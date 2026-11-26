import 'dart:convert';
import '../http_util.dart';
import '../douyin_capture.dart';
import '../app_logger.dart';
import '../../models/parsed_media.dart';
import '../parser_service.dart';

/// 抖音解析器
///
/// 数据源 A（主路径，纯 HTTP 不依赖 WebView）：ttwid + 分享页 SSR
///   2026-11 实测：iesdouyin share 页在无 Cookie 时 SSR 只含 itemId；
///   携带 ttwid Cookie 后 SSR 即内嵌完整 videoInfoRes.item_list
///   （desc/author/video.play_addr/images 全有，与真浏览器一致）。
///   ttwid 获取：POST ttwid.bytedance.com/ttwid/union/register/ →
///   data.redirect_url（ixigua 回调）→ GET 回调页从 Set-Cookie 取 ttwid。
///   play_addr 为 playwm 带水印地址，playwm→play 替换仍有效（实测 8.8MB→6.9MB）。
///
/// 数据源 B（兜底）：WebView 捕获
///   DouyinCaptureView 让抖音 H5 自己跑起来，截获 detail 响应；
///   页面未返回 detail JSON 时兜底抓 <video>/<source> 播放地址与 DOM 图集。
class DouyinParser extends MediaParser {
  /// 作品类型路径：video=视频 note=图集 slides=2026-11 新版图集分享路径
  static final _idInUrl = RegExp(r'/(video|note|slides)/(\d+)');

  /// 作者主页：/user/{sec_uid}（桌面）或 /share/user/{sec_uid}（移动分享页）
  static final _userInUrl = RegExp(r'/user/([A-Za-z0-9_-]{10,})');

  static const _ttwidRegisterUrl =
      'https://ttwid.bytedance.com/ttwid/union/register/';
  /// 多组注册参数轮换（2026-11 实测 aid 1768/6383/2906 均可出 ticket），
  /// 主参数被风控时自动降级重试，降低 A1 失败率。
  static const _ttwidRegisterBodies = [
    '{"region":"cn","aid":1768,"needFid":false,"service":"www.ixigua.com",'
        '"migrate_info":{"ticket":"","source":"node"},"cbUrlProtocol":"https","union":true}',
    '{"region":"cn","aid":6383,"needFid":false,"service":"www.ixigua.com",'
        '"migrate_info":{"ticket":"","source":"node"},"cbUrlProtocol":"https","union":true}',
    '{"region":"cn","aid":2906,"needFid":false,"service":"www.ixigua.com",'
        '"migrate_info":{"ticket":"","source":"node"},"cbUrlProtocol":"https","union":true}',
  ];
  static final _ttwidInCookie = RegExp(r'ttwid=([^;\s]+)');

