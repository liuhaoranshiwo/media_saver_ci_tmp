import 'dart:convert';
import 'dart:io' show HttpException, HttpHeaders;
import '../http_util.dart';
import '../../models/parsed_media.dart';
import '../app_logger.dart';
import '../parser_service.dart';

/// 闲鱼解析器（build 123 重写）
///
/// 旧实现只从分享页 HTML 抠 `og:image`，最多一张主图 —— 那是真正的降级方案。
/// 本版走商品详情 mtop 接口，能拿到**全部原图**（实测 4 张 1440×1920）。
///
/// ---- 接口与签名（2026-11-26 纯 HTTP 实测确认）----
/// POST `https://h5api.m.goofish.com/h5/mtop.taobao.idle.awesome.detail/1.0/`
///   query: jsv=2.7.2 & appKey=12574478 & t=<毫秒时间戳> & sign=... & v=1.0
///          & type=originaljson & accountSite=xianyu & dataType=json & api=...
///   body : `data={"itemId":"1102747889343"}` （x-www-form-urlencoded）
///
/// **两步法**（第一次请求不带 token 必然失败，目的就是拿 token）：
///   ① 无 sign 请求 → `ret: FAIL_SYS_TOKEN_EMPTY::令牌为空`
///      但响应 Set-Cookie 下发：
///        `_m_h5_tk=<token>_<过期时间戳>; Path=/; Domain=.goofish.com`
///        `_m_h5_tk_enc=<enc>`
///   ② `sign = md5(token & t & appKey & data)`（token 是 `_m_h5_tk` 值里
///      **下划线前**那一段），带上完整两个 cookie + sign 再请求
///      → `ret: SUCCESS::调用成功`，48KB 数据
///
/// ⚠️ 两个必须踩对的细节（第一次实测就是在这挂的）：
///   · cookie 要传**完整值** `token_timestamp`，不能只传 token
///     否则服务端仍报 FAIL_SYS_TOKEN_EMPTY
///   · `_m_h5_tk_enc` 也必须一起带上
///
/// ---- 数据字段（实测）----
///   data.itemDO.title           标题
///   data.itemDO.desc            描述
///   data.itemDO.soldPrice       价格
///   data.itemDO.imageInfos[]    全部图片（本版主要收益）
///     .url        原图直链，形如
///                 http://img.alicdn.com/bao/uploaded/i4/xxx.jpg
///                 （**不带 `_640x640q90.jpg` 这类缩放后缀**，就是原图）
///     .widthSize / .heightSize  原图宽高（实测 1440×1920）
///     .major      是否主图
///     .type       0 = 图片
///
/// ---- 风控 ----
/// 请求过密会返回 `RGV587_ERROR::SM::哎哟喂,被挤爆啦,请稍后重试!`（实测踩到）。
/// 本版策略：单次解析最多重试 3 轮，每轮之间退避 3s / 8s / 18s，
/// 并且两步请求之间也留 600ms 间隔。
///
/// ---- 视频（build 123）----
/// 被探测的商品（1102747889343）本身**没有视频**：itemDO 59 个字段逐个查过，
/// 全响应里没有任何 mp4 / vod 域名，只有 img/gw alicdn。
/// 带视频的商品该字段叫什么，实测无法确认 —— 因为 IP 之后被闲鱼
/// `x5secdata` 滑块风控锁定（`RGV587_ERROR::SM` + 不下发 `_m_h5_tk`），
/// 且推荐/搜索接口都拿不到可用的 itemId，找不到第二个样本。
///
/// 所以这里**不猜字段名**，改成「按值识别」：递归遍历整个 itemDO，
/// 凡是值形如视频直链（.mp4/.m3u8/.mov/.flv，或域名含 vod/play/video）
/// 就收下。这样无论闲鱼把它放在 `video`、`videos[]`、`videoUrl`、
/// `mediaInfo` 还是别的字段，都能命中；字段名对不上也不会误伤图片
/// （图片走 `.jpg/.png/...` 分支）。
///
/// 已知限制：若闲鱼把视频地址做成**加密串/需要再签一次名**（部分商品
/// 会把播放地址藏在 `mtop.taobao.idle.video.play` 之类的二级接口），
/// 本版取不到 —— 那种情况会以"未发现视频"呈现，不会报错。
class XianyuParser extends MediaParser {
  static const _appKey = '12574478';
  static const _api = 'mtop.taobao.idle.awesome.detail';
  static const _ver = '1.0';
  static const _h5api = 'https://h5api.m.goofish.com/h5';

