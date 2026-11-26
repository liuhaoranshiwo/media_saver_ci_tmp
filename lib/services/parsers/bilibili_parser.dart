import 'dart:convert';
import 'dart:io' show HttpException;
import '../http_util.dart';
import '../../models/parsed_media.dart';
import '../app_logger.dart';
import '../parser_service.dart';

/// B 站解析器（build 123 新增）
///
/// 链路全部为纯 HTTP 匿名可用（2026-11-26 实测确认，无需 cookie / 无需 wbi 签名）：
///
/// ① `api.bilibili.com/x/web-interface/view?bvid=...`
///    → code 0，拿到 bvid / aid / cid / title / pic（封面原图）/ pages（分P列表）
///
/// ② `api.bilibili.com/x/player/playurl?avid=&cid=&qn=80&fnval=0&fourk=1`
///    → code 0，`data.durl[0].url` 是**单文件 mp4**（视频+音频在同一文件）
///    实测 BV1vHy2zSEGp（1080×1920）: qn=80 实际返回 quality=64（720P），
///    163,715,490 字节，`Content-Type: video/mp4`。
///
/// ⚠️ 为什么不用 DASH（fnval=16 / 4048）：
///    匿名态下 DASH 最高只给到 480×852（video id=32），**画质比 durl 的 720P 更低**，
///    而且音视频是分离的 .m4s（需额外下音轨再合成）——
///    实测同一视频：durl quality=64 (720P) vs dash 最高 512×384 / 480×852。
///    所以固定走 fnval=0 的 durl 路线。
///
/// ③ 下载必须带 `Referer: https://www.bilibili.com/`：
///    实测裸请求 / 无 UA 一律 403（返回 150 字节 HTML），
///    带 Referer 才 200 + `accept-ranges: bytes`（支持断点续传）。
///    该 Referer 已在 Downloader._headerVariants 里按域名注入。
///
/// 图片类：视频封面 `data.pic` 本身就是原图（hdslb.com/bfs/archive/*.jpg，
///    不带 `@` 缩放后缀），直接作为图片项输出。
class BilibiliParser extends MediaParser {
  /// iPhone UA（实测匿名可用；不带 UA 会被 403）
  static const _ua = HttpUtil.iosUa;

  /// 视频页 / 番剧页正则
  static final _bvidRe = RegExp(r'BV1[A-Za-z0-9]{9,}');
  static final _avRe = RegExp(r'(?:/video/av|aid=)(\d{6,})');
  /// 短链 b23.tv
  static final _b23Re = RegExp(r'b23\.tv/([A-Za-z0-9]+)');