  @override
  Future<ParseResult> parse(String url) async {
    // 1. 展开短链拿作品 ID
    final (finalUrl, _) =
        await HttpUtil.getWithRedirects(url, ua: HttpUtil.iosUa);
    final m = _idInUrl.firstMatch(finalUrl);
    if (m == null) {
      // 非作品链接：优先识别作者主页（/user/{sec_uid} 或 sec_uid= 参数）。
      // 注意作品分享 URL 的 query 里也常带 sec_uid，所以先查作品 ID、后查主页。
      final userM = _userInUrl.firstMatch(finalUrl);
      final secUid = userM?.group(1) ??
          Uri.tryParse(finalUrl)?.queryParameters['sec_uid'];
      if (secUid != null && secUid.length >= 10) {
        return _parseUserProfile(secUid, url);
      }
      throw ParseException('抖音链接中未找到作品 ID（$finalUrl）');
    }
    final kindPath = m.group(1)!;
    final awemeId = m.group(2)!;
    // slides 页面无 SSR 数据，统一转 note 路径（SSR 与 WebView 捕获两路都用 note）
    final ssrKind = kindPath == 'slides' ? 'note' : kindPath;

    // 2. 数据源 A：ttwid + 分享页 SSR（纯 HTTP）
    var diagA = '';
    try {
      final r = await _viaTtwid(awemeId, kindPath, url);
      // SSR 是降级数据（images 无 live 字段，2026-11-08 手机日志证实）：
      // 图集里没识别到实况时，走 www note 页桌面 detail 兜底
      final live = await _tryDesktopLive(r, awemeId, url);
      return live ?? r;
    } on ParseException catch (e) {
      diagA = e.message;
      AppLogger.log('dy-parse', 'A路失败: ${e.message}');
    } catch (e) {
      diagA = 'ttwid路线异常:${e.toString().substring(0, e.toString().length.clamp(0, 120))}';
      AppLogger.log('dy-parse', 'A路异常: $diagA');
    }

    // 3. 数据源 B：WebView 捕获
    var diagB = '';
    try {
      final item = await DouyinCapture.instance
          .captureItem('https://www.iesdouyin.com/share/$ssrKind/$awemeId');
      if (item != null) {
        // 仅捕获到 <video> 播放地址的兜底（无 bit_rate 多档位）。
        // ⚠️ slides/note 图集作品：这个 <video> src 往往只是封面/首图预览视频
        //    （只有 1 段），不是完整图集 —— 2026-11-10 真机反馈"图集 3 视频只抓
        //    到 1 个"。必须先走桌面 detail 兜底拿完整图集（多实况），失败再退回。
        final srcOnly = videoSrcOnlyItem(item);
        if (srcOnly != null) {
          AppLogger.log('dy-parse', 'B路抓到<video> src，先走桌面 detail 兜底拿完整图集');
          final probe = ParseResult(
            platform: ParsePlatform.douyin,
            sourceUrl: url,
            title: '抖音作品',
            author: '',
            items: [const ParsedMediaItem(kind: MediaKind.image, url: '')],
            parsedAt: DateTime.now(),
          );
          final live = await _tryDesktopLive(probe, awemeId, url);
          if (live != null) return live;
          return ParseResult(
            platform: ParsePlatform.douyin,
            sourceUrl: url,
            title: '抖音作品',
            author: '',
            items: [srcOnly],
            parsedAt: DateTime.now(),
          );
        }
        // 仅捕获到图文页 DOM 图集（note 页无 detail 数据时的兜底）
        final imagesOnly =
            (item['__imagesOnly'] as List?)?.cast<String>();
        if (imagesOnly != null && imagesOnly.isNotEmpty) {
          final r = ParseResult(
            platform: ParsePlatform.douyin,
            sourceUrl: url,
            title: '抖音作品',
            author: '',
            items: imagesOnly
                .map((u) => ParsedMediaItem(kind: MediaKind.image, url: u))
                .toList(),
            parsedAt: DateTime.now(),
          );
          final live = await _tryDesktopLive(r, awemeId, url);
          return live ?? r;
        }
        final r = _buildResult(item, url);
        // 同 A 路：图集没识别到实况时走桌面 detail 兜底
        final live = await _tryDesktopLive(r, awemeId, url);
        return live ?? r;
      }
    } on ParseException {
      rethrow;
    } catch (e) {
      diagB = '捕获异常:${e.toString().substring(0, e.toString().length.clamp(0, 120))}';
      AppLogger.log('dy-parse', 'B路异常: $diagB');
    }
    if (diagB.isEmpty) diagB = '无数据';
    final failMsg = '抖音解析失败[A:$diagA|B:$diagB]，请稍后重试';
    AppLogger.log('dy-parse', '两路均失败');
    AppLogger.report(failMsg);
    throw ParseException(failMsg);
  }

  // ---------- 作者主页：抓取全部作品（2026-11-12 新增） ----------