  /// 移动 UA（闲鱼 H5 判定移动端）
  static const _ua = HttpUtil.iosUa;

  @override
  Future<ParseResult> parse(String url) async {
    AppLogger.log('xy', '开始解析: $url');

    // ---------- 1. 展开短链，取出 itemId ----------
    final (finalUrl, itemId, rawHtml) = await _resolveItemId(url);
    if (itemId == null) {
      // 短链页面里没有 itemId → 退回 og:image 降级方案（比直接失败好）
      return _fallbackFromHtml(url, rawHtml);
    }
    AppLogger.log('xy', 'itemId=$itemId (来自 $finalUrl)');

    // ---------- 2. mtop 两步法拿详情 ----------
    // 重试策略（实测依据）：闲鱼对**同一 IP 高频请求**会返回
    //   RGV587_ERROR::SM::哎哟喂,被挤爆啦,请稍后重试!
    // 且此时响应**不下发 `_m_h5_tk`** → 第一步就失败。
    // 真实用户一次解析只发 2 个请求（token + 详情），命中概率很低；
    // 三次退避后仍失败则降级 og:image，并把原因带回给用户。
    Map<String, dynamic>? itemDO;
    String? lastErr;
    final backoffs = [3, 8, 18];
    for (var round = 0; round < backoffs.length; round++) {
      try {
        itemDO = await _fetchDetail(itemId);
        if (itemDO != null) {
          break;
        }
        lastErr ??= '接口未返回 itemDO';
      } catch (e) {
        lastErr = '$e';
        AppLogger.log('xy', '第 ${round + 1} 轮失败: $e');
        if (_isRiskControl(lastErr)) {
          final wait = backoffs[round];
          AppLogger.log('xy', '命中风控，${wait}s 后重试');
          await Future.delayed(Duration(seconds: wait));
        } else if (round == 0) {
          await Future.delayed(const Duration(milliseconds: 600));
        }
      }
    }

    if (itemDO == null) {
      AppLogger.log('xy', 'mtop 详情未取到，降级 og:image');
      return _fallbackFromHtml(url, rawHtml, reason: lastErr);
    }

    // ---------- 3. 组装结果 ----------
    final title = (itemDO['title'] as String?)?.trim();
    final desc = (itemDO['desc'] as String?)?.trim() ?? '';
    final price = _priceText(itemDO);
    final items = <ParsedMediaItem>[];

    // 3.1 全部图片（imageInfos 是主战场）
    final infos = (itemDO['imageInfos'] as List?)?.whereType<Map>().toList() ??
        const <Map>[];
    for (final raw in infos) {
      final info = raw.cast<String, dynamic>();
      final u = (info['url'] as String?)?.trim();
      if (u == null || u.isEmpty) continue;
      // 原图直链，但仍防御性去掉可能附带的缩放后缀
      final original = _stripResize(u);
      if (items.any((e) => e.url == original)) continue;
      items.add(ParsedMediaItem(
        kind: MediaKind.image,
        url: original.startsWith('http://')
            ? original.replaceFirst('http://', 'https://')
            : original,
        width: (info['widthSize'] as num?)?.toInt(),
        height: (info['heightSize'] as num?)?.toInt(),
        ext: _extOf(original),
      ));
    }
    AppLogger.log('xy', '图片 ${items.length} 张（imageInfos 原始 ${infos.length} 条）');

    // 3.2 视频：按值识别，不依赖字段名（见文件头注释）
    final videos = _findVideoUrls(itemDO);
    // 视频项在结果页用 coverUrl 显示缩略图；闲鱼没有单帧封面可用，
    // 退一步拿首图当封面，让用户在网格里能认出这是哪个商品
    final poster = items.isNotEmpty ? items.first.url : null;
    for (final v in videos) {
      if (items.any((e) => e.url == v)) continue;
      items.add(ParsedMediaItem(
        kind: MediaKind.video,
        url: v,
        coverUrl: poster,
        ext: _videoExtOf(v),
      ));
    }
    if (videos.isNotEmpty) {
      AppLogger.log('xy', '视频 ${videos.length} 条');
    }

    // 3.3 og:image 兜底（imageInfos 缺失时的保险）
    if (items.isEmpty) {
      final og = RegExp(r'<meta[^>]+property="og:image"[^>]+content="([^"]*)"')
          .firstMatch(rawHtml)
          ?.group(1);
      if (og != null && og.isNotEmpty) {
        items.add(ParsedMediaItem(kind: MediaKind.image, url: og));
        AppLogger.log('xy', 'imageInfos 为空 → 用 og:image 兜底');
      }
    }

    // 3.4 全量兜底：连一张图都没有时才报错
    if (items.isEmpty) {
      throw ParseException('闲鱼商品未取到任何图片或视频（可能已下架或需要登录）');
    }

    final t = (title != null && title.isNotEmpty)
        ? title
        : (desc.isNotEmpty ? _firstLine(desc) : '闲鱼商品');
    // 价格 + 视频数（有视频时明确告知，否则用户不知道拿到了视频）
    final parts = <String>[];
    if (price.isNotEmpty) parts.add('售价 $price');
    if (videos.isNotEmpty) parts.add('含 ${videos.length} 个视频');
    final notice = parts.isEmpty ? null : parts.join(' · ');

    return ParseResult(
      platform: ParsePlatform.xianyu,
      sourceUrl: url,
      title: t,
      author: '',
      items: items,
      parsedAt: DateTime.now(),
      notice: notice,
    );
  }