  @override
  Future<ParseResult> parse(String url) async {
    AppLogger.log('bili', '开始解析: $url');

    // 1. 短链展开（b23.tv → www.bilibili.com/video/BVxxx）
    var target = url;
    if (_b23Re.hasMatch(url)) {
      try {
        final (finalUrl, _) = await HttpUtil.getWithRedirects(url, ua: _ua);
        target = finalUrl;
        AppLogger.log('bili', '短链展开 → $target');
      } catch (e) {
        AppLogger.log('bili', '短链展开失败: $e');
      }
    }

    // 2. 取 bvid / aid
    final bvid = _bvidRe.firstMatch(target)?.group(0);
    final aid = bvid == null ? _avRe.firstMatch(target)?.group(1) : null;
    if (bvid == null && aid == null) {
      throw ParseException('B 站链接中未找到 BV 号或 av 号（$target）');
    }
    final idQuery = bvid != null ? 'bvid=$bvid' : 'aid=$aid';

    // 3. view 接口：视频元信息 + 分 P 列表
    final view = await _getJson(
        'https://api.bilibili.com/x/web-interface/view?$idQuery');
    final vcode = view['code'];
    if (vcode != 0) {
      final msg = view['message'] ?? view['msg'] ?? '未知错误';
      AppLogger.log('bili', 'view 失败 code=$vcode msg=$msg');
      throw ParseException('B 站接口返回错误（code $vcode：$msg），可能视频已删除或需要登录');
    }
    final data = view['data'];
    if (data is! Map) throw ParseException('B 站 view 返回结构异常');
    final v = data.cast<String, dynamic>();

    final title = (v['title'] as String?) ?? 'B 站视频';
    final owner = (v['owner'] is Map)
        ? ((v['owner'] as Map)['name'] as String? ?? '')
        : '';
    final realAid = '${v['aid'] ?? aid}';
    final cover = (v['pic'] as String?)?.trim();

    // 分 P：pages 是数组，每项有自己的 cid 和 part 标题
    final pages = (v['pages'] as List?)?.whereType<Map>().toList() ?? const [];
    final items = <ParsedMediaItem>[];
    // 尺寸/方向在最外层 dimension（pages 里的每项通常没有 dimension 字段）
    final dim = (v['dimension'] as Map?)?.cast<String, dynamic>();
    final vw = (dim?['width'] as num?)?.toInt();
    final vh = (dim?['height'] as num?)?.toInt();

    // 4. 逐个分 P 取 playurl（单文件 durl，含音频）
    if (pages.isNotEmpty) {
      for (var i = 0; i < pages.length; i++) {
        final pg = pages[i].cast<String, dynamic>();
        final cid = '${pg['cid'] ?? ''}';
        if (cid.isEmpty) continue;
        final part = (pg['part'] as String?)?.trim() ?? '';
        try {
          final one = await _playurl(realAid, cid);
          if (one == null) {
            AppLogger.log('bili', '第 ${i + 1} P cid=$cid 无可用地址，跳过');
            continue;
          }
          final (url2, backup, qnDesc, size) = one;
          items.add(ParsedMediaItem(
            kind: MediaKind.video,
            url: url2,
            fallbackUrls: backup,
            coverUrl: cover,
            ext: 'mp4',
            width: vw,
            height: vh,
          ));
          AppLogger.log('bili',
              'P${i + 1} ok: cid=$cid part=$part qn=$qnDesc size=$size '
              '${backup.length > 0 ? "备用${backup.length}条" : ""}');
          // 多 P 之间稍作间隔，避免连续请求被判频控
          if (pages.length > 1) {
            await Future.delayed(const Duration(milliseconds: 400));
          }
        } catch (e) {
          AppLogger.log('bili', 'P${i + 1} 解析失败: $e');
        }
      }
    } else {
      // 无 pages 字段时用顶层 cid 兜底
      final topCid = '${v['cid'] ?? ''}';
      if (topCid.isNotEmpty) {
        final one = await _playurl(realAid, topCid);
        if (one != null) {
          final (u, backup, qnDesc, size) = one;
          items.add(ParsedMediaItem(
            kind: MediaKind.video,
            url: u,
            fallbackUrls: backup,
            coverUrl: cover,
            ext: 'mp4',
            width: vw,
            height: vh,
          ));
          AppLogger.log('bili', '单P ok: cid=$topCid qn=$qnDesc size=$size');
        }
      }
    }

    if (items.isEmpty) {
      throw ParseException('B 站视频地址解析失败（可能需要登录或该视频受限）');
    }

    // 5. 封面图作为附加图片项（用户点"全部保存"可一并拿到）
    //    注意：放在视频项之后，避免用户以为只有图
    if (cover != null && cover.isNotEmpty) {
      // 封面原始地址可能带 @ 缩放参数（部分接口返回），去掉后取原图
      final rawCover = cover.split('@').first;
      items.add(ParsedMediaItem(
        kind: MediaKind.image,
        url: rawCover.startsWith('http')
            ? rawCover.replaceFirst('http://', 'https://')
            : 'https://$rawCover',
        ext: _extOf(rawCover),
      ));
    }

    final count = items.where((e) => e.isVideo).length;
    final notice = pages.length > 1
        ? '该视频共 ${pages.length} 个分 P，已全部解析为独立视频文件'
        : null;

    return ParseResult(
      platform: ParsePlatform.bilibili,
      sourceUrl: url,
      title: title,
      author: owner,
      items: items,
      parsedAt: DateTime.now(),
      notice: notice,
    );
  }