  /// 主页链接（/user/{sec_uid}）→ 抓取作者全部作品。
  ///
  /// 匿名（未登录）：桌面页服务端只发首批 20 条，返回 notice 提示登录；
  /// 登录态（WebView cookie 已有 sessionid）：翻页到 has_more=false 全量。
  /// 每条 aweme item 结构与 detail 一致（实测探测确认），直接复用 _extractItems。
  Future<ParseResult> _parseUserProfile(String secUid, String sourceUrl) async {
    AppLogger.log('dy-user', '识别到作者主页链接，启动主页抓取');
    // 注意：不能声明 final —— try/catch 两处赋值会触发 Dart 流分析报错
    // （"Final variable 'cap' might already be assigned"，build 117 CI 实测）
    Map<String, dynamic>? cap;
    try {
      // budget 用 captureUserProfile 默认 150s（build 118：128 件 ≈ 7 页，
      // 登录态每页 2-4s + 空转容忍，100s 不够）
      cap = await DouyinCapture.instance.captureUserProfile(secUid);
    } catch (e) {
      AppLogger.log('dy-user', '主页抓取异常: $e');
      cap = null;
    }
    if (cap == null) {
      final msg = '主页抓取失败：页面未返回数据（稍后重试或检查链接）';
      AppLogger.log('dy-user', msg);
      AppLogger.report(msg);
      throw ParseException(msg);
    }

    final posts = (cap['__userPosts'] as List?)?.whereType<Map>().toList() ??
        const <Map>[];
    final hasMore = cap['__userMore'] == true;
    final nickname = (cap['__userNickname'] as String?) ?? '';
    final totalCount = (cap['__userCount'] as num?)?.toInt();
    final needLogin = cap['__userNeedLogin'] == true ||
        (!(cap['__userLoggedIn'] == true) && posts.isEmpty);

    // 匿名无数据：抖音已不向未登录用户返回作品列表（2026-11-26 实测）
    // → 抛 needLogin 异常，首页渲染"登录抖音"按钮，登录后自动重试
    if (posts.isEmpty && needLogin) {
      final msg = '抖音主页作品需要登录后抓取'
          '${totalCount != null && totalCount > 0 ? "（该作者共 $totalCount 件）" : ""}'
          '。抖音已不再向未登录用户返回作品列表';
      AppLogger.log('dy-user', msg);
      throw ParseException(msg, needLogin: true);
    }

    // 已登录但 posts 为空 → 明确失败（不是登录问题，是风控/网络）
    if (posts.isEmpty) {
      final msg = '主页抓取失败：已登录但未获取到作品列表（平台风控或网络，稍后重试）';
      AppLogger.log('dy-user', msg);
      AppLogger.report(msg);
      throw ParseException(msg);
    }

    final items = <ParsedMediaItem>[];
    var skipped = 0;
    for (final p in posts) {
      try {
        final one = _extractItems((p as Map).cast<String, dynamic>());
        if (one == null) {
          skipped++;
          continue;
        }
        items.addAll(one);
      } catch (_) {
        skipped++;
      }
    }
    AppLogger.log('dy-user',
        '主页转换完成: 作品 ${posts.length} 件 → 媒体 ${items.length} 项（跳过 $skipped）');

    if (items.isEmpty) {
      throw ParseException('主页作品全部无法解析（私密或审核中的作品不可下载）');
    }

    // 截断提示：区分"未登录"（服务端锁死）与"登录了但翻页中断"（网络/风控/轮次用尽），
    // 两者的用户动作不同：前者扫码登录重抓，后者直接点重试。
    //
    // ⚠️ build 121 修正：原来只在 `hasMore==true` 时才提示，导致
    //   「抓取被 maxIdle/预算截断、但服务端 has_more 恰好已是 false」时
    //   **静默少给作品**（用户看到的就是"作品爬不全"却没有任何提示）。
    //   现在改为：只要「已抓数量 < 作者作品总数」就提示，不再依赖 has_more。
    //
    // ⚠️ build 122 修正（用户真机反馈"结果页数量对不上"）：
    //   ① `aweme_count` 是**账号总量**，含私密/审核中/仅好友可见的作品，
    //      `aweme/post` 永远取不到这些 → 它只能当"参考上限"，**不能当应抓数**。
    //      原来 `grabbed >= total` 就断言"已抓取全部"，反而会漏报；
    //      真正的完成依据是服务端 `has_more == false`。
    //   ② `posts.length` 是**作品数**，`items.length` 是**媒体项数**
    //      （一个图集作品可含 3 个视频项），两者天生不等 —— 文案必须点明。
    String? notice;
    final loggedIn = cap['__userLoggedIn'] == true;
    final total = totalCount ?? 0;
    final grabbed = posts.length;          // 作品数
    final itemCount = items.length;        // 媒体项数（图集会多于作品数）
    final complete = cap['__userComplete'] == true; // 服务端明确无下一页
    final looksShort = total > 0 && grabbed < total;
    // 完成判定：服务端说没下一页了才算抓全（maxItems 截断不算）
    final reallyComplete = complete && !hasMore;
    if (reallyComplete && !looksShort) {
      // 服务端到底了，且数量也对得上 → 唯一能宣称"全部"的情况
      notice = '已抓取该作者全部 $grabbed 件作品'
          '${itemCount != grabbed ? "，共 $itemCount 个媒体文件（图集合集/实况会拆成多项）" : ""}';
    } else if (reallyComplete && looksShort) {
      // 服务端到底了，但仍少于账号总数 → 差额是取不到的作品（私密/审核中/仅好友）
      // 这类差额重抓也拿不到，所以 complete 仍为 true，不给重抓入口 ——
      // 文案不能写"可点下方重新抓取"（按钮不会出现，会自相矛盾）
      notice = '已抓取 $grabbed 件公开作品'
          '（账号共 $total 件）'
          '，差额可能是私密/审核中/仅好友可见的作品，这部分无法抓取。'
          '${itemCount != grabbed ? "共 $itemCount 个媒体文件。" : ""}';
    } else if (!loggedIn) {
      notice = total > grabbed && total > 0
          ? '当前未登录抖音，只能抓取最近 $grabbed 件（账号共 $total 件）。'
              '点下方登录后自动抓取全部公开作品'
          : '当前未登录抖音，仅抓取到 $grabbed 件。点下方登录后自动抓取全部作品';
    } else {
      notice = (total > grabbed && total > 0)
          ? '已抓取 $grabbed 件（账号共 $total 件）—— 翻页提前结束'
              '（网络/风控/轮次用尽），可点下方重新抓取'
          : '翻页提前结束（网络/风控/轮次用尽），已抓 $grabbed 件，可点下方重新抓取';
      if (itemCount != grabbed) {
        notice = '$notice（共 $itemCount 个媒体文件）';
      }
    }

    // 标题也改用「作品数 + 媒体项数」双口径，避免用户把媒体项当成作品数
    final titleBase = nickname.isEmpty ? '作者主页作品' : '$nickname 的作品';
    final titleSuffix = itemCount != grabbed
        ? '（$grabbed 件作品 · $itemCount 个文件）'
        : '（$grabbed 件）';

    return ParseResult(
      platform: ParsePlatform.douyin,
      sourceUrl: sourceUrl,
      title: '$titleBase$titleSuffix',
      author: nickname,
      items: items,
      parsedAt: DateTime.now(),
      notice: notice,
      // 只有「服务端到底 + 数量对得上」才算真正抓全；
      // 「到底但少于账号总数」差额是取不到的私密作品，重抓也没用 → 同样不给重抓
      complete: reallyComplete,
      isProfile: true,
    );
  }