  // ---------------- 短链 / itemId ----------------

  /// 展开短链并取出 itemId。
  ///
  /// 闲鱼/淘宝短链（m.tb.cn、2taobao.net 等）**不是 302**，而是返回一段
  /// 用 `window.location.replace(url)` 跳转的 HTML（实测 12.7KB）。
  /// 页面里带 `itemId=1102747889343`，所以直接从 HTML 里抠，
  /// 不必真的跟到 h5.m.goofish.com（省一次请求，也少一次风控机会）。
  Future<(String, String?, String)> _resolveItemId(String url) async {
    // 已经是商品页 → 直接从 URL 取
    final direct = _itemIdFromUrl(url);
    if (direct != null) {
      final (finalUrl, html) = await _safeGet(url);
      return (finalUrl, direct, html);
    }

    String finalUrl = url;
    String html = '';
    try {
      final r = await HttpUtil.getWithRedirects(url, ua: _ua);
      finalUrl = r.$1;
      html = r.$2;
    } catch (e) {
      AppLogger.log('xy', '短链请求失败: $e');
    }

    // ① 重定向后的 URL 里可能已带 itemId
    var id = _itemIdFromUrl(finalUrl);
    // ② 页面 HTML 里抠（跳转脚本里一定有）
    id ??= RegExp(r'itemId[=%22]*(\d{8,})').firstMatch(html)?.group(1);
    id ??= RegExp(r'"itemId"\s*:\s*"?(\d{8,})').firstMatch(html)?.group(1);
    id ??= RegExp(r'id=(\d{8,})').firstMatch(html)?.group(1);

    return (finalUrl, id, html);
  }

  String? _itemIdFromUrl(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return null;
    for (final k in ['itemId', 'id', 'item_id']) {
      final v = u.queryParameters[k];
      if (v != null && RegExp(r'^\d{8,}$').hasMatch(v)) return v;
    }
    final m = RegExp(r'/(?:item|detail)/(\d{8,})').firstMatch(u.path);
    return m?.group(1);
  }

  Future<(String, String)> _safeGet(String url) async {
    try {
      return await HttpUtil.getWithRedirects(url, ua: _ua);
    } catch (e) {
      return (url, '');
    }
  }

  // ---------------- mtop 两步法 ----------------