  /// 播放地址：返回 (主地址, 备用地址链, 画质描述, 字节数)
  ///
  /// fnval=0 表示要 **durl**（单文件 mp4），不是 DASH 分段。
  /// qn=80 请求 720P；服务端会按账号权限降级，实际画质看 `data.quality`。
  Future<(String, List<String>, String, int)?> _playurl(
      String aid, String cid) async {
    final url = 'https://api.bilibili.com/x/player/playurl'
        '?avid=$aid&cid=$cid&qn=80&fnval=0&fnver=0&fourk=1';
    final json = await _getJson(url,
        referer: 'https://www.bilibili.com/video/av$aid');
    final code = json['code'];
    if (code != 0) {
      AppLogger.log('bili', 'playurl code=$code msg=${json['message'] ?? json['msg']}');
      return null;
    }
    final data = json['data'];
    if (data is! Map) return null;
    final d = data.cast<String, dynamic>();

    // durl 是分片数组；普通视频只有 1 段，超过 1 段需要按序合并
    // （实测匿名 720P 只有 1 段，多段多见于超长视频）
    final durl = (d['durl'] as List?)?.whereType<Map>().toList() ?? const [];
    if (durl.isEmpty) {
      AppLogger.log('bili', 'playurl 无 durl（可能被降级或需要登录）');
      return null;
    }
    final first = durl.first.cast<String, dynamic>();
    final main = (first['url'] as String?) ?? '';
    if (main.isEmpty) return null;

    final backup = (first['backup_url'] as List?)?.cast<String>() ?? const <String>[];
    final qn = (d['quality'] as num?)?.toInt() ?? 0;
    final size = (first['size'] as num?)?.toInt() ?? 0;

    if (durl.length > 1) {
      AppLogger.log('bili', '⚠️ durl 有 ${durl.length} 段，当前只取第一段（超长视频需分段合并）');
    }

    return (
      main.startsWith('http://') ? main.replaceFirst('http://', 'https://') : main,
      backup.map((b) => b.startsWith('http://') ? b.replaceFirst('http://', 'https://') : b).toList(),
      _qnName(qn),
      size,
    );
  }

  Future<Map<String, dynamic>> _getJson(String url, {String? referer}) async {
    final client = HttpUtil.newHttpClient(ua: _ua);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('Referer', referer ?? 'https://www.bilibili.com/');
      req.headers.set('Origin', 'https://www.bilibili.com');
      req.headers.set('Accept', 'application/json, text/plain, */*');
      req.headers.set('Accept-Language', 'zh-CN,zh;q=0.9');
      final resp = await req.close().timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode} : $url');
      }
      final body = await resp.transform(utf8.decoder).join();
      final j = jsonDecode(body);
      if (j is! Map) throw HttpException('响应不是 JSON 对象: $url');
      return j.cast<String, dynamic>();
    } finally {
      client.close();
    }
  }

  /// qn 数值 → 人话画质（B 站 quality 是响应里回报的实际值，不是请求值）
  static String _qnName(int qn) {
    switch (qn) {
      case 127:
        return '8K';
      case 126:
        return '杜比视界';
      case 125:
        return 'HDR';
      case 120:
        return '4K';
      case 116:
        return '1080P60';
      case 112:
        return '1080P+';
      case 80:
        return '1080P';
      case 74:
        return '720P60';
      case 64:
        return '720P';
      case 32:
        return '480P';
      case 16:
        return '360P';
      default:
        return 'qn$qn';
    }
  }

  static String _extOf(String url) {
    final p = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    if (p.endsWith('.png')) return 'png';
    if (p.endsWith('.webp')) return 'webp';
    if (p.endsWith('.gif')) return 'gif';
    return 'jpg';
  }
}