  // ---------- 数据源 A：ttwid + 分享页 SSR（纯 HTTP 主路径） ----------

  /// 图集无实况时的桌面兜底：
  /// 结果里已有实况/或不是图片作品 → 返回 null（直接用原结果）；
  /// 否则用 www note 页桌面 UA 兜底（captureDesktopDetail 三级递进）：
  /// ① detail 接口结果最优先（实况字段最全，图集→多视频）
  /// ② DOM <video> 直链（免接口风控）：
  ///    - 单图动图：1 图 = 1 视频，DOM 单视频可信
  ///    - 多图图集：DOM 单视频是封面/首图预览，绝不采纳
  ///      （2026-11-10 真机"图集 3 视频只抓 1 个"教训）；
  ///      仅当 DOM 视频数 == 图集张数时按序配对
  /// ③ 都拿不到 → 保留原结果
  Future<ParseResult?> _tryDesktopLive(
      ParseResult r, String awemeId, String sourceUrl) async {
    final firstKind = r.items.firstOrNull?.kind;
    if (firstKind != MediaKind.image) return null; // 视频作品或空结果不兜底
    if (r.items.any((i) => i.kind == MediaKind.livePhoto)) return null;
    final gallery =
        r.items.where((i) => i.kind == MediaKind.image).toList();
    AppLogger.log('dy-live', '图集未识别到实况，启动桌面兜底');
    try {
      final d = await DouyinCapture.instance.captureDesktopDetail(
          'https://www.douyin.com/note/$awemeId',
          expectedVideos: gallery.length);
      if (d == null) {
        // 桌面页没拿到（超时/403）→ 退回更轻量的分享页 detail
        return await _viaShareDetail(awemeId, sourceUrl);
      }

      // ① detail 接口路最优先：图集→视频/实况均为兜底成功（单图动图、多图
      //    实况 aweme_type=68 输出的是多个视频项）。
      try {
        final dr = _buildResult(d, sourceUrl);
        final hasMedia = dr.items.any((i) =>
            i.kind == MediaKind.livePhoto || i.kind == MediaKind.video);
        if (hasMedia) {
          AppLogger.log('dy-live',
              '桌面兜底成功(detail): ${dr.items.map((i) => i.kind.name).join(",")}');
          return dr;
        }
      } catch (_) {/* detail 无可用项，走 DOM 直链 */}

      // ② DOM <video> 直链路：桌面页渲染的作品视频（带签名 douyinvod 直链）。
      //    capture 侧已主动翻页逐张采集（实况视频懒加载）。
      //    SSR 的 title/author 已有，直接沿用。
      final domVideos =
          (d['__desktopVideos'] as List?)?.cast<String>() ?? const <String>[];
      final domBgm = d['__desktopBgm'] as String?;
      if (gallery.length == 1 && domVideos.isNotEmpty) {
        // 单图动图：唯一的 DOM 视频就是作品本体（用户实测确认）
        final v = domVideos.first;
        AppLogger.log('dy-live', '桌面 DOM 兜底: 单图动图→1视频');
        return ParseResult(
          platform: ParsePlatform.douyin,
          sourceUrl: sourceUrl,
          title: r.title,
          author: r.author,
          items: [
            ParsedMediaItem(
              kind: MediaKind.video,
              url: v,
              coverUrl: gallery.first.url.isNotEmpty ? gallery.first.url : null,
              audioUrl: domBgm ?? _musicUrl(d),
              width: gallery.first.width,
              height: gallery.first.height,
              ext: 'mp4',
            )
          ],
          parsedAt: DateTime.now(),
        );
      }
      if (gallery.length > 1 && domVideos.length == gallery.length) {
        // 多图图集：【严格数量匹配】才按序配对（图作封面）。
        // 2026-11-11：撤回 109 的"部分配对"——数量配不上说明采集不全或
        // 混入推荐流视频，硬配必然错目标（真机"全解析错目标"教训）。
        // 配不上时保留原图集，宁缺勿错。
        final bgm = domBgm ?? _musicUrl(d);
        final paired = <ParsedMediaItem>[];
        for (var i = 0; i < domVideos.length; i++) {
          paired.add(ParsedMediaItem(
            kind: MediaKind.video,
            url: domVideos[i],
            coverUrl: gallery[i].url.isNotEmpty ? gallery[i].url : null,
            audioUrl: bgm,
            width: gallery[i].width,
            height: gallery[i].height,
            ext: 'mp4',
          ));
        }
        AppLogger.log('dy-live',
            '桌面 DOM 配对: ${domVideos.length}视频 ↔ ${gallery.length}图（严格匹配）');
        return ParseResult(
          platform: ParsePlatform.douyin,
          sourceUrl: sourceUrl,
          title: r.title,
          author: r.author,
          items: paired,
          parsedAt: DateTime.now(),
        );
      }
      AppLogger.log('dy-live',
          '桌面兜底无实况/视频(DOM视频=${domVideos.length} 图集=${gallery.length})，保留原结果');
    } catch (e) {
      AppLogger.log('dy-live', '桌面兜底异常: $e');
    }
    return await _viaShareDetail(awemeId, sourceUrl);
  }