  /// 返回 itemDO；失败抛异常（含 RGV587 风控标记，供上层退避）
  Future<Map<String, dynamic>?> _fetchDetail(String itemId) async {
    final tok = await _fetchToken(itemId);
    if (tok == null) {
      throw HttpException('未取到 _m_h5_tk token');
    }
    final tokenStr = tok.$1;
    final cookieHeader = tok.$2;

    // 两步之间留间隔，降低风控概率
    await Future.delayed(const Duration(milliseconds: 600));

    final dataStr = jsonEncode({'itemId': itemId});
    final t = DateTime.now().millisecondsSinceEpoch;
    final sign = _md5('$tokenStr&$t&$_appKey&$dataStr');
    final json = await _postMtop(
      dataStr: dataStr,
      t: t,
      sign: sign,
      cookies: cookieHeader,
      itemId: itemId,
    );

    final ret = (json['ret'] as List?)?.cast<String>() ?? const [];
    final retStr = ret.isEmpty ? '' : ret.first;
    if (!retStr.contains('SUCCESS')) {
      throw HttpException(retStr.isEmpty ? '未知错误' : retStr);
    }
    final data = json['data'];
    if (data is! Map) return null;
    final item = (data as Map)['itemDO'];
    return item is Map ? item.cast<String, dynamic>() : null;
  }

  /// 第 ① 步：不带 token 请求，只为从 Set-Cookie 拿 `_m_h5_tk`。
  /// 返回 (token, cookieHeader)；拿不到返回 null。
  Future<(String, String)?> _fetchToken(String itemId) async {
    final dataStr = jsonEncode({'itemId': itemId});
    final t = DateTime.now().millisecondsSinceEpoch;
    final resp = await _rawPost(
      dataStr: dataStr,
      t: t,
      sign: '',
      cookieHeader: null,
      itemId: itemId,
    );

    final setCookies = resp.$2;
    String? tkFull; // token_timestamp 完整值
    String? enc;
    for (final c in setCookies) {
      final kv = c.split(';').first.trim();
      if (kv.startsWith('_m_h5_tk=') && !kv.startsWith('_m_h5_tk_enc=')) {
        tkFull = kv.substring('_m_h5_tk='.length);
      } else if (kv.startsWith('_m_h5_tk_enc=')) {
        enc = kv.substring('_m_h5_tk_enc='.length);
      }
    }
    AppLogger.log('xy', '① token: ${tkFull == null ? "未拿到" : "已拿到"} '
        'enc=${enc == null ? "无" : "有"}');

    if (tkFull == null) return null;
    // token 本体 = 下划线前那段；cookie 必须回传**完整** tkFull
    final token = tkFull.split('_').first;
    final cookieHeader = enc != null
        ? '_m_h5_tk=$tkFull; _m_h5_tk_enc=$enc'
        : '_m_h5_tk=$tkFull';
    return (token, cookieHeader);
  }

  Future<Map<String, dynamic>> _postMtop({
    required String dataStr,
    required int t,
    required String sign,
    required String? cookies,
    required String itemId,
  }) async {
    final r = await _rawPost(
      dataStr: dataStr,
      t: t,
      sign: sign,
      cookieHeader: cookies,
      itemId: itemId,
    );
    final body = r.$3;
    try {
      final j = jsonDecode(body) as Map;
      return j.cast<String, dynamic>();
    } catch (_) {
      final head = body.length > 80 ? body.substring(0, 80) : body;
      throw HttpException('响应非 JSON（长度 ${body.length}）：$head');
    }
  }

  /// 底层 POST：返回 (状态码, Set-Cookie 列表, body)
  Future<(int, List<String>, String)> _rawPost({
    required String dataStr,
    required int t,
    required String sign,
    required String? cookieHeader,
    required String itemId,
  }) async {
    final query = [
      'jsv=2.7.2',
      'appKey=$_appKey',
      't=$t',
      if (sign.isNotEmpty) 'sign=$sign',
      'v=$_ver',
      'type=originaljson',
      'accountSite=xianyu',
      'dataType=json',
      'timeout=20000',
      'api=$_api',
      'sessionOption=AutoLoginOnly',
    ].join('&');
    final endpoint = '$_h5api/$_api/$_ver/?$query';

    final client = HttpUtil.newHttpClient(ua: _ua);
    try {
      final req = await client.postUrl(Uri.parse(endpoint));
      req.headers.set(HttpHeaders.contentTypeHeader,
          'application/x-www-form-urlencoded; charset=utf-8');
      req.headers.set(HttpHeaders.acceptHeader,
          'application/json, text/plain, */*');
      req.headers.set('Origin', 'https://h5.m.goofish.com');
      req.headers.set('Referer',
          'https://h5.m.goofish.com/item?forceFlush=1&itemId=$itemId&id=$itemId');
      if (cookieHeader != null) {
        req.headers.set(HttpHeaders.cookieHeader, cookieHeader);
      }
      // ⚠️ 显式 Content-Length：不设会被 mtop 网关拒（chunked 不受支持）
      // 用 encodeComponent（空格 → %20）而不是 encodeQueryComponent（空格 → +）：
      // 实测抓到的原始 body 是 `data=%7B%22itemId%22%3A%221102747889343%22%7D`，
      // token 与 sign 都对不上 `+` 形式，必须保持一致。
      final payload = 'data=${Uri.encodeComponent(dataStr)}';
      final bytes = utf8.encode(payload);
      req.headers.set(HttpHeaders.contentLengthHeader, '${bytes.length}');
      req.add(bytes);

      final resp = await req.close().timeout(const Duration(seconds: 25));
      final setCookies = resp.headers[HttpHeaders.setCookieHeader] ?? const <String>[];
      final body = await resp.transform(utf8.decoder).join();
      AppLogger.log('xy', 'POST $endpoint → ${resp.statusCode} ${body.length}B');
      return (resp.statusCode, setCookies, body);
    } finally {
      client.close();
    }
  }

