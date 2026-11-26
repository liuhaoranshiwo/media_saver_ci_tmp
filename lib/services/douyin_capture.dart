import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/parsed_media.dart';
import 'app_logger.dart';

/// 抖音 WebView 捕获服务
///
/// 背景（2026 实测）：抖音已全面签名化——
///   iesdouyin share 页 SSR 不再内嵌视频数据（普通 UA）
///   feed/detail API 需要 a_bogus 签名；ttwid 被风控；公共解析 API 开始收费
/// 唯一稳定路径：让抖音自己的 H5 页在 WebView 里跑（前端天然带签名），
/// 注入 JS 钩子截获页面自己发出的 aweme/detail 响应（含原画 bit_rate），
/// 兜底再抓 <video> 标签的播放地址。
///
/// 使用方式：DouyinCaptureView 挂在 App 根部（屏幕外），解析时调 captureItem()。

/// 关键补丁（2026-11-07 实测有效）：
/// 抖音 note 页本身不发 aweme/detail 请求，但**从页面上下文 fetch 该接口**
/// 会带上网页自己的 cookie/ttwid，服务端直接返回 200 + aweme_detail（无需 a_bogus）。
/// 实测：aweme_type=68 的实况图文，images[i].video.play_addr.url_list 就是实况视频。
const _pullDetailJs = '''
(function(){
try {
  var id = '';
  var m = location.href.match(/(?:note|video|slides)\/(\d{8,})/);
  if (m) id = m[1];
  if (!id) {
    var im = document.documentElement.innerHTML.match(/aweme_id["'=:]+(\d{8,})/);
    if (im) id = im[1];
  }
  if (!id) return;
  var u = 'https://www.douyin.com/aweme/v1/web/aweme/detail/?device_platform=webapp&aid=6383'
    + '&channel=channel_pc_web&aweme_id=' + id
    + '&pc_client_type=1&version_code=170400&version_name=17.4.0'
    + '&cookie_enabled=true&platform=PC&downlink=10';
  fetch(u, {credentials:'include'})
    .then(function(r){ return r.text(); })
    .then(function(t){
      // 只在成功拿到 aweme_detail 时上报，并用 __capPulled 防重复上报；
      // 失败（cookie 未就绪 → 403 无 aweme_detail）不设标志，允许后续
      // 4/7/10s 的多次注入重试 —— 否则一次性标志会让首次失败后永不重试
      if (t && t.indexOf('aweme_detail') >= 0 && !window.__capPulled) {
        window.__capPulled = true;
        window.flutter_inappwebview.callHandler('capDetail', t);
      }
    })
    .catch(function(){});
} catch(e){}
})();
''';

/// 抖音作者主页抓取（2026-11-12 新增）：
///   桌面 /user/{secUid} 页自己发的 aweme/post 请求带 a_bogus 签名且响应完整
///   （bit_rate 10 档 + play_addr 3 url + music + images，实测探测确认），
///   匿名首批 20 条；移动 v2 API 翻页被锁且无 play_addr，不可用。
///   抓取策略 = hook 截获页面 post 响应 + 主动 fetch 翻页（免签尝试，detail
///   接口实测免签，post 可能同样免签）+ 程序化滚动驱动（页面自己发签名请求）
///   + 匿名登录墙移除（.douyin_login_new_class 的 fixed 祖先 remove）。
///   匿名被服务端锁 20 条时返回 hasMore=true，由上层提示"登录后可抓全部"。
const _profileHookJs = '''
(function(){
  if (window.__profInstalled) return; window.__profInstalled = true;
  function post(name, val){ try{ window.flutter_inappwebview.callHandler(name, val); }catch(e){} }
  function isPostText(t){ return typeof t === 'string' && t.indexOf('aweme_list') >= 0; }
  var of = window.fetch;
  if (of) {
    window.fetch = function(){
      var p = of.apply(this, arguments);
      try {
        p.then(function(res){ res.clone().text().then(function(t){ if (isPostText(t)) post('capPosts', t); }); });
      } catch(e){}
      return p;
    };
  }
  var ox = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function(m, u){ this.__profUrl = u; return ox.apply(this, arguments); };
  var os = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function(){
    var xhr = this;
    xhr.addEventListener('load', function(){
      try { if (isPostText(xhr.responseText)) post('capPosts', xhr.responseText); } catch(e){}
    });
    return os.apply(this, arguments);
  };
  // SSR 用户信息轮询（2026-11 实测两种结构都要认）：
  //   移动分享页 iesdouyin/share/user：loaderData["user_(id)/page"].userInfoRes.user_info
  //   旧桌面页：loaderData[xxx].userInfo.user
  // 新版桌面页已无 _ROUTER_DATA（只有 RENDER_DATA 且不含作者信息）—— 作者信息
  // 只能从移动分享页拿，故 captureUserProfile 先加载移动页读它再切桌面抓作品。
  var n = 0;
  var t1 = setInterval(function(){
    n++;
    try {
      var rd = window._ROUTER_DATA;
      if (rd && rd.loaderData) {
        var ld = rd.loaderData;
        for (var k in ld) {
          var p = ld[k];
          if (p && p.userInfoRes && p.userInfoRes.user_info) {
            post('capPosts', JSON.stringify({__userInfo: p.userInfoRes.user_info}));
            clearInterval(t1);
            return;
          }
          if (p && p.userInfo && p.userInfo.user) {
            post('capPosts', JSON.stringify({__userInfo: p.userInfo.user}));
            clearInterval(t1);
            return;
          }
        }
      }
    } catch(e){}
    if (n > 40) clearInterval(t1);
  }, 300);
})();
''';