  /// 兜底③（2026-11-11 新增）：iesdouyin 分享页上下文的 detail。
  ///
  /// 桌面 www note 页在真机上常 403（Uifid Not Found）或超时，而 iesdouyin
  /// 分享页更轻、页面 cookie 就绪更快，页面上下文 fetch detail 同样能拿到
  /// aweme_type=68 的 images[i].video.play_addr（可下载的签名直链）。
  Future<ParseResult?> _viaShareDetail(
      String awemeId, String sourceUrl) async {
    try {
      final item = await DouyinCapture.instance.captureItem(
          'https://www.iesdouyin.com/share/note/$awemeId',
          timeout: const Duration(seconds: 14));
      if (item != null) {
        final rr = _buildResult(item, sourceUrl);
        final hasMedia = rr.items.any(
            (i) => i.kind == MediaKind.livePhoto || i.kind == MediaKind.video);
        if (hasMedia) {
          AppLogger.log('dy-live',
              '分享页 detail 兜底成功: ${rr.items.map((i) => i.kind.name).join(",")}');
          return rr;
        }
        AppLogger.log('dy-live', '分享页 detail 无实况/视频，保留原结果');
      }
    } catch (e) {
      AppLogger.log('dy-live', '分享页 detail 兜底异常: $e');
    }
    return null;
  }


