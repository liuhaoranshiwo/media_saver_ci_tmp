import 'dart:io' show HttpException;
import '../http_util.dart';
import '../../models/parsed_media.dart';
import '../parser_service.dart';

/// X（推特）解析器
///
/// 链路（公开已知方案，无需登录态）：
/// 1. 短链 t.co/xxx → 30x → x.com/{user}/status/{id}
/// 2. 数据源（按优先级）：
///    A. cdn.syndication.twimg.com/tweet-result?id={id}&token=x
///       → mediaDetails[]：photo / video / animated_gif + video_info.variants
///    B. api.fxtwitter.com/status/{id}（fxtwitter 开放 API，兜底）
///       → tweet.media.all[]：type photo / gif / video，url 已是直链
/// 3. 图片原图：media_url_https + ?format=jpg&name=orig（name=orig = 原始分辨率，
///    不带 name 参数拿到的是 ~680px 缩略版，切勿直接用）
/// 4. 视频原文件：video_info.variants 中 content_type=video/mp4 里 bitrate 最高的一条
/// 5. 推特 GIF（animated_gif）本质是循环 mp4 —— 保存时作为 Live Photo 来源：
///    原生层会抽取首帧 + 注入 Apple 实况元数据后合成系统实况照片
//!
//! 维护提示：token=x 失效（返回 invalid token）时，更换 token 或直接切 fxtwitter；
//! fxtwitter 字段变化时抓 api.fxtwitter.com 响应核对。
class TwitterParser extends MediaParser {
  static final _tweetId = RegExp(r'/status(?:es)?/(\d{10,25})');

  @override
  Future<ParseResult> parse(String url) async {
    var workUrl = url;

    // 1. 展开 t.co 短链
    final uri = Uri.parse(workUrl);
    if (uri.host.toLowerCase() == 't.co' ||
        uri.host.toLowerCase().endsWith('.t.co')) {
      final (finalUrl, _) = await HttpUtil.getWithRedirects(workUrl);
      workUrl = finalUrl;
    }

    final id = _tweetId.firstMatch(workUrl)?.group(1);
    if (id == null) {
      throw ParseException('链接中未找到推文 ID（需为 x.com/{user}/status/{id} 形式）');
    }

    // 2. 主源：syndication；失败切 fxtwitter
    try {
      return await _viaSyndication(id, url);
    } on ParseException {
      rethrow;
    } catch (_) {
      return await _viaFxtwitter(id, url);
    }
  }

  // ---------- 数据源 A：syndication ----------

  Future<ParseResult> _viaSyndication(String id, String sourceUrl) async {
    final data = await HttpUtil.getJson(
      'https://cdn.syndication.twimg.com/tweet-result?id=$id&token=x&lang=zh-cn',
      ua: HttpUtil.iosUa,
    );
    final mediaDetails = data['mediaDetails'] as List?;
    if (mediaDetails == null || mediaDetails.isEmpty) {
      throw const HttpException('syndication 无媒体数据');
    }

    final author = ((((data['user'] ?? const {}) as Map)['name'])) as String? ?? '';
    final text = (data['text'] as String?)?.trim() ?? 'X 帖子';

    final items = <ParsedMediaItem>[];
    for (final raw in mediaDetails) {
      final m = raw as Map<String, dynamic>;
      final type = m['type'] as String?;
      final mediaUrl = m['media_url_https'] as String?;
      if (mediaUrl == null) continue;

      switch (type) {
        case 'photo':
          items.add(ParsedMediaItem(
            kind: MediaKind.image,
            url: _origImageUrl(mediaUrl),
            width: (m['sizes']?['orig']?['w'] as num?)?.toInt(),
            height: (m['sizes']?['orig']?['h'] as num?)?.toInt(),
          ));
        case 'video':
          final best = _bestVideoVariant(m);
          if (best != null) {
            items.add(ParsedMediaItem(
              kind: MediaKind.video,
              url: best,
              coverUrl: _origImageUrl(mediaUrl),
              ext: 'mp4',
            ));
          }
        case 'animated_gif':
          final best = _bestVideoVariant(m);
          if (best != null) {
            // media_url_https 为 tweet_video_thumb 缩略图，用作网格预览
            items.add(ParsedMediaItem(
              kind: MediaKind.livePhoto,
              url: _origImageUrl(mediaUrl),
              companionUrl: best,
              ext: 'mp4',
            ));
          }
      }
    }
    if (items.isEmpty) throw const HttpException('syndication 未产出媒体项');

    return ParseResult(
      platform: ParsePlatform.twitter,
      sourceUrl: sourceUrl,
      title: text,
      author: author,
      items: items,
      parsedAt: DateTime.now(),
    );
  }