  // ---------------- 降级 & 工具 ----------------

  /// 是否是闲鱼风控/限流（实测原文 `RGV587_ERROR::SM::哎哟喂,被挤爆啦,请稍后重试!`）
  static bool _isRiskControl(String err) =>
      err.contains('RGV587') ||
      err.contains('被挤爆') ||
      err.contains('令牌为空') ||
      err.contains('FAIL_SYS_TOKEN');

  /// mtop 失败时的降级：沿用旧的分享页 HTML 提取（至少给一张主图）
  Future<ParseResult> _fallbackFromHtml(String url, String html,
      {String? reason}) async {
    var h = html;
    if (h.isEmpty) {
      try {
        final r = await HttpUtil.getWithRedirects(url, ua: _ua);
        h = r.$2;
      } catch (_) {}
    }
    final items = <ParsedMediaItem>[];

    final ogImage =
        RegExp(r'<meta[^>]+property="og:image"[^>]+content="([^"]*)"')
            .firstMatch(h)
            ?.group(1);
    final ogTitle =
        RegExp(r'<meta[^>]+property="og:title"[^>]+content="([^"]*)"')
            .firstMatch(h)
            ?.group(1);

    // 页面里散落的 alicdn 商品图也一并收（去重 + 去缩放后缀）
    final re = RegExp(r'https?:\\?/\\?/[^"\s]*?img\.alicdn\.com[^"\s]*');
    for (final m in re.allMatches(h)) {
      final raw = m.group(0)!.replaceAll(r'\/', '/');
      if (!RegExp(r'\.(jpg|jpeg|png|webp)').hasMatch(raw.toLowerCase())) continue;
      final orig = _stripResize(raw);
      if (items.any((e) => e.url == orig)) continue;
      // 过滤 UI 小图标（144x144 之类）
      if (RegExp(r'-(2-tps-|tps-)\d{1,3}-\d{1,3}').hasMatch(orig)) continue;
      items.add(ParsedMediaItem(kind: MediaKind.image, url: orig));
    }
    if (items.isEmpty && ogImage != null && ogImage.isNotEmpty) {
      items.add(ParsedMediaItem(kind: MediaKind.image, url: ogImage));
    }

    if (items.isEmpty) {
      final why = reason == null
          ? ''
          : _isRiskControl(reason)
              ? '闲鱼接口限流（短时间内请求过多）。'
              : '接口错误（${_shorten(reason)}）。';
      throw ParseException(
          '闲鱼解析受限：$why'
          '请等 1~2 分钟再试，或直接在闲鱼 App 内保存');
    }

    AppLogger.log('xy', '降级模式拿到 ${items.length} 张图');
    return ParseResult(
      platform: ParsePlatform.xianyu,
      sourceUrl: url,
      title: (ogTitle != null && ogTitle.isNotEmpty) ? ogTitle : '闲鱼商品',
      author: '',
      items: items,
      parsedAt: DateTime.now(),
      notice: reason != null && _isRiskControl(reason)
          ? '闲鱼接口限流，当前只取到 ${items.length} 张图（降级模式）。'
              '等 1~2 分钟后重新解析可获取全部原图'
          : '接口受限，当前为降级模式，可能只取到部分图片',
    );
  }