  Future<ParseResult> _viaTtwid(
      String awemeId, String kindPath, String sourceUrl) async {
    final ttwid = await _fetchTtwid();
    if (ttwid == null) throw ParseException('A1:ttwid注册失败');
    // ⚠️ 2026-11-06 实测：slides 分享页是客户端渲染壳（无内嵌 _ROUTER_DATA），
    // 同一作品改用 note 路径请求即有完整 SSR（图集/实况都在）
    final ssrKind = kindPath == 'slides' ? 'note' : kindPath;
    final (_, html) = await HttpUtil.getWithRedirects(
      'https://www.iesdouyin.com/share/$ssrKind/$awemeId/',
      ua: HttpUtil.iosUa,
      headers: {'Cookie': 'ttwid=$ttwid'},
    );

    final jsonStr = _extractRouterData(html);
    if (jsonStr == null) throw ParseException('A2:SSR无_ROUTER_DATA');
    final data = jsonDecode(jsonStr) as Map<String, dynamic>;

    final itemList = _findItemList(data);
    if (itemList == null || itemList.isEmpty) {
      throw ParseException('A3:未找到item_list');
    }
    return _buildResult(itemList.first as Map<String, dynamic>, sourceUrl);
  }

  /// 注册 ttwid：register 接口返回 redirect_url（ixigua 回调页），
  /// GET 回调页从 Set-Cookie 里提取 ttwid（2026-11 实测该链路有效）。
  /// 多组 aid 参数依次尝试，任一成功即返回。
  Future<String?> _fetchTtwid() async {
    for (final body in _ttwidRegisterBodies) {
      try {
        final (status, _, respBody) = await HttpUtil.postJsonRaw(
          _ttwidRegisterUrl,
          body: body,
        );
        if (status != 200) continue;
        final data = jsonDecode(respBody) as Map<String, dynamic>;
        // 2026-11-09 实测：redirect_url 直接在响应顶层
        // （{"status_code":0,...,"redirect_url":"https://..."}），
        // 兼容旧结构 data['data']['redirect_url'] 两种形态
        final redirect =
            ((data['data'] ?? const {}) as Map)['redirect_url'] as String? ??
                data['redirect_url'] as String?;
        if (redirect == null || redirect.isEmpty) continue;

        final (st2, cookies, _) = await HttpUtil.getRaw(redirect);
        if (st2 >= 400) continue;
        for (final c in cookies) {
          final m = _ttwidInCookie.firstMatch(c);
          if (m != null) return m.group(1);
        }
      } catch (_) {
        continue; // 换下一组参数重试
      }
    }
    return null;
  }

  // ---------- item → ParseResult（捕获/SSR 共用） ----------