  // ---------- 数据源 B：fxtwitter ----------

  Future<ParseResult> _viaFxtwitter(String id, String sourceUrl) async {
    final data = await HttpUtil.getJson(
      'https://api.fxtwitter.com/status/$id',
      ua: HttpUtil.iosUa,
    );
    if (data['code'] != 200) throw const HttpException('fxtwitter 返回异常');
    final tweet = data['tweet'] as Map<String, dynamic>;
    final author = ((((tweet['author'] ?? const {}) as Map)['name'])) as String? ?? '';
    final text = (tweet['text'] as String?)?.trim() ?? 'X 帖子';

    final media = tweet['media'] as Map<String, dynamic>?;
    final all = media?['all'] as List?;
    if (all == null || all.isEmpty) throw const HttpException('fxtwitter 无媒体数据');

    final items = <ParsedMediaItem>[];
    for (final raw in all) {
      final m = raw as Map<String, dynamic>;
      final type = m['type'] as String?;
      final url = m['url'] as String?;
      final thumb = (m['thumb_url'] ?? m['thumbnail_url'] ?? m['thumbnail'])
          as String?;
      if (url == null) continue;
      switch (type) {
        case 'photo':
          items.add(ParsedMediaItem(kind: MediaKind.image, url: url));
        case 'gif':
          items.add(ParsedMediaItem(
            kind: MediaKind.livePhoto,
            url: thumb ?? '', // 无缩略图时网格显示占位
            companionUrl: url,
            ext: 'mp4',
          ));
        case 'video':
          items.add(ParsedMediaItem(
            kind: MediaKind.video,
            url: url,
            coverUrl: thumb,
            ext: 'mp4',
          ));
      }
    }
    if (items.isEmpty) throw const HttpException('fxtwitter 未产出媒体项');

    return ParseResult(
      platform: ParsePlatform.twitter,
      sourceUrl: sourceUrl,
      title: text,
      author: author,
      items: items,
      parsedAt: DateTime.now(),
    );
  }

  // ---------- 工具 ----------

  /// 任意 twimg 图片地址 → 原始分辨率地址
  String _origImageUrl(String mediaUrl) {
    final i = mediaUrl.indexOf('?');
    final base = i > 0 ? mediaUrl.substring(0, i) : mediaUrl;
    // 保持原扩展名（png/gif 不强转 jpg，Twitter 支持 format 参数）
    final ext = base.contains('.') ? base.split('.').last : 'jpg';
    final dot = base.lastIndexOf('.');
    final stem = dot > 0 ? base.substring(0, dot) : base;
    return '$stem?format=$ext&name=orig';
  }

  /// variants 中选码率最高的 mp4（原画质）
  String? _bestVideoVariant(Map<String, dynamic> media) {
    final info = media['video_info'] as Map<String, dynamic>?;
    final variants = info?['variants'] as List?;
    if (variants == null || variants.isEmpty) return null;
    String? best;
    int bestBitrate = -1;
    for (final v in variants) {
      final map = v as Map<String, dynamic>;
      final contentType = map['content_type'] as String? ?? '';
      if (!contentType.contains('mp4')) continue;
      final bitrate = (map['bitrate'] as num?)?.toInt() ?? 0;
      if (bitrate > bestBitrate) {
        bestBitrate = bitrate;
        best = map['url'] as String?;
      }
    }
    return best;
  }
}