/// 主动 fetch post 接口翻页（页面上下文，带页面 cookie；
/// 与 detail 同思路 —— 可能免签，失败则由滚动驱动兜底）
String _pullPostsJs(String secUid, int maxCursor) => '''
(function(){
try {
  var u = 'https://www.douyin.com/aweme/v1/web/aweme/post/?device_platform=webapp&aid=6383'
    + '&channel=channel_pc_web&sec_user_id=' + encodeURIComponent('$secUid')
    + '&max_cursor=$maxCursor&count=20'
    + '&pc_client_type=1&version_code=170400&version_name=17.4.0'
    + '&cookie_enabled=true&platform=PC&downlink=10';
  fetch(u, {credentials:'include'})
    .then(function(r){ return r.text(); })
    .then(function(t){
      if (t && t.indexOf('aweme_list') >= 0 && !window.__profPulled$maxCursor) {
        window.__profPulled$maxCursor = true;
        window.flutter_inappwebview.callHandler('capPosts', t);
      }
    })
    .catch(function(){});
} catch(e){}
})();
''';

/// 程序化滚动驱动 v3（build 119）：
///   v2 遍历 `div,section,main` 全 DOM 读 scrollHeight —— 抖音主页数千元素，
///   每次读都强制 layout，真机 WebView 会卡死/JSEvaluate 超时（build 118 教训）。
///   v3 只操作 window + document.scrollingElement + 至多 12 个 scroll/list 候选，
///   不再全 DOM 遍历；保留 WheelEvent（真实滚轮事件才是懒加载触发源）
///   与"加载更多"按钮点击、登录墙移除。
const _scrollProfileJs = '''
(function(){
  try {
    var n = document.querySelector('.douyin_login_new_class');
    if (n) {
      var a = n;
      while (a && a !== document.body) {
        var st = getComputedStyle(a);
        if (st.position === 'fixed') { a.remove(); break; }
        a = a.parentElement;
      }
    }
  } catch(e){}
  try {
    window.dispatchEvent(new WheelEvent('wheel',
        {deltaY: 2400, bubbles: true, cancelable: true, view: window}));
    if (document.body) {
      document.body.dispatchEvent(new WheelEvent('wheel',
          {deltaY: 2400, bubbles: true, cancelable: true, view: window}));
    }
  } catch(e){}
  try { window.scrollBy(0, 2600); } catch(e){}
  try {
    var cands = [document.scrollingElement, document.documentElement, document.body];
    var extra = document.querySelectorAll('[class*="scroll"],[class*="list"],[tabindex="-1"]');
    for (var i = 0; i < extra.length && i < 12; i++) cands.push(extra[i]);
    for (var j = 0; j < cands.length; j++) {
      var el = cands[j];
      try {
        if (el && el.scrollHeight > el.clientHeight + 200) {
          el.scrollTop = el.scrollHeight - 200;
        }
      } catch(e){}
    }
  } catch(e){}
  try {
    var btns = document.querySelectorAll('[class*="load-more"],[class*="loadMore"]');
    for (var i = 0; i < btns.length; i++) { btns[i].click(); }
  } catch(e){}
  return 1;
})();
''';

/// 采集当前 DOM 全部 douyinvod 视频直链 + BGM 音乐 + 当前页 URL
/// （翻页扫描用；url 用于检测误跳到"下一个推荐作品"）
/// ⚠️ 2026-11-11 实测：slides 图集在桌面页的视频 src 是
///   www.douyin.com/aweme/v1/play/?file_id=...（需页面 cookie，普通下载 0 字节），
///   **不是** douyinvod 直链 → 这类作品的 DOM 路无可用地址，只能靠 detail 接口。
///   所以这里保持只认 douyinvod；不加视口过滤（实测主内容视频在 top≈2164，
///   视口过滤会把它们全排除，导致整作品退回图片）。
const _collectVideosJs = '''
(function(){
  try {
    var vs = document.querySelectorAll('video');
    var videos = [], bgm = '';
    for (var i = 0; i < vs.length; i++) {
      var v = vs[i];
      var s = String(v && (v.currentSrc || v.src) || '');
      if (s.indexOf('http') !== 0) {
        var srcEl = v && v.querySelector('source');
        if (srcEl) s = String(srcEl.getAttribute('src') || srcEl.src || '');
      }
      if (s.indexOf('http') !== 0) continue;
      if (s.indexOf('douyinvod') >= 0 && videos.indexOf(s) < 0) videos.push(s);
      else if (!bgm && (s.indexOf('.mp3') >= 0 || s.indexOf('ies-music') >= 0 || s.indexOf('douyinstatic') >= 0)) bgm = s;
    }
    return JSON.stringify({videos: videos, bgm: bgm, url: String(location.href)});
  } catch(e) { return '{"videos":[],"bgm":"","url":""}'; }
})();
''';

/// 翻到图集下一张：键盘→事件 + 点击常见的"下一张"控件
const _nextSlideJs = '''
(function(){
  try {
    var ev = new KeyboardEvent('keydown', {key:'ArrowRight', code:'ArrowRight', keyCode:39, which:39, bubbles:true, cancelable:true});
    var t = document.activeElement || document.body;
    t.dispatchEvent(ev);
    document.dispatchEvent(ev);
    window.dispatchEvent(ev);
    var sels = ['[class*="switch-next"]','[class*="arrow-next"]','[class*="next-arrow"]','[class*="btn-next"]','[class*="next"]'];
    for (var j = 0; j < sels.length; j++) {
      var bs = document.querySelectorAll(sels[j]);
      for (var i = 0; i < bs.length; i++) {
        if (bs[i].offsetWidth > 0) { bs[i].click(); }
      }
    }
  } catch(e){}
  return 1;
})();
''';