  /// 核心转换（安静版）：aweme item → 媒体项列表。
  /// 不抛异常、不上报（作者主页批量解析逐条调用，私密/审核中的作品直接跳过）。
  List<ParsedMediaItem>? _extractItems(Map<String, dynamic> item) {
    final items = <ParsedMediaItem>[];

    // 图集（含实况：live_photo 标志 + live_image 配对视频双重确认）
    final images = item['images'] as List?;
    // 动图/实况作品：aweme_type=68 —— 每张带视频源的图 = 一个视频
    // （2026-11-09 用户确认：单图是视频、多图是多个视频），统一输出视频文件、
    // 图作封面，不再包装成 livePhoto。1 图→1 视频，3 图→3 视频。
    final isGifNote = '${item['aweme_type'] ?? ''}' == '68';
    // 抖音动图 BGM：aweme.music.play_url（整个作品共享的音轨，mp3）。
    // play_addr 是无声画面（BGM 播放器实时混音），保存时与画面合成。
    final musicUrl = isGifNote ? _musicUrl(item) : null;
    if (images != null) {
      for (final img in images) {
        final map = img as Map<String, dynamic>;
        final urls = (map['url_list'] as List?)?.cast<String>() ?? const [];
        if (urls.isEmpty) continue;
        // 抖音实况（2026-11 实测存在多种结构，全部兼容）：
        //   ① images[i].live_photo = true + images[i].live_image.url_list
        //   ② images[i].live_photo = true + images[i].video.play_addr(.h264)
        //   ③ 仅 images[i].video 存在（aweme_type 42/68 等实况笔记）
        final liveFlag =
            map['live_photo'] == true || map['live_photo'] == 'true';
        final liveUrls = _liveVideoUrls(map);
        if (isGifNote && liveUrls.isNotEmpty) {
          // 动图作品：每张带视频的图 → 一个视频项（图作封面）。
          // audioUrl 带上 BGM 音轨，保存时合成"无水印画面 + BGM"。
          items.add(ParsedMediaItem(
            kind: MediaKind.video,
            url: liveUrls.first,
            coverUrl: urls.first,
            audioUrl: musicUrl,
            width: (map['width'] as num?)?.toInt(),
            height: (map['height'] as num?)?.toInt(),
            ext: 'mp4',
          ));
        } else if ((liveFlag || liveUrls.isNotEmpty) && liveUrls.isNotEmpty) {
          items.add(ParsedMediaItem(
            kind: MediaKind.livePhoto,
            url: urls.first,
            companionUrl: liveUrls.first,
            width: (map['width'] as num?)?.toInt(),
            height: (map['height'] as num?)?.toInt(),
            ext: 'jpg',
          ));
        } else {
          items.add(ParsedMediaItem(
            kind: MediaKind.image,
            url: urls.first,
            width: (map['width'] as num?)?.toInt(),
            height: (map['height'] as num?)?.toInt(),
          ));
        }
        // 诊断日志：逐张记录原始结构（判断为何没识别成实况），不改变任何逻辑
        List? vk;
        if (map['video'] is Map) {
          vk = (map['video'] as Map).keys.toList();
          vk.sort();
        }
        AppLogger.log('dy-img',
            '#${items.length - 1} live_photo=${map['live_photo']} '
            'video=${vk == null ? "无" : "keys:${vk.join(",")}"} '
            'live_image=${map['live_image'] is Map ? "有" : "无"} '
            'urlList=${urls.length} aweme_type=${item['aweme_type']}');
      }
    }

    // 视频：遍历 bit_rate 清晰度档位选码率最高（feed 源含原画档），兜底 play_addr
    // gear_name 形如 lowest_540 / normal_720_0 / highest_1080 / highest_4k / adapt_*
    final video = item['video'] as Map<String, dynamic>?;
    if (video != null && items.isEmpty) {
      String? bestUrl;
      int bestBitrate = -1;
      final bitRates = video['bit_rate'] as List?;
      if (bitRates != null) {
        for (final br in bitRates) {
          final map = br as Map<String, dynamic>;
          final bitrate = (map['bit_rate'] as num?)?.toInt() ?? 0;
          final urls =
              ((map['play_addr'] as Map<String, dynamic>)?['url_list'] as List?)
                      ?.cast<String>() ??
                  const [];
          if (urls.isNotEmpty && bitrate > bestBitrate) {
            bestBitrate = bitrate;
            bestUrl = urls.first;
          }
        }
      }
      bestUrl ??= ((video['play_addr'] as Map<String, dynamic>)?['url_list']
              as List?)
          ?.cast<String>()
          .firstOrNull;

      // 图集作品（aweme_type=68）detail 顶层 video.play_addr 可能指向 BGM 音乐
      // （sf6-cdn-tos.douyinstatic.com/...mp3），必须过滤，否则把音乐当视频存
      if (bestUrl != null && !_isRealVideo(bestUrl)) {
        bestUrl = null;
      }

      if (bestUrl != null) {
        // playwm → play 去水印（多数档位已是无水印地址，替换兜底）
        bestUrl = bestUrl.replaceAll('playwm', 'play');
        items.add(ParsedMediaItem(
          kind: MediaKind.video,
          url: bestUrl,
          coverUrl:
              ((video['cover'] as Map<String, dynamic>)?['url_list'] as List?)
                      ?.cast<String>()
                      .firstOrNull ??
                  null,
          ext: 'mp4',
        ));
      }
    }

    if (items.isEmpty) return null;
    return items;
  }

