import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'http_util.dart';
import 'app_logger.dart';
import '../models/parsed_media.dart';

/// 流式下载到应用临时目录，返回本地文件路径
/// 1. 边下边写盘，支持大视频，内存占用恒定
/// 2. 断点续传：连接中断时从已收字节处 Range 续传，不从头下载
/// 3. 403 时自动轮换请求头组合：微博/X 的视频 CDN 对 Referer/UA 的要求
///    因域名而异（weibocdn 视频域有的要无 Referer、有的要 weibo.com、
///    有的要 m.weibo.cn），写死一种会踩坑，按阶梯逐组尝试
class Downloader {
  static const _resumeAttempts = 3; // 每组请求头的断点续传次数

  /// 最近一次成功下载实际使用的源地址（供保存环节判断是否为无水印原始文件）
  static String? lastSourceUrl;

  static Future<File> download(
    ParsedMediaItem item, {
    void Function(int received, int total)? onProgress,
  }) async {
    final dir = await getTemporaryDirectory();
    final mediaDir = Directory('${dir.path}/media_saver');
    if (!await mediaDir.exists()) {
      await mediaDir.create(recursive: true);
    }
    final name =
        '${DateTime.now().millisecondsSinceEpoch}_${item.kind.name}.${item.ext}';
    final target = File('${mediaDir.path}/$name');

    Object? lastError;
    // 候选地址链：微博 woriginal（无水印原图）失败自动回退 large 等
    final urls = [item.url, ...item.fallbackUrls];
    outer:
    for (final url in urls) {
      // 换源时必须丢弃上一个源的断点字节（内容不同不能续传）
      if (await target.exists()) {
        try {
          await target.delete();
        } catch (_) {}
      }
      variants:
      for (final variant in _headerVariants(url)) {
        final ua = variant.remove('__ua') ?? HttpUtil.iosUa;
        for (var attempt = 0; attempt < _resumeAttempts; attempt++) {
          final resumeFrom = await target.exists() ? await target.length() : 0;
          IOSink? sink;
          try {
            final headers = Map<String, String>.from(variant);
            var baseReceived = 0;
            if (resumeFrom > 0) {
              headers['Range'] = 'bytes=$resumeFrom-';
              baseReceived = resumeFrom;
            }

            final resp = await HttpUtil.downloadStream(
              url,
              headers: headers,
              ua: ua,
            );

            // 403/401 = 请求头组合被拒 → 换下一组请求头
            if (resp.statusCode == 403 || resp.statusCode == 401) {
              AppLogger.log('dl',
                  '候选#${urls.indexOf(url)} HTTP${resp.statusCode}（换请求头）: ${Uri.parse(url).host}');
              lastError = HttpException('HTTP ${resp.statusCode}');
              continue variants;
            }
            // 404/410 = 该源地址不存在（如旧图无 woriginal 档）→ 换下一候选源
            if (resp.statusCode == 404 || resp.statusCode == 410) {
              AppLogger.log('dl',
                  '候选#${urls.indexOf(url)} HTTP${resp.statusCode}（换候选源）: $url');
              lastError = HttpException('HTTP ${resp.statusCode}');
              continue outer;
            }
            // 416 = 断点已到文件末尾（内容完整）
            if (resp.statusCode == 416) return target;
          if (resp.statusCode != 200 && resp.statusCode != 206) {
            throw HttpException('下载失败 HTTP ${resp.statusCode}');
          }
          // 服务器不支持 Range（返回 200 全量）时从头写
          if (baseReceived > 0 && resp.statusCode == 200) {
            baseReceived = 0;
          }

          final total = baseReceived + (resp.contentLength ?? 0);
          var received = baseReceived;
          sink = target.openWrite(
              mode: baseReceived > 0 ? FileMode.append : FileMode.write);

          await for (final chunk in resp.stream) {
            received += chunk.length;
            sink.add(chunk);
            onProgress?.call(received, total);
          }
          await sink.flush();
          await sink.close();
          sink = null;
          final idx = urls.indexOf(url);
          lastSourceUrl = url;
          AppLogger.log('dl',
              '下载成功: 候选#$idx ${Uri.parse(url).host} ${received}B（共${urls.length}个候选）');
          // 小红书：前两个无水印原图直链（sns-img-*）都失败、最终用了带水印的
          // H5 图时自动上报——用于统计原图直链 404 的笔记范围
          if (idx > 0 &&
              idx == urls.length - 1 &&
              Uri.parse(url).host.contains('xhscdn')) {
            AppLogger.report(
                '小红书原图直链失效回退带水印图: 候选$idx/${urls.length} 最后错误=$lastError');
          }
          return target;
        } catch (e) {
          lastError = e;
          // 保留已收字节，下一轮从断点续传
        } finally {
          if (sink != null) {
            try {
              await sink.flush();
              await sink.close();
            } catch (_) {}
          }
        }
      }
    }
    }
    throw HttpException('下载失败（已重试）：$lastError');
  }

  /// 按媒体域名生成请求头尝试阶梯（'__ua' 为特殊键指定 UA）
  static List<Map<String, String>> _headerVariants(String url) {
    final uri = Uri.tryParse(url);
    final host = (uri?.host.toLowerCase()) ?? '';

    // 微博：图片域校验 Referer；视频域（weibocdn 等）规则不一，多组尝试
    if (host.contains('sinaimg.cn') || host.contains('weibo.com')) {
      return [
        {'Referer': 'https://weibo.com/'},
        {'Referer': 'https://m.weibo.cn/'},
      ];
    }
    if (host.contains('weibo')) {
      return [
        // 2026-11 实测：f.video.weibocdn.com 裸请求 403，
        // 带 weibo.com Referer 206 成功 → Referer 组提前
        {'Referer': 'https://weibo.com/'},
        {'Referer': 'https://m.weibo.cn/'},
        {
          '__ua': HttpUtil.androidUa,
          'Referer': 'https://weibo.com/',
        },
        {}, // 极少数视频 CDN 带 Referer 反而 403，裸请求殿后
      ];
    }
    // X（推特）：twimg 带 x.com Referer；失败再裸请求
    if (host.contains('twimg.com')) {
      return [
        {'Referer': 'https://x.com/'},
        {},
      ];
    }
    // 其他域名：裸请求即可
    return [
      {},
      {'Referer': 'https://${uri?.host ?? ''}/'},
    ];
  }
}