class DouyinCapture {
  DouyinCapture._();
  static final DouyinCapture instance = DouyinCapture._();

  /// 基线 UA（iPhone Safari）：iesdouyin 分享页 SSR 用
  static const _iosUa =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 '
      'Mobile/15E148 Safari/604.1';

  /// 桌面 UA：www.douyin.com note 页 detail 兜底用（动图数据只在这条路有）
  static const _desktopUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  InAppWebViewController? _controller;
  Completer<String?>? _detailWaiter;
  Completer<String?>? _videoWaiter;
  Completer<List<String>?>? _videosWaiter;
  Completer<List<String>?>? _imagesWaiter;
  int _runId = 0;
  /// 目标作品 ID：detail/SSR 响应必须包含它才采纳 —— 推荐流的 item_list
  /// 响应也含特征字，抢跑会解析成别的作品（2026-11-11 真机"全解析错目标"）
  String _expectedId = '';

  // ---------- 作者主页抓取状态（capPosts 通道） ----------
  /// aweme_id → item（跨翻页去重累加）
  final Map<String, Map<String, dynamic>> _postItems = {};
  bool _postHasMore = true;
  int _postCursor = 0;
  Map<String, dynamic>? _profileInfo;
  Completer<bool>? _newPostsSignal;

  void attach(InAppWebViewController controller) {
    _controller = controller;
    controller.addJavaScriptHandler(
        handlerName: 'capDetail',
        callback: (args) {
          if (args.isNotEmpty && args.first is String) {
            final raw = args.first as String;
            if (_expectedId.isNotEmpty && !raw.contains(_expectedId)) {
              AppLogger.log('dy-cap',
                  '忽略非目标作品响应（不含 $_expectedId，len=${raw.length}）');
              return null; // 非目标作品的 detail/feed 响应，忽略
            }
            final waiter = _detailWaiter;
            if (waiter != null && !waiter.isCompleted) {
              waiter.complete(raw);
            }
          }
          return null;
        });
    controller.addJavaScriptHandler(
        handlerName: 'capVideo',
        callback: (args) {
          if (args.isNotEmpty && args.first is String) {
            final waiter = _videoWaiter;
            if (waiter != null && !waiter.isCompleted) {
              waiter.complete(args.first as String);
            }
          }
          return null;
        });
    // 图集实况：桌面页全部 douyinvod 视频直链（hook 兜底2 收集）
    controller.addJavaScriptHandler(
        handlerName: 'capVideos',
        callback: (args) {
          if (args.isNotEmpty && args.first is String) {
            try {
              final list = (jsonDecode(args.first as String) as List)
                  .cast<String>()
                  .toList();
              final waiter = _videosWaiter;
              if (waiter != null && !waiter.isCompleted) {
                waiter.complete(list);
              }
            } catch (_) {}
          }
          return null;
        });
    controller.addJavaScriptHandler(
        handlerName: 'capImages',
        callback: (args) {
          if (args.isNotEmpty && args.first is String) {
            try {
              final list = (jsonDecode(args.first as String) as List)
                  .cast<String>()
                  .toList();
              final waiter = _imagesWaiter;
              if (waiter != null && !waiter.isCompleted) {
                waiter.complete(list);
              }
            } catch (_) {}
          }
          return null;
        });
    // 作者主页：aweme/post 响应（aweme_list+has_more）与 SSR userInfo
    controller.addJavaScriptHandler(
        handlerName: 'capPosts',
        callback: (args) {
          if (args.isEmpty || args.first is! String) return null;
          try {
            final d = jsonDecode(args.first as String);
            if (d is! Map) return null;
            // SSR userInfo（{__userInfo: {...}} 包装）
            final ui = d['__userInfo'];
            if (ui is Map) {
              final user = ui['user'];
              _profileInfo = (user is Map)
                  ? (user as Map).cast<String, dynamic>()
                  : (ui as Map).cast<String, dynamic>();
              AppLogger.log('dy-user',
                  'userInfo: ${_profileInfo?['nickname']} aweme_count=${_profileInfo?['aweme_count']}');
              return null;
            }
            final list = d['aweme_list'];
            if (list is List) {
              var added = 0;
              for (final it in list) {
                if (it is Map && it['aweme_id'] != null) {
                  final id = '${it['aweme_id']}';
                  if (!_postItems.containsKey(id)) {
                    _postItems[id] = (it as Map).cast<String, dynamic>();
                    added++;
                  }
                }
              }
              final hm = d['has_more'];
              if (hm is bool) _postHasMore = hm;
              if (hm is num) _postHasMore = hm != 0;
              final mc = d['max_cursor'];
              if (mc is num) _postCursor = mc.toInt();
              AppLogger.log('dy-user',
                  'post 响应: +$added (总${_postItems.length}) has_more=$_postHasMore cursor=$_postCursor');
              if (added > 0 &&
                  _newPostsSignal != null &&
                  !_newPostsSignal!.isCompleted) {
                _newPostsSignal!.complete(true);
              }
            }
          } catch (_) {}
          return null;
        });
  }