  static String _shorten(String s) =>
      s.length > 40 ? '${s.substring(0, 40)}…' : s;

  /// 去掉 alicdn 缩放后缀，取原图：
  /// `...jpg_640x640q90.jpg` → `...jpg`
  static String _stripResize(String url) {
    var u = url;
    // 常见形态 1: xxx.jpg_640x640q90.jpg
    u = u.replaceAllMapped(
        RegExp(r'(\.(?:jpg|jpeg|png|webp|gif))_[\d]+x[\d]+[a-z0-9]*\.(?:jpg|jpeg|png|webp|gif)$',
            caseSensitive: false),
        (m) => m.group(1)!);
    // 常见形态 2: xxx.jpg_400x400.jpg
    u = u.replaceAllMapped(
        RegExp(r'(\.(?:jpg|jpeg|png|webp|gif))_[\d]+x[\d]+\.(?:jpg|jpeg|png|webp|gif)$',
            caseSensitive: false),
        (m) => m.group(1)!);
    // 形态 3: xxx.jpg@640w_640h
    u = u.replaceAll(RegExp(r'@[\d]+[wh][_a-z0-9]*$', caseSensitive: false), '');
    return u;
  }

  /// 递归扫描整个 itemDO，按**值的形态**找视频直链（不依赖字段名）。
  ///
  /// 判定：http(s) 开头、且 ①路径后缀是视频容器格式，或 ②域名带
  /// vod/play/video 且路径疑似媒体（排除纯接口域名如 h5api）。
  /// 去重后按出现顺序返回。
  static List<String> _findVideoUrls(dynamic node) {
    final out = <String>[];
    void walk(dynamic n, int depth) {
      if (depth > 12) return; // 防异常深度（正常 itemDO 最多 4~5 层）
      if (n is String) {
        final v = _asVideoUrl(n);
        if (v != null && !out.contains(v)) out.add(v);
      } else if (n is List) {
        for (final e in n) {
          walk(e, depth + 1);
        }
      } else if (n is Map) {
        for (final e in n.values) {
          walk(e, depth + 1);
        }
      }
    }

    walk(node, 0);
    return out;
  }

  /// 单个值 → 视频直链（不是视频返回 null）
  ///
  /// 注意**排除 m3u8/HLS**：下载器只会把播放列表当普通文件存下来
  /// （得到一段文本而非视频），需要分片下载 + 合并才能出片，
  /// 本版没有这条路 —— 与其存个坏文件，不如不认。
  static String? _asVideoUrl(String s) {
    final t = s.trim();
    if (t.length < 12 || t.length > 2000) return null;
    if (!t.startsWith('http://') && !t.startsWith('https://')) return null;
    // 整串必须是 URL（排除夹在文案里的链接）
    if (t.contains(' ') || t.contains('\n')) return null;

    final u = Uri.tryParse(t);
    if (u == null || u.host.isEmpty) return null;
    final path = u.path.toLowerCase();
    final host = u.host.toLowerCase();

    // ① 路径后缀即视频容器格式 —— 最可靠的判据（单文件，可直接下载）
    final byExt = RegExp(r'\.(mp4|mov|flv|mkv|avi|wmv)$').hasMatch(path);
    // ② 阿里视频云（vod）域名 + 非图片路径
    final byVod = (host.contains('vod') || host.contains('play')) &&
        !RegExp(r'\.(jpg|jpeg|png|webp|gif)$').hasMatch(path);
    if (!byExt && !byVod) return null;
    // HLS 播放列表取不到成品文件
    if (RegExp(r'\.(m3u8|mpd)$').hasMatch(path)) return null;

    // 排除明确不是正片的东西
    if (path.contains('/cover') || path.contains('poster')) return null;

    final norm =
        t.startsWith('http://') ? t.replaceFirst('http://', 'https://') : t;
    return _stripResize(norm);
  }

  /// 视频扩展名（默认 mp4）
  static String _videoExtOf(String url) {
    final p = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    for (final e in const ['mp4', 'mov', 'flv', 'mkv']) {
      if (p.endsWith('.$e')) return e;
    }
    return 'mp4';
  }

  static String _extOf(String url) {
    final p = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    if (p.endsWith('.png')) return 'png';
    if (p.endsWith('.webp')) return 'webp';
    if (p.endsWith('.gif')) return 'gif';
    return 'jpg';
  }