  ParseResult _buildResult(Map<String, dynamic> item, String sourceUrl) {
    final items = _extractItems(item);

    // 核心诊断：图集作品却一张实况都没识别出来 → 上报原始结构供后台分析
    final images = item['images'] as List?;
    if (images != null && images.isNotEmpty && items != null) {
      final hasLive = items.any((i) => i.kind == MediaKind.livePhoto);
      if (!hasLive) {
        AppLogger.log('dy-live',
            '⚠️ 图集 ${images.length} 张全部识别为普通图片，无实况');
        AppLogger.report(
            '抖音图集未识别到实况: ${items.length}张图 aweme_type=${item['aweme_type']}');
      }
    }

    if (items == null || items.isEmpty) {
      throw ParseException('未解析到可下载的图片或视频');
    }

    final desc = (item['desc'] as String?) ?? '抖音作品';
    final author =
        (((item['author'] ?? const {}) as Map)['nickname']) as String? ?? '';
    return ParseResult(
      platform: ParsePlatform.douyin,
      sourceUrl: sourceUrl,
      title: desc,
      author: author,
      items: items,
      parsedAt: DateTime.now(),
    );
  }

  /// 提取抖音动图 BGM 音轨地址（aweme.music.play_url.url_list[0]，mp3）。
  /// 2026-11-10 实测：抖音动图 play_addr 音轨是 -91dB 静音（BGM 由播放器
  /// 实时混音），只有 music.play_url 才是真正 BGM；保存时需与画面合成。
  static String? _musicUrl(Map<String, dynamic> item) {
    final music = item['music'];
    if (music is! Map) return null;
    final playUrl = music['play_url'];
    if (playUrl is! Map) return null;
    final list = playUrl['url_list'];
    if (list is List && list.isNotEmpty && list.first is String) {
      return list.first as String;
    }
    return null;
  }

  /// 从单张图里尽可能挖出配对视频地址（实况），并过滤 BGM 音乐
  static List<String> _liveVideoUrls(Map<String, dynamic> map) {
    final out = <String>[];
    void addAddr(Object? addr) {
      if (addr is! Map) return;
      final list = addr['url_list'];
      if (list is List) {
        for (final u in list) {
          if (u is String && u.isNotEmpty && _isRealVideo(u) && !out.contains(u)) {
            out.add(u);
          }
        }
      }
    }

    // ① live_image.url_list
    final li = map['live_image'];
    if (li is Map) {
      addAddr(li);
      addAddr((li as Map)['video']);
    }
    // ② video.play_addr / play_addr_h264（实况视频常见位置）
    final v = map['video'];
    if (v is Map) {
      addAddr(v['play_addr']);
      addAddr(v['play_addr_h264']);
      addAddr(v['play_addr_265']);
      final vm = v['video_model'];
      if (vm is String && vm.isNotEmpty) {
        try {
          final m2 = jsonDecode(vm) as Map<String, dynamic>;
          addAddr(m2['play_addr']);
        } catch (_) {}
      }
    }
    return out;
  }

  /// 判断是否为真实视频直链（而非 BGM 音乐/占位）。
  /// 2026-11-09 实测：图集作品的 detail 顶层 video.play_addr、桌面页
  /// 部分 <video> 元素都指向 BGM 音频（sf6-cdn-tos.douyinstatic.com/...mp3）
  static bool _isRealVideo(String url) {
    final u = url.toLowerCase();
    if (u.contains('.mp3') || u.contains('ies-music') || u.contains('douyinstatic')) {
      return false;
    }
    return u.contains('douyinvod') || u.contains('/video/') || u.contains('video');
  }

  // ---------- _ROUTER_DATA 提取（H5 源） ----------

  String? _extractRouterData(String html) {
    final m = RegExp(r'window\._ROUTER_DATA\s*=\s*(\{[\s\S]*?\})\s*</script>')
        .firstMatch(html);
    return m?.group(1);
  }

  List? _findItemList(Map<String, dynamic> data) {
    final loader = data['loaderData'] as Map<String, dynamic>?;
    if (loader == null) return null;
    for (final entry in loader.entries) {
      final page = entry.value;
      if (page is Map && page['videoInfoRes'] != null) {
        return (page['videoInfoRes'] as Map)['item_list'] as List?;
      }
      if (page is Map && page['noteInfoRes'] != null) {
        return (page['noteInfoRes'] as Map)['item_list'] as List?;
      }
    }
    // 兜底：深度查找
    for (final v in data.values) {
      final r = _deepFindItemList(v, 0);
      if (r != null) return r;
    }
    return null;
  }

  List? _deepFindItemList(dynamic node, int depth) {
    if (node is! Map || depth > 6) return null;
    if (node['item_list'] is List) return node['item_list'] as List;
    for (final v in node.values) {
      final r = _deepFindItemList(v, depth + 1);
      if (r != null) return r;
    }
    return null;
  }
}