  /// 加载分享页并等待捕获。返回：
  ///   - 完整作品 item（含 bit_rate 原画档 / images 图集 / 实况）
  ///   - {'__videoSrcOnly': url}（仅捕获到视频播放地址）
  ///   - {'__imagesOnly': [url...]}(仅捕获到图文页 DOM 图集)
  Future<Map<String, dynamic>?> captureItem(String url,
      {Duration timeout = const Duration(seconds: 18)}) async {
    final controller = _controller;
    if (controller == null) return null;
    _runId++;
    _expectedId =
        RegExp(r'/(?:note|video|slides)/(\d+)').firstMatch(url)?.group(1) ?? '';
    _detailWaiter = Completer<String?>();
    _videoWaiter = Completer<String?>();
    _videosWaiter = Completer<List<String>?>();
    _imagesWaiter = Completer<List<String>?>();

    try {
      await controller.loadUrl(
          urlRequest: URLRequest(url: WebUri(url)));
      AppLogger.log('dy-cap', '已加载页面: $url');
    } catch (e) {
      AppLogger.log('dy-cap', 'loadUrl 异常: $e');
    }/* 加载失败走超时 */

    // 页面自身不会请求 aweme/detail，但【从页面上下文 fetch】会带上网页的
    // cookie/ttwid，服务端直接返回 aweme_detail（实测 200/50KB，无需 a_bogus）。
    // 这是拿到抖音实况（aweme_type=68，images[i].video.play_addr）的唯一途径。
    for (final ms in [2500, 5000, 8000]) {
      Timer(Duration(milliseconds: ms), () {
        controller.evaluateJavascript(source: _pullDetailJs);
      });
    }

    final detail = await _detailWaiter!.future
        .timeout(timeout, onTimeout: () => null);
    if (detail != null) {
      AppLogger.log('dy-cap',
          'detail 已捕获: len=${detail.length} head=${detail.length > 200 ? detail.substring(0, 200) : detail}');
      final item = _extractItem(detail);
      if (item != null) {
        AppLogger.log('dy-cap',
            'item 提取成功: keys=${item.keys.toList().join(",")} aweme_type=${item['aweme_type']} images=${(item['images'] as List?)?.length ?? 0}');
        return item;
      }
      AppLogger.log('dy-cap', 'detail 拿到但提取 item 失败');
    } else {
      AppLogger.log('dy-cap', 'detail 超时未捕获（${timeout.inSeconds}s）');
    }

    // 兜底1：页面 <video> 播放地址（单清晰度，通常无水印）
    final src =
        await _videoWaiter!.future.timeout(const Duration(seconds: 3),
            onTimeout: () => null);
    if (src != null && src.startsWith('http')) {
      AppLogger.log('dy-cap', '兜底命中 <video> src');
      return {
        'desc': '',
        '__videoSrcOnly': src,
      };
    }

    // 兜底2：图文页 DOM 图集（note 页无 detail XHR 也无 <video>）
    final images =
        await _imagesWaiter!.future.timeout(const Duration(seconds: 3),
            onTimeout: () => null);
    if (images != null && images.isNotEmpty) {
      AppLogger.log('dy-cap', '兜底命中 DOM 图集: ${images.length} 张');
      return {
        'desc': '',
        '__imagesOnly': images,
      };
    }
    AppLogger.log('dy-cap', '三条路均未捕获，返回 null');
    return null;
  }