  static String _firstLine(String s) {
    final i = s.indexOf('\n');
    final line = (i > 0 ? s.substring(0, i) : s).trim();
    return line.length > 40 ? '${line.substring(0, 40)}…' : line;
  }

  static String _priceText(Map<String, dynamic> item) {
    final p = item['soldPrice'];
    if (p is num) return '¥${_fmt(p)}';
    if (p is String && p.isNotEmpty) return '¥$p';
    final dp = item['defaultPrice'];
    if (dp is num) return '¥${_fmt(dp)}';
    return '';
  }

  static String _fmt(num n) {
    final d = n.toDouble();
    return d == d.roundToDouble()
        ? d.round().toString()
        : d.toStringAsFixed(2);
  }
}

/// MD5（纯 Dart 实现，避免引入 crypto 依赖）
///
/// 项目里没有 crypto 包，而为了一处签名加依赖会拖慢构建；
/// 这里用标准 RFC 1321 实现，输入只可能是 ASCII（token/数字/appKey/JSON）。
String _md5(String input) {
  final bytes = utf8.encode(input);

  // padding: 0x80 + 0...0 + 8 字节长度（小端）
  final msgLen = bytes.length;
  final paddedLen = (((msgLen + 8) ~/ 64) + 1) * 64;
  final padded = List<int>.filled(paddedLen, 0);
  for (var i = 0; i < msgLen; i++) {
    padded[i] = bytes[i];
  }
  padded[msgLen] = 0x80;
  final bitLen = msgLen * 8;
  for (var i = 0; i < 4; i++) {
    padded[paddedLen - 8 + i] = (bitLen >> (8 * i)) & 0xff;
  }
  // 高 4 字节是长度高位（本场景远小于 2^32，写 0 即可，已由 filled 保证）

  var a0 = 0x67452301;
  var b0 = 0xefcdab89;
  var c0 = 0x98badcfe;
  var d0 = 0x10325476;

  final s = [
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, //
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, //
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, //
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, //
  ];
  final k = _kTable;

  for (var off = 0; off < paddedLen; off += 64) {
    final m = List<int>.generate(16, (i) => 0);
    for (var i = 0; i < 16; i++) {
      final j = off + i * 4;
      m[i] = (padded[j] & 0xff) |
          ((padded[j + 1] & 0xff) << 8) |
          ((padded[j + 2] & 0xff) << 16) |
          ((padded[j + 3] & 0xff) << 24);
    }

    var a = a0, b = b0, c = c0, d = d0;
    for (var i = 0; i < 64; i++) {
      int f, g;
      if (i < 16) {
        f = (b & c) | (~b & d);
        g = i;
      } else if (i < 32) {
        f = (d & b) | (~d & c);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = b ^ c ^ d;
        g = (3 * i + 5) % 16;
      } else {
        f = c ^ (b | ~d);
        g = (7 * i) % 16;
      }
      final tmp = d;
      d = c;
      c = b;
      final sum = (a + f + k[i] + m[g]) & 0xffffffff;
      b = (b + _rotl(sum, s[i])) & 0xffffffff;
      a = tmp;
    }

    a0 = (a0 + a) & 0xffffffff;
    b0 = (b0 + b) & 0xffffffff;
    c0 = (c0 + c) & 0xffffffff;
    d0 = (d0 + d) & 0xffffffff;
  }

  final out = <int>[];
  for (final v in [a0, b0, c0, d0]) {
    for (var i = 0; i < 4; i++) {
      out.add((v >> (8 * i)) & 0xff);
    }
  }
  final sb = StringBuffer();
  for (final b in out) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

int _rotl(int x, int n) => ((x << n) | (x >> (32 - n))) & 0xffffffff;

/// MD5 的 K 常量表（floor(2^32*|sin(i+1)|)），预先算好避免运行时三角函数
const _kTable = <int>[
  0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a,
  0xa8304613, 0xfd469501, 0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
  0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
  0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453,
  0xd8a1e681, 0xe7d3fbc8, 0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
  0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
  0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9,
  0xf6bb4b60, 0xbebfbc70, 0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
  0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
  0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92,
  0xffeff47d, 0x85845dd1, 0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
  0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
];
