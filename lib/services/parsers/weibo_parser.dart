import 'dart:convert';
import 'dart:io' show HttpException, HttpClient, HttpHeaders;
import '../http_util.dart';
import '../../models/parsed_media.dart';
import '../parser_service.dart';

/// 微博解析器（2026-11-06 风控复现实测校准）
///
/// 2026-11 现状（本机 curl 实测）：
/// 1. PC ajax statuses/show 对访客 Cookie 只返回空壳（ok=1 但无 playback_list）
///    —— 多清晰度档位路线失效，除非用户登录
/// 2. m.weibo.cn show 免登录仍可用：视频帖 media_info 现在只剩
///    stream_url / stream_url_hd（720p mp4 无水印），旧 mp4_1080p_mp4 等档位键
///    已消失；page_info['urls'] 里另有 mp4_720p_mp4 / mp4_ld_mp4 兜底
/// 3. 视频直链（f.video.weibocdn.com）裸请求 403，必须带 Referer
/// 4. 部分帖子 stream_url 是 http://（iOS ATS 会拦截）→ 强制升级 https
/// 5. feed/搜索类接口已风控（432/-100），单帖 show 接口仍稳
///
/// 图片档位规律（2026-11-09 按用户实测方案校准）：
///   微博两套图片生成管线：
///     - 标准管线 large/original/mw2000：CDN 动态盖章博主水印（宽或高>300px 即加）
///     - 旁路管线 oslarge：跳过盖章环节 → 直接出无水印文件（~690px，平台限制）
///   large = original = mw2000 三者字节级相同（原始分辨率，带水印）。
///   os 其它前缀（osmw2000/osbmiddle 等）不存在，返回 7092 字节占位 GIF。
///   无水印候选链：oslarge → large → woriginal → 原地址（404/占位自动回退）。
///   保存环节零二次处理（用户要求：直接爬取，不做像素修补）。
class WeiboParser extends MediaParser {
  /// iPhone iOS 16.6 Safari UA（移动端 UA 是 m.weibo.cn 的关键）
  static const _ua =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) '
      'Version/16.6 Mobile/15E148 Safari/604.1';

  /// PC Chrome UA（weibo.com/ajax 需要）
  static const _pcUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  @override
  Future<ParseResult> parse(String url) async {
    final bid = _extractBid(url);
    if (bid == null) {
      throw ParseException('微博链接中未找到微博 ID');
    }

    // ---- ① m.weibo.cn show：图片 + 视频候选（风控时 UA 轮换重试） ----
    Map<String, dynamic>? mb;
    for (final (ua, useGuest) in [
      (_ua, false),
      (_ua, true),
      (HttpUtil.androidUa, true),
    ]) {
      try {
        final cookies = useGuest ? await _guestCookies(ua) : null;
        final data = await _fetchShow(bid, cookies, ua: ua);
        if (data['ok'] == 1 && data['data'] is Map) {
          mb = (data['data'] as Map).cast<String, dynamic>();
          break;
        }
      } catch (_) {}
      if (useGuest) {
        // 带访客 Cookie 的尝试失败后稍等再换组，降低风控概率
        await Future.delayed(const Duration(milliseconds: 800));
      }
    }

    // ---- ② PC ajax：访客态已实测空壳，仅在 m.show 完全失败时最后一搏 ----
    Map<String, dynamic>? pcData;
    if (mb == null) {
      try {
        final pcCookies = await _guestCookies(_pcUa);
        final data = await _fetchPcShow(bid, pcCookies);
        if (data['ok'] == 1 && data['data'] is Map) {
          final d = (data['data'] as Map).cast<String, dynamic>();
          // 空壳检测：文本与 page_info 均无内容则视为无效
          if ((d['text_raw'] ?? d['text'] ?? '').toString().isNotEmpty ||
              (d['page_info'] as Map?)?.isNotEmpty == true) {
            pcData = d;
          }
        }
      } catch (_) {}
    }

    if (mb == null && pcData == null) {
      throw ParseException('微博接口返回异常（可能触发风控），请稍后重试');
    }

    final author = _pick([
      mb?['user'],
      pcData?['user'],
    ].whereType<Map>().map((m) => m['screen_name']).whereType<String>());

    final text = _stripHtml(_pick([
      mb?['text'],
      pcData?['text_raw'],
      pcData?['text'],
    ]).toString());

    final items = <ParsedMediaItem>[];

    // ---- 图片与实况图（无水印候选链） ----
    final pics = (mb?['pics'] ?? pcData?['pics']) as List?;
    if (pics != null) {
      for (final raw in pics) {
        if (raw is! Map) continue;
        final pic = raw.cast<String, dynamic>();
        // 优先 large/original 声明的高清地址作为基准（再改写无水印前缀）
        final baseUrl = (pic['large']?['url'] ??
                pic['original']?['url'] ??
                pic['url'])
            as String?;
        if (baseUrl == null || baseUrl.isEmpty) continue;

        final candidates = _noWatermarkUrls(baseUrl);

        final liveVideoUrl = pic['videoSrc'] as String?;
        final isLive = pic['type'] == 'livephoto' &&
            liveVideoUrl != null &&
            liveVideoUrl.isNotEmpty;

        items.add(ParsedMediaItem(
          kind: isLive ? MediaKind.livePhoto : MediaKind.image,
          url: candidates.first,
          fallbackUrls: candidates.sublist(1),
          companionUrl: isLive ? liveVideoUrl : null,
          width: _intOf(pic['large']?['geo']?['width']),
          height: _intOf(pic['large']?['geo']?['height']),
          ext: 'jpg',
        ));
      }
    }

    // pic_ids 兜底（pics 缺失时拼无水印直链，无实况信息）
    if (items.isEmpty) {
      final picIds = mb?['pic_ids'] as List? ?? const [];
      for (final pid in picIds) {
        if (pid is String && pid.isNotEmpty) {
          // 同 _noWatermarkUrls：os* 无水印优先（690px），large 仅兜底
          final chain = _noWatermarkUrls('https://wx1.sinaimg.cn/large/$pid.jpg');
          items.add(ParsedMediaItem(
            kind: MediaKind.image,
            url: chain.first,
            fallbackUrls: chain.sublist(1),
          ));
        }
      }
    }

    // ---- 视频：多来源候选（http→https 强制升级，m3u8 后置） ----
    final videoCandidates = <String>[];
    final m3u8Candidates = <String>[];
    void addVideoUrl(String? raw) {
      if (raw == null || raw.isEmpty) return;
      var url = raw;
      // iOS ATS 拦截 http 请求，video.weibocdn 支持 https
      if (url.startsWith('http://')) url = 'https://${url.substring(7)}';
      if (url.contains('.m3u8')) {
        if (!m3u8Candidates.contains(url)) m3u8Candidates.add(url);
        return;
      }
      if (!videoCandidates.contains(url)) videoCandidates.add(url);
    }

    // ②a PC ajax playback_list：取像素面积最高档（登录态才有，访客多为空）
    Map? bestPlay;
    final playbackList = ((((pcData?['page_info'] ?? const {})
                as Map)['media_info'] ??
            const {})
        as Map)['playback_list'] as List?;
    if (playbackList != null) {
      int px(Map e) {
        final p = (e['play_info'] ?? const {}) as Map;
        final w = _intOf(p['width']) ?? 0;
        final h = _intOf(p['height']) ?? 0;
        return w * h;
      }

      int bitrate(Map e) => _intOf(((e['play_info'] ?? const {}) as Map)['bitrate']) ?? 0;
      final sorted = playbackList.whereType<Map>().toList()
        ..sort((a, b) {
          final c = px(a).compareTo(px(b));
          return c != 0 ? c : bitrate(a).compareTo(bitrate(b));
        });
      for (final e in sorted.reversed) {
        addVideoUrl(((e['play_info'] ?? const {}) as Map)['url'] as String?);
      }
      if (sorted.isNotEmpty) bestPlay = (sorted.last['play_info'] ?? const {}) as Map;
    }

    // ②b m.show media_info 档位（2026-11 实测只剩 stream_url/stream_url_hd）
    final pageInfo = (mb?['page_info'] ?? pcData?['page_info']) as Map?;
    final mediaInfo = ((pageInfo?['media_info'] ?? const {}) as Map).cast<String, dynamic>();
    const tierKeys = [
      'mp4_1080p_mp4',
      'mp4_720p_mp4',
      'mp4_hd_mp4',
      'mp4_ld_mp4',
      'stream_url_hd',
      'stream_url',
    ];
    for (final k in tierKeys) {
      addVideoUrl(mediaInfo[k] as String?);
    }

    // ②c page_info['urls'] 兜底（新版部分帖 media_info 精简后，档位挪到这里）
    final urlMap = pageInfo?['urls'];
    if (urlMap is Map) {
      for (final k in tierKeys) {
        addVideoUrl(urlMap[k] as String?);
      }
    }

    // m3u8 仅在无任何 mp4 时作为最后手段
    if (videoCandidates.isEmpty) videoCandidates.addAll(m3u8Candidates);

    if (videoCandidates.isNotEmpty && items.isEmpty) {
      items.add(ParsedMediaItem(
        kind: MediaKind.video,
        url: videoCandidates.first,
        fallbackUrls: videoCandidates.sublist(1),
        coverUrl: pageInfo?['page_pic'] is Map
            ? ((pageInfo!['page_pic']) as Map)['url'] as String?
            : pageInfo?['page_pic'] as String?,
        width: _intOf(bestPlay?['width']),
        height: _intOf(bestPlay?['height']),
        ext: 'mp4',
      ));
    }

    if (items.isEmpty) throw ParseException('未解析到可下载的图片或视频');

    return ParseResult(
      platform: ParsePlatform.weibo,
      sourceUrl: url,
      title: text,
      author: author,
      items: items,
      parsedAt: DateTime.now(),
    );
  }

  // ---------- 无水印图片改写 ----------

  /// 把 sinaimg 任意尺寸前缀改写为候选链（2026-11-09 高画质无水印方案）：
  /// large（=original=mw2000 原始分辨率，带平台水印）→ woriginal → oslarge（无水印690px兜底）→ 原地址
  ///
  /// 微博两套图片生成管线：
  ///   - 标准管线 large/original/mw2000：CDN 动态盖章博主水印（宽或高>300px 即加）
  ///   - 旁路管线 oslarge：跳过盖章环节，直接出无水印文件（~690px，平台限制）
  /// 高画质无水印（用户 2026-11-09 要求）：优先下载 large 全分辨率原图，
  /// 保存环节用 native 精准去水印（角部矩形掩码 + 中央亮度差白字检测 + inpaint），
  /// 检测不到水印则原样保存 —— 兼顾"高画质 + 无水印"。oslarge 仅作 404 兜底。
  static List<String> _noWatermarkUrls(String rawUrl) {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || !uri.host.contains('sinaimg.cn')) return [rawUrl];
    final segs = uri.pathSegments;
    if (segs.length < 2) return [rawUrl];
    final pid = segs.last;
    final host = uri.host;
    String build(String prefix) => 'https://$host/$prefix/$pid';
    final chain = [
      build('large'),     // = original = mw2000，原始分辨率（保存时去水印）
      build('woriginal'), // 原尺寸重压档（兜底）
      build('oslarge'),   // 无水印旁路管线（~690px，前两者 404 时兜底）
      rawUrl,
    ];
    // 去重保序
    return chain.toSet().toList();
  }

  // ---------- m.weibo.cn show 接口 ----------

  Future<Map<String, dynamic>> _fetchShow(
      String bid, Map<String, String>? cookies,
      {String ua = _ua}) async {
    return HttpUtil.getJson(
      'https://m.weibo.cn/statuses/show?id=$bid',
      headers: {
        'Referer': 'https://m.weibo.cn/',
        'X-Requested-With': 'XMLHttpRequest',
        'MWeibo-Pwa': '1',
        if (cookies != null) 'Cookie': cookies.entries
            .map((e) => '${e.key}=${e.value}')
            .join('; '),
      },
      ua: ua,
    );
  }

  // ---------- PC ajax 接口（yt-dlp 同款，视频高清直链） ----------

  Future<Map<String, dynamic>> _fetchPcShow(
      String bid, Map<String, String>? cookies) async {
    return HttpUtil.getJson(
      'https://weibo.com/ajax/statuses/show?id=$bid',
      headers: {
        'Referer': 'https://weibo.com/',
        'Accept': 'application/json, text/plain, */*',
        if (cookies != null) 'Cookie': cookies.entries
            .map((e) => '${e.key}=${e.value}')
            .join('; '),
      },
      ua: _pcUa,
    );
  }

  // ---------- 访客系统（免登录换 SUB/SUBP，非用户 Cookie） ----------

  Future<Map<String, String>?> _guestCookies(String ua) async {
    final client = HttpClient();
    client.userAgent = ua;
    try {
      // 1. genvisitor：提交设备指纹，JSONP 返回 tid
      final fp = jsonEncode({
        'os': '1',
        'browser': 'Chrome149,0,0,0',
        'fonts': 'undefined',
        'screenInfo': '1920*1080*24',
        'plugins': '',
      });
      final req1 = await client
          .postUrl(Uri.parse('https://passport.weibo.com/visitor/genvisitor'));
      req1.headers.set(HttpHeaders.contentTypeHeader,
          'application/x-www-form-urlencoded');
      req1.write('cb=gen_callback&fp=${Uri.encodeComponent(fp)}');
      final resp1 = await req1.close().timeout(const Duration(seconds: 10));
      if (resp1.statusCode != 200) return null;
      final txt1 = await resp1.transform(utf8.decoder).join();

      final i = txt1.indexOf('(');
      final j = txt1.lastIndexOf(')');
      if (i < 0 || j <= i) return null;
      final data1 =
          (jsonDecode(txt1.substring(i + 1, j)) as Map)['data'];
      if (data1 is! Map || data1['tid'] == null) return null;
      final tid = data1['tid'] as String;
      final w = data1['new_tid'] == true ? 3 : 2;
      final c = data1['confidence'] is int ? data1['confidence'] as int : 100;

      // 2. incarnate：换取访客 Cookie（SUB/SUBP 在 Set-Cookie 里）
      final req2 = await client.getUrl(Uri.parse(
          'https://passport.weibo.com/visitor/visitor'
          '?a=incarnate&t=$tid&w=$w&c=${c.toString().padLeft(3, '0')}&gc='
          '&cb=cross_domain&from=weibo'
          '&_rand=${DateTime.now().millisecondsSinceEpoch}'));
      final resp2 = await req2.close().timeout(const Duration(seconds: 10));

      final cookies = <String, String>{};
      for (final value in resp2.headers['set-cookie'] ?? const []) {
        final pair = value.split(';').first;
        final eq = pair.indexOf('=');
        if (eq > 0) {
          cookies[pair.substring(0, eq).trim()] =
              pair.substring(eq + 1).trim();
        }
      }
      // SUB/SUBP 至少要有 SUB 才算成功
      return cookies.containsKey('SUB') ? cookies : null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  // ---------- 工具 ----------

  static String _pick(Iterable<Object?> values) {
    for (final v in values) {
      if (v != null && '$v'.isNotEmpty) return '$v';
    }
    return '';
  }

  static int? _intOf(Object? v) =>
      v is num ? v.toInt() : int.tryParse('${v ?? ''}');

  /// 从 weibo.com/{uid}/{id} 或 m.weibo.cn/status/{bid} 提取 ID
  /// 末段两种形态 m.weibo.cn show 接口均接受（已实测）：
  ///   - 纯数字 mid（如 weibo.com/2792519675/5361662556377595）
  ///   - base62 bid（如 weibo.com/u/1234567/PgZqaOCt）
  String? _extractBid(String url) {
    final uri = Uri.parse(url);
    final segments =
        uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return null;
    if (segments.length >= 2 && segments.first == 'status') {
      return segments[1];
    }
    final last = segments.last;
    // 数字 mid（u/数字用户ID/数字mid 也是这个形态）
    if (RegExp(r'^\d{15,22}$').hasMatch(last)) return last;
    // base62 bid
    if (RegExp(r'^[0-9A-Za-z]{9,16}$').hasMatch(last) &&
        !RegExp(r'^\d+$').hasMatch(last)) {
      return last;
    }
    return null;
  }

  String _stripHtml(String s) =>
      s.replaceAll(RegExp(r'<[^>]+>'), '').trim();
}