  /// 桌面兜底（2026-11-08/09 实测，专拿动图）—— 三级递进：
  ///
  /// 1. detail 接口：www.douyin.com/note/{id} 页面上下文 fetch（带页面自种
  ///    cookie，实测 200 无需 a_bogus），aweme_type=68 的实况在
  ///    images[i].video.play_addr —— 有实况直接用（最优先）
  /// 2. DOM <video> 直链（2026-11-09 用户实测思路）：桌面 note 页把实况动图
  ///    直接挂 <video>（duration≈3s 短循环），src 即带签名 douyinvod 直链；
  ///    detail 超时/无实况字段时的免接口兜底
  /// 3. detail 图集（无实况）：交 parser 保留原结果
  ///
  /// 实现（全部为实测结论）：
  ///  - 桌面 UA 落到 www.douyin.com/note/{id}，页面自己的 JS 会种好
  ///    __ac_signature/UIFID 等所需 cookie，无需预置 ttwid（无 cookie 403）
  ///  - 必须让页面 JS 跑起来（屏蔽脚本则 403），但屏蔽 MEDIA/IMAGE/FONT/CSS
  ///    后页面只剩 HTML 骨架+脚本，内存极轻，不会重演整页渲染闪退
  ///  - 页面上下文 fetch detail 无需 a_bogus（实测 200）
  ///
  /// 用后恢复基线 iPhone UA，不影响 iesdouyin 主路。
  Future<Map<String, dynamic>?> captureDesktopDetail(String noteUrl,
      {Duration timeout = const Duration(seconds: 18),
      int expectedVideos = 0}) async {
    final controller = _controller;
    if (controller == null) return null;
    _runId++;
    _expectedId =
        RegExp(r'/(?:note|video|slides)/(\d+)').firstMatch(noteUrl)?.group(1) ?? '';
    _detailWaiter = Completer<String?>();
    _videoWaiter = Completer<String?>();
    _videosWaiter = Completer<List<String>?>();
    _imagesWaiter = Completer<List<String>?>();

    AppLogger.log('dy-live', '桌面 detail 兜底启动: $noteUrl');
    try {
      await controller.setSettings(
          settings: InAppWebViewSettings(
        javaScriptEnabled: true,
        transparentBackground: true,
        userAgent: _desktopUa,
        cacheEnabled: true,
      ));
    } catch (e) {
      AppLogger.log('dy-live', '切桌面 UA 失败: $e');
    }
    try {
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(noteUrl)));
    } catch (_) {/* 加载失败走超时 */}

    // 页面 JS 种 cookie 需要几秒；3.5/6/9/12/15s 五次尝试 fetch detail
    // （2026-11-11 真机：桌面页首次 fetch 常 403 Uifid Not Found，需等页面
    //   自种 cookie 完成，多给几次机会）
    for (final ms in [3500, 6000, 9000, 12000, 15000]) {
      Timer(Duration(milliseconds: ms), () {
        controller.evaluateJavascript(source: _pullDetailJs);
      });
    }

    final detail = await _detailWaiter!.future
        .timeout(timeout, onTimeout: () => null);

    // 用完立刻恢复基线 iPhone UA（下一次 iesdouyin 主路不受影响）
    try {
      await controller.setSettings(
          settings: InAppWebViewSettings(
        javaScriptEnabled: true,
        transparentBackground: true,
        userAgent: _iosUa,
        cacheEnabled: true,
      ));
    } catch (_) {}

    Map<String, dynamic>? detailItem;
    if (detail != null) {
      AppLogger.log('dy-live',
          '桌面 detail 已捕获: len=${detail.length} head=${detail.length > 120 ? detail.substring(0, 120) : detail}');
      final item = _extractItem(detail);
      if (item != null) {
        // detail 里已带实况（images[i].video / live_photo）→ 最优先直接用
        final imgs = item['images'] as List?;
        final hasLive = imgs?.any((e) =>
                e is Map &&
                ((e as Map)['video'] is Map || e['live_photo'] == true)) ??
            false;
        if (hasLive) {
          AppLogger.log('dy-live',
              '桌面 item: aweme_type=${item['aweme_type']} images=${imgs?.length ?? 0} detail自带实况');
          return item;
        }
        detailItem = item;
        AppLogger.log('dy-live',
            'detail 有图集但无实况字段，继续等 DOM <video> 直链（页面渲染的实况视频）');
      }
    } else {
      AppLogger.log('dy-live', '桌面 detail 超时未捕获，改等 DOM <video> 直链');
    }

    // DOM 直链路（2026-11-09 用户实测思路 → 2026-11-10 两次升级）：
    // 桌面 note 页把作品视频挂 <video> 元素，src 即带签名 douyinvod 直链。
    // 关键坑（build 108 真机教训）：图集实况视频【懒加载】—— 页面只渲染当前
    // slide 的 <video>，静态收集只能拿到第 1 个（1≠图集张数，配不上→只出图）。
    // 所以 hook 静态收集后还要【主动翻页】逐张采集（键盘→/点下一张按钮），
    // 顺路抓 BGM 音乐（<video> 挂的 mp3，合成音轨用）。
    final videoList = await _videosWaiter!.future
        .timeout(const Duration(seconds: 4), onTimeout: () => null);
    var safeList = _filterRealVideos(videoList ?? const <String>[]);
    String? bgm;

    if (expectedVideos > 1 && safeList.length < expectedVideos) {
      final seen = List<String>.from(safeList);
      // 基线 URL：翻页后跳到"下一个推荐作品"（URL 变化）必须立即停手，
      // 否则会把推荐流的视频混进配对列表
      var base = '';
      try {
        base = (await controller.evaluateJavascript(source: 'location.href'))
                ?.toString() ??
            '';
      } catch (_) {}
      for (var k = 0;
          k < expectedVideos + 2 && seen.length < expectedVideos;
          k++) {
        try {
          await controller.evaluateJavascript(source: _nextSlideJs);
        } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 800));
        try {
          final raw =
              await controller.evaluateJavascript(source: _collectVideosJs);
          final (vs, b, u) = _parseCollect(raw);
          final norm = u.startsWith('"') ? u.substring(1) : u;
          if (base.isNotEmpty && norm.isNotEmpty && norm != base) {
            AppLogger.log('dy-live', '翻页跳出作品页（URL变化），停止扫描');
            break;
          }
          if (b != null && bgm == null) bgm = b;
          for (final u2 in _filterRealVideos(vs)) {
            if (!seen.contains(u2)) seen.add(u2);
          }
        } catch (_) {}
      }
      if (seen.length > safeList.length) {
        AppLogger.log(
            'dy-live', '翻页采集补齐: ${safeList.length} → ${seen.length} 个视频');
        safeList = seen;
      }
    }

    if (safeList.isNotEmpty) {
      AppLogger.log('dy-live', 'DOM <video> 直链命中: ${safeList.length} 个视频');
      return {
        'desc': '',
        '__desktopVideos': safeList,
        '__desktopVideo': safeList.first,
        if (bgm != null) '__desktopBgm': bgm,
      };
    }
    return detailItem; // detail 有图集但无实况、DOM 也无 video → 交 parser 保留原结果
  }

  /// 读 WebView cookie 判断抖音登录态（sessionid 存在且非 delete_me）
  Future<bool> _douyinLoggedIn() async {
    try {
      final cookies = await CookieManager.instance()
          .getCookies(url: WebUri('https://www.douyin.com'));
      return cookies.any((c) =>
          c.name == 'sessionid' &&
          (c.value?.isNotEmpty ?? false) &&
          c.value != 'delete_me');
    } catch (_) {
      return false;
    }
  }

  /// 抓取作者主页全部作品（2026-11-12 新增，build 119 重构）。
  ///
  /// 2026-11-26 实测（关键变化）：抖音已对**匿名**用户彻底关闭作品列表 ——
  ///   桌面 aweme/post 返回 {"aweme_list":[], "has_more":0,
  ///   "not_login_module":{"guide_login_tip_exist":true}}（1027 字节空体）
  ///   移动 v2 仅 6 条、条目无 play_addr、翻页直接 status_code 11110 shark_fail_1
  ///   → **登录是唯一可靠路径**。新版桌面页也已无 _ROUTER_DATA / userInfo，
  ///   作者信息只能从移动分享页 userInfoRes.user_info 拿。
  ///
  /// 流程：
  ///   ① 读登录态 → ② 移动分享页取作者昵称/作品数（iPhone UA）
  ///   → ③ 桌面主页 hook 截获 post 响应 + 免签 fetch + 滚动驱动（桌面 UA）
  ///     · 已登录：budget 150s、空转容忍 6 轮（128 件 ≈ 7 页）
  ///     · 匿名：只跑 25s 快速判定（服务端必返回空列表），不空等
  ///   → ④ 空结果时 report 诊断 → 上层据 __userNeedLogin 引导登录
  ///
  /// 返回 {'__userPosts': [...], '__userMore': bool, '__userLoggedIn': bool,
  ///        '__userNeedLogin': bool, '__userNickname'?, '__userCount'?}
  Future<Map<String, dynamic>?> captureUserProfile(String secUid,
      {Duration budget = const Duration(seconds: 150),
      int maxItems = 600}) async {
    final controller = _controller;
    if (controller == null) return null;
    _runId++;
    _expectedId = ''; // 主页模式：不按作品 ID 过滤响应
    _postItems.clear();
    _postHasMore = true;
    _postCursor = 0;
    _profileInfo = null;
    _newPostsSignal = Completer<bool>();

    final loggedIn = await _douyinLoggedIn();
    AppLogger.log('dy-user',
        '主页抓取启动: sec_uid=${secUid.length}字符 登录态=${loggedIn ? "已登录" : "匿名"}');

    // ---------- ① 移动分享页：作者昵称 / 作品总数 ----------
    // （桌面新版页无任何作者信息；移动 SSR 的 userInfoRes 是唯一来源）
    try {
      await controller.setSettings(
          settings: InAppWebViewSettings(
        javaScriptEnabled: true,
        transparentBackground: true,
        userAgent: _iosUa,
        cacheEnabled: true,
      ));
      await controller.loadUrl(
          urlRequest: URLRequest(
              url: WebUri('https://www.iesdouyin.com/share/user/$secUid')));
      final infoDeadline = DateTime.now().add(const Duration(seconds: 7));
      while (_profileInfo == null && DateTime.now().isBefore(infoDeadline)) {
        await Future.delayed(const Duration(milliseconds: 300));
      }
      AppLogger.log('dy-user',
          '作者信息: ${_profileInfo?['nickname']} aweme_count=${_profileInfo?['aweme_count']}');
    } catch (e) {
      AppLogger.log('dy-user', '移动分享页取作者信息失败: $e');
    }

    // ---------- ② 桌面主页：抓作品列表 ----------
    try {
      await controller.setSettings(
          settings: InAppWebViewSettings(
        javaScriptEnabled: true,
        transparentBackground: true,
        userAgent: _desktopUa,
        cacheEnabled: true,
      ));
      await controller.loadUrl(
          urlRequest:
              URLRequest(url: WebUri('https://www.douyin.com/user/$secUid')));
    } catch (_) {/* 加载失败走超时 */}

    final sw = Stopwatch()..start();
    final effBudget = loggedIn ? budget : const Duration(seconds: 25);
    final maxIdle = loggedIn ? 6 : 3;
    var idleRounds = 0;
    while (sw.elapsed < effBudget &&
        _postItems.length < maxItems &&
        _postHasMore &&
        idleRounds < maxIdle) {
      _newPostsSignal = Completer<bool>();
      final before = _postItems.length;
      try {
        await controller.evaluateJavascript(
            source: _pullPostsJs(secUid, _postCursor));
        await controller.evaluateJavascript(source: _scrollProfileJs);
        // 一轮内二次滚动：页面往往需要连续滚动才触发下一页加载
        await Future.delayed(const Duration(milliseconds: 1500));
        await controller.evaluateJavascript(source: _scrollProfileJs);
      } catch (_) {}
      try {
        await _newPostsSignal!.future
            .timeout(const Duration(seconds: 8), onTimeout: () => false);
      } catch (_) {}
      if (_postItems.length > before) {
        idleRounds = 0;
      } else {
        idleRounds++;
        AppLogger.log('dy-user',
            '第 $idleRounds 轮无新增（has_more=$_postHasMore cursor=$_postCursor 已抓${_postItems.length}）');
      }
    }

    // 用完立刻恢复基线 iPhone UA（不影响 iesdouyin 主路）
    try {
      await controller.setSettings(
          settings: InAppWebViewSettings(
        javaScriptEnabled: true,
        transparentBackground: true,
        userAgent: _iosUa,
        cacheEnabled: true,
      ));
    } catch (_) {}

    // ---------- ③ 结果 + 诊断 ----------
    if (_postItems.isEmpty) {
      final nickname = _profileInfo?['nickname'];
      final count = _profileInfo?['aweme_count'];
      AppLogger.log('dy-user',
          '主页抓取结束: 0 件（登录态=${loggedIn ? "已登录" : "匿名"} 昵称=$nickname 作品数=$count）');
      if (!loggedIn) {
        AppLogger.report('抖音主页匿名无数据: 昵称=$nickname 作品数=$count '
            '（服务端返回空 aweme_list，需登录）');
      } else {
        AppLogger.report('抖音主页已登录但抓取为 0: 昵称=$nickname 作品数=$count');
      }
      return {
        '__userPosts': const [],
        '__userMore': true,
        '__userLoggedIn': loggedIn,
        '__userNeedLogin': !loggedIn,
        if (nickname is String) '__userNickname': nickname,
        if (count is num) '__userCount': (count as num).toInt(),
      };
    }
    AppLogger.log('dy-user',
        '主页抓取结束: ${_postItems.length} 件 has_more=$_postHasMore 耗时=${sw.elapsedMilliseconds}ms');
    return {
      '__userPosts': _postItems.values.toList(),
      '__userMore': _postHasMore && _postItems.length < maxItems,
      '__userLoggedIn': loggedIn,
      '__userNeedLogin': false,
      if (_profileInfo?['nickname'] is String)
        '__userNickname': _profileInfo!['nickname'] as String,
      if (_profileInfo?['aweme_count'] is num)
        '__userCount': (_profileInfo!['aweme_count'] as num).toInt(),
    };
  }

  /// 只认 douyinvod 视频直链；BGM 音乐（.mp3/ies-music/douyinstatic）一律滤除
  static List<String> _filterRealVideos(Iterable<String> urls) => urls
      .where((u) =>
          u.startsWith('http') &&
          u.contains('douyinvod') &&
          !u.contains('.mp3') &&
          !u.contains('douyinstatic') &&
          !u.contains('ies-music'))
      .toList();
  /// 解析 _collectVideosJs 返回（可能被外层引号包裹）→ (视频列表, BGM, URL)
  static (List<String>, String?, String) _parseCollect(dynamic raw) {
    try {
      var s = (raw ?? '').toString().trim();
      if (s.startsWith('"')) s = jsonDecode(s) as String;
      final d = jsonDecode(s);
      if (d is Map) {
        final vs = (d['videos'] as List?)?.cast<String>() ?? const <String>[];
        final b = d['bgm'] as String?;
        final u = d['url'] as String? ?? '';
        return (vs, (b != null && b.isNotEmpty) ? b : null, u);
      }
      if (d is List) return (d.cast<String>(), null, '');
    } catch (_) {}
    return (const <String>[], null, '');
  }

  /// detail JSON → aweme item（结构可能是 {aweme_detail} / {item_list} / 裸 item）
  Map<String, dynamic>? _extractItem(String raw) {
    try {
      final d = jsonDecode(raw);
      Map<String, dynamic>? found;
      void search(dynamic node, int depth) {
        if (found != null || depth > 8) return;
        if (node is Map) {
          if (node['aweme_detail'] is Map) {
            found = (node['aweme_detail'] as Map).cast<String, dynamic>();
            return;
          }
          if (node['item_list'] is List &&
              (node['item_list'] as List).isNotEmpty) {
            found = ((node['item_list'] as List).first as Map)
                .cast<String, dynamic>();
            return;
          }
          node.values.forEach((v) => search(v, depth + 1));
        } else if (node is List) {
          for (final v in node) {
            search(v, depth + 1);
          }
        }
      }

      search(d, 0);
      return found;
    } catch (_) {
      return null;
    }
  }
}

/// 挂在 App 根部的离屏 WebView（勿删，抖音解析依赖它）
class DouyinCaptureView extends StatelessWidget {
  const DouyinCaptureView({super.key});


  static const _hookJs = '''
(function(){
  if (window.__capInstalled) return; window.__capInstalled = true;
  function post(name, val){ try{ window.flutter_inappwebview.callHandler(name, val); }catch(e){} }
  // 2026-11：note 图文页不发 aweme/detail XHR，数据直接 SSR 内嵌在 _ROUTER_DATA
  // （loaderData["note_(id)/page"].videoInfoRes.item_list），故除 XHR 钩子外
  // 还需轮询 _ROUTER_DATA；同时按响应内容特征匹配，不再只认 URL 子串
  function isDetailText(t){
    return typeof t === 'string' && t.length > 20 &&
      (t.indexOf('aweme_detail') >= 0 || t.indexOf('item_list') >= 0 || t.indexOf('videoInfoRes') >= 0);
  }
  var of = window.fetch;
  if (of) {
    window.fetch = function(){
      var u = (arguments[0] && arguments[0].url) || arguments[0];
      var p = of.apply(this, arguments);
      try {
        if (typeof u === 'string' && /detail|item|note|aweme/i.test(u)) {
          p.then(function(res){ res.clone().text().then(function(t){ if (isDetailText(t)) post('capDetail', t); }); });
        }
      } catch(e){}
      return p;
    };
  }
  var ox = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function(m, u){ this.__capUrl = u; return ox.apply(this, arguments); };
  var os = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function(){
    var xhr = this;
    xhr.addEventListener('load', function(){
      try {
        var u = String(xhr.__capUrl || '');
        if (/detail|item|note|aweme/i.test(u) && isDetailText(xhr.responseText)) {
          post('capDetail', xhr.responseText);
        }
      } catch(e){}
    });
    return os.apply(this, arguments);
  };
  // 兜底1：SSR 内嵌数据（真浏览器里 videoInfoRes 会随页面渲染返回）
  var n = 0;
  var t1 = setInterval(function(){
    n++;
    try {
      if (window._ROUTER_DATA) {
        post('capDetail', JSON.stringify(window._ROUTER_DATA));
        clearInterval(t1);
        return;
      }
    } catch(e){}
    if (n > 60) clearInterval(t1);
  }, 300);
  // 兜底2：<video> 播放地址。2026-11-10 升级：收集【全部】douyinvod 视频直链
  // （图集实况在桌面页是多个 <video>，旧逻辑只取第一个 → 多图图集永远只报
  //  1 个封面视频，真机反馈"图集 3 视频只抓到 1 个"）。列表连续 3 轮无新增
  // 才上报（视频渐进加载，避免只抓到第一段就上报）。
  // ⚠️ 2026-11-11：不加视口过滤 —— 实测桌面页主内容视频在 top≈2164（首屏外），
  // 过滤会把主视频全排除 → 整作品退回图片（真机"识别成照片"）。推荐流干扰
  // 改由 parser 侧"严格数量匹配"兜住。
  var m = 0, lastLen = 0, stable = 0, sent = false;
  var t2 = setInterval(function(){
    m++;
    try {
      var vs = document.querySelectorAll('video');
      var list = [];
      for (var i = 0; i < vs.length; i++) {
        var v = vs[i];
        var s = String(v && (v.currentSrc || v.src) || '');
        if (s.indexOf('http') !== 0) {
          var srcEl = v && v.querySelector('source');
          if (srcEl) s = String(srcEl.getAttribute('src') || srcEl.src || '');
        }
        if (s.indexOf('http') !== 0) continue;
        if (s.indexOf('.mp3') >= 0 || s.indexOf('ies-music') >= 0 || s.indexOf('douyinstatic') >= 0) continue; // BGM 音乐，跳过
        if (s.indexOf('douyinvod') >= 0 && list.indexOf(s) < 0) list.push(s); // 作品视频直链
      }
      if (list.length > 0 && list.length === lastLen) stable++; else stable = 0;
      lastLen = list.length;
      if (!sent && list.length >= 1 && (stable >= 3 || m >= 60)) {
        sent = true;
        post('capVideos', JSON.stringify(list)); // 全部视频（图集实况配对用）
        post('capVideo', list[0]);               // 兼容旧单视频路
        clearInterval(t2);
      }
    } catch(e){}
    if (m > 70) clearInterval(t2);
  }, 400);
  // 兜底3：图文页 DOM 图集（note 作品，CDN 图床特征）。
  // 2026-11-09 用户实测思路：优先收集 biz_tag=aweme_images（作品内容图），
  // 1 张即报 —— 实况图文（aweme_type=68）只有单张内容图，旧逻辑 >=2 永不触发
  var k = 0;
  var t3 = setInterval(function(){
    k++;
    try {
      var imgs = document.querySelectorAll('img');
      var urls = [], generic = [];
      for (var i = 0; i < imgs.length; i++) {
        var s2 = String(imgs[i].currentSrc || imgs[i].src || '');
        if (s2.indexOf('http') !== 0) continue;
        if (s2.indexOf('aweme_images') >= 0) {
          if (urls.indexOf(s2) < 0) urls.push(s2);
        } else if (s2.indexOf('byteimg') >= 0 || s2.indexOf('zjcdn') >= 0 ||
                   s2.indexOf('douyinpic') >= 0 || s2.indexOf('douyin') >= 0) {
          if (generic.indexOf(s2) < 0 && generic.length < 10) generic.push(s2);
        }
      }
      if (urls.length >= 1) { post('capImages', JSON.stringify(urls)); clearInterval(t3); }
      else if (generic.length >= 2) { post('capImages', JSON.stringify(generic)); clearInterval(t3); }
    } catch(e){}
    if (k > 60) clearInterval(t3);
  }, 400);
})();
''';

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: -2500,
      top: 0,
      width: 390,
      height: 844,
      child: InAppWebView(
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          transparentBackground: true,
          userAgent: DouyinCapture._iosUa,
          cacheEnabled: true,
          // 屏蔽媒体/图片/字体/CSS 的解码加载（2026-11-08 实测）：
          // 1) iesdouyin 主路的照片来自 SSR JSON，不依赖图片渲染
          // 2) www note 页桌面兜底若不屏蔽，PC 整页视频/大图解码会把
          //    iPhone 内存打爆导致闪退（run85 崩溃上报证实）
          // 脚本/XHR/fetch 必须放行（页面 JS 要种 cookie，屏蔽则 detail 403）
          contentBlockers: [
            ContentBlocker(
              trigger: ContentBlockerTrigger(
                urlFilter: '.*',
                resourceType: [
                  ContentBlockerTriggerResourceType.MEDIA,
                  ContentBlockerTriggerResourceType.IMAGE,
                  ContentBlockerTriggerResourceType.FONT,
                  ContentBlockerTriggerResourceType.STYLE_SHEET,
                ],
              ),
              action:
                  ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
            ),
          ],
        ),
        initialUserScripts: UnmodifiableListView<UserScript>([
          UserScript(
              source: _hookJs,
              injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START),
          // 作者主页抓取 hook（aweme_list 响应 + SSR userInfo 上报）
          UserScript(
              source: _profileHookJs,
              injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START),
        ]),
        onWebViewCreated: (c) => DouyinCapture.instance.attach(c),
      ),
    );
  }
}

/// 视频仅捕获到播放地址时的兜底转换（无 bit_rate，单一清晰度）
ParsedMediaItem? videoSrcOnlyItem(Map<String, dynamic> item) {
  final src = item['__videoSrcOnly'] as String?;
  if (src == null || src.isEmpty) return null;
  return ParsedMediaItem(kind: MediaKind.video, url: src, ext: 'mp4');
}
