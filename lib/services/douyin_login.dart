import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'app_logger.dart';

/// 抖音扫码登录（2026-11-26 重做：首页原地弹码）
///
/// 旧方案是整页跳转登录页，但桌面登录弹窗在手机窄屏上
/// 会横向溢出（实测 390px 视口下弹窗宽度 ~620px，二维码右侧被裁），
/// 观感差且要退出页面才能回到首页。
///
/// 现在改为「原生二维码」：
///   - 常驻一个离屏 WebView（main.dart 挂载 [DouyinLoginHost]）
///   - 加载 www.douyin.com/user/self —— 桌面 UA 匿名访问时登录弹窗
///     【自动弹出】（实测 `#douyin_login_comp_scan_code_qrcode` 就位）
///   - 注入 hook 把面板里的二维码图（data:image/png;base64）抓给 Flutter
///   - Flutter 用 Image.memory 原生渲染，尺寸/边距完全可控
///   - 面板自己的 JS 负责 check_qrconnect 轮询与过期刷新；hook 额外兜底：
///     二维码 75s 未变或出现"失效/刷新"文案时点一下刷新
///   - 登录成功 → WebView 里落 cookie（sessionid）→ 我们轮询 CookieManager
class DouyinLogin {
  DouyinLogin._();
  static final DouyinLogin instance = DouyinLogin._();

  /// 桌面 UA：只有桌面版 www 才会自动弹扫码面板（移动 UA 跳分享页无入口）
  static const desktopUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  /// /user/self 匿名访问 = 登录引导页，面板自动弹出（实测唯一免点击入口；
  /// www.douyin.com/login 会直接跳 passport 回调，反而没有二维码）
  static const loginUrl = 'https://www.douyin.com/user/self';

  InAppWebViewController? _controller;
  final _qrController = StreamController<String>.broadcast();
  Stream<String> get qrStream => _qrController.stream;

  /// 页面 JS 侧确认登录（cookie 有 sessionid/sid_guard）—— 比 CookieManager
  /// 轮询更快更准，作为加速信号，不作为唯一判定
  final _loginController = StreamController<int>.broadcast();
  Stream<int> get loginStream => _loginController.stream;

  String? _lastQr;
  /// 最近一次抓到的二维码图 src（data: 或 http）—— 弹窗打开时先取这个，
  /// 避免等下一轮 hook 上报（面板已加载过时秒出码）
  String? get lastQr => _lastQr;

  bool _loading = false;

  /// 离屏 WebView 是否已挂载（main.dart 的 [DouyinLoginHost]）
  bool get attached => _controller != null;

  void attach(InAppWebViewController controller) {
    _controller = controller;
    controller.addJavaScriptHandler(
        handlerName: 'capQr',
        callback: (args) {
          if (args.isEmpty || args.first is! String) return null;
          final src = args.first as String;
          if (src.isEmpty || src == _lastQr) return null;
          _lastQr = src;
          if (!_qrController.isClosed) _qrController.add(src);
          return null;
        });
    // 面板 JS 检测到登录 cookie 后上报，直接触发成功（不等 2s 轮询）
    controller.addJavaScriptHandler(
        handlerName: 'capLoggedIn',
        callback: (args) {
          AppLogger.log('dy-login', '页面 JS 上报登录成功');
          if (!_loginController.isClosed) _loginController.add(1);
          return null;
        });
  }

  /// 开始/重新加载扫码面板（离屏 WebView 已 attach 的前提下）
  ///
  /// 返回 true = 已经就位并开始加载（调用方据此显示二维码占位/错误提示）。
  /// 二维码本身由 hook 异步上报，不在这里返回。
  ///
  /// 首次调用时 WebView 可能还没建好（main.dart 的 Host 与对话框同帧挂载），
  /// 这里最多等 3s，避免刚进 App 就点登录误报"未就绪"。
  Future<bool> start({bool force = false}) async {
    var c = _controller;
    if (c == null) {
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (_controller == null && DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 120));
      }
      c = _controller;
    }
    if (c == null) {
      AppLogger.log('dy-login', '离屏 WebView 未就绪');
      return false;
    }
    if (_loading) return true;
    _loading = true;
    try {
      await c.setSettings(
          settings: InAppWebViewSettings(
        javaScriptEnabled: true,
        cacheEnabled: true,
        transparentBackground: true,
        userAgent: desktopUa,
      ));
      if (force || _lastQr == null) {
        _lastQr = null;
        await c.loadUrl(urlRequest: URLRequest(url: WebUri(loginUrl)));
        AppLogger.log('dy-login', '扫码面板加载: $loginUrl');
      }
      return true;
    } catch (e) {
      AppLogger.log('dy-login', '扫码面板加载失败: $e');
      return false;
    } finally {
      _loading = false;
    }
  }

  /// 换一张码（用户点「刷新二维码」时）
  Future<void> refresh() async {
    _lastQr = null;
    try {
      await _controller?.reload();
      AppLogger.log('dy-login', '手动刷新二维码');
    } catch (_) {}
  }

  /// 退出抖音登录（换账号扫码前必做）
  ///
  /// 已登录时 /user/self 直接显示个人主页、根本不会弹扫码面板，
  /// 所以"重新扫码"= 先清掉登录 cookie 再进引导页。
  ///
  /// 注意：iOS 的 WKHTTPCookieStore 按 (name, domain, path) 三元组精确匹配，
  /// 硬编码 domain 很可能删不掉，所以先 getCookies 读出真实 domain/path。
  Future<void> logout() async {
    const authNames = {
      'sessionid',
      'sessionid_ss',
      'sid_guard',
      'sid_tt',
      'uid_tt',
      'uid_tt_ss',
      'passport_auth_mix_state',
      'passport_csrf_token',
    };
    try {
      final cm = CookieManager.instance();
      final cookies =
          await cm.getCookies(url: WebUri('https://www.douyin.com'));
      var removed = 0;
      for (final c in cookies) {
        if (!authNames.contains(c.name)) continue;
        final rawPath = c.path;
        final p = (rawPath != null && rawPath.isNotEmpty) ? rawPath : '/';
        final ok = await cm.deleteCookie(
          url: WebUri('https://www.douyin.com'),
          name: c.name,
          domain: c.domain,
          path: p,
        );
        // domain 为 null 时再试一次（部分实现要求显式主域）
        if (!ok) {
          await cm.deleteCookie(
            url: WebUri('https://www.douyin.com'),
            name: c.name,
            domain: '.douyin.com',
            path: p,
          );
        }
        removed++;
      }
      AppLogger.log('dy-login',
          '已清除抖音登录 cookie $removed 条（换号扫码）');
    } catch (e) {
      AppLogger.log('dy-login', '清除登录 cookie 失败: $e');
    }
    _lastQr = null;
  }

  /// 用完释放（about:blank 卸载重页面，避免常驻吃内存；cookie 不受影响）
  Future<void> stop() async {
    try {
      await _controller
          ?.loadUrl(urlRequest: URLRequest(url: WebUri('about:blank')));
    } catch (_) {}
    _lastQr = null;
  }

  /// 是否已有抖音登录态（cookie sessionid / sid_guard）
  static Future<bool> checkSession() async {
    try {
      final cookies = await CookieManager.instance()
          .getCookies(url: WebUri('https://www.douyin.com'));
      final hasSession = cookies.any((c) =>
          c.name == 'sessionid' &&
          (c.value?.isNotEmpty ?? false) &&
          c.value != 'delete_me');
      final hasGuard = cookies
          .any((c) => c.name == 'sid_guard' && (c.value?.isNotEmpty ?? false));
      return hasSession || hasGuard;
    } catch (_) {
      return false;
    }
  }
}

/// 二维码抓取 hook（注入到离屏登录 WebView，AT_DOCUMENT_START）
///
/// 面板 DOM（实测）：
///   #douyin_login_comp_scan_code_container
///     └ #douyin_login_comp_scan_code_qrcode > img[src=data:image/png;base64,…]
///
/// 只做三件事：
///   1. 二维码 src 变化就上报（去重，避免刷屏）
///   2. 面板没自动弹出（偶发）→ 点 `.douyin_login_new_class` 唤起
///   3. 过期兜底：src 75s 未变，或容器里出现"失效/刷新"文案 → 点刷新
const _qrHookJs = r'''
(function(){
  if (window.__qrHookInstalled) return;
  window.__qrHookInstalled = 1;
  function post(v){ try{ window.flutter_inappwebview.callHandler('capQr', v); }catch(e){} }
  function upLogin(){ try{ window.flutter_inappwebview.callHandler('capLoggedIn'); }catch(e){} }
  var last = '';
  var lastAt = Date.now();
  var tick = 0;
  var loginSent = false;

  // 登录成功判定：document.cookie 出现 sessionid / sid_guard
  function checkLogin(){
    if (loginSent) return;
    try {
      var ck = String(document.cookie || '');
      if (ck.indexOf('sessionid=') >= 0 || ck.indexOf('sid_guard=') >= 0) {
        loginSent = true;
        upLogin();
      }
    } catch(e){}
  }

  // 扫码确认后抖音常把面板换成“登录成功”页，cookie 也可能写入 httpOnly
  // 读不到，此时靠页面文案兜底。但页面出现"扫码成功"只代表手机已扫，
  // 用户还要在 App 里点确认 —— 所以这里只当作"可以去查 cookie 了"的信号，
  // 真正判定仍由 Dart 侧 checkSession() 做。
  function checkText(){
    if (loginSent) return;
    try {
      var t = String(document.body ? document.body.innerText : '');
      if (t.length > 4000) t = t.substring(0, 4000);
      if (t.indexOf('登录成功') >= 0) {
        loginSent = true;
        upLogin();
      }
    } catch(e){}
  }

  setInterval(function(){
    tick++;
    try {
      checkLogin();
      checkText();
      var img = document.querySelector('#douyin_login_comp_scan_code_qrcode img');
      if (!img) {
        // 面板未自动弹出：每 8 轮试一次唤起（约 10s）
        if (tick % 8 === 0) {
          var t = document.querySelector('.douyin_login_new_class');
          if (t) { try { t.click(); } catch(e){} }
        }
        return;
      }
      var s = String(img.currentSrc || img.src || '');
      if (!s) return;
      if (s !== last) {
        last = s;
        lastAt = Date.now();
        post(s);
        return;
      }
      // 过期判定：超时 或 面板提示失效
      var need = (Date.now() - lastAt > 75000);
      if (!need) {
        var cont = document.querySelector('#douyin_login_comp_scan_code_container');
        if (cont) {
          var txt = String(cont.innerText || '');
          if (txt.indexOf('失效') >= 0 || txt.indexOf('刷新') >= 0) need = true;
        }
      }
      if (need) {
        var box = document.querySelector('#douyin_login_comp_scan_code_container')
                  || document.body;
        var els = box.querySelectorAll('div,span,button,a,p');
        for (var i = 0; i < els.length; i++) {
          var el = els[i];
          var t2 = String(el.textContent || '').trim();
          if (t2.length > 0 && t2.length <= 14 &&
              (t2.indexOf('刷新') >= 0 || t2.indexOf('失效') >= 0)) {
            try { el.click(); } catch(e){}
          }
        }
        last = '';
        lastAt = Date.now();
      }
    } catch(e){}
  }, 1200);
})();
''';

/// 离屏登录 WebView（不可见，挂在 main.dart 的 Stack 里，勿删）
class DouyinLoginHost extends StatelessWidget {
  const DouyinLoginHost({super.key});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: -2500,
      top: 0,
      width: 390,
      height: 820,
      child: InAppWebView(
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          transparentBackground: true,
          userAgent: DouyinLogin.desktopUa,
          cacheEnabled: true,
          // 只挡视频/字体：二维码是 data: URI（非网络请求，不受拦截影响），
          // 背景图放行避免误伤面板渲染；视频解码是内存大头，必须挡
          contentBlockers: [
            ContentBlocker(
              trigger: ContentBlockerTrigger(
                urlFilter: '.*',
                resourceType: [
                  ContentBlockerTriggerResourceType.MEDIA,
                  ContentBlockerTriggerResourceType.FONT,
                ],
              ),
              action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
            ),
          ],
        ),
        initialUserScripts: UnmodifiableListView<UserScript>([
          UserScript(
              source: _qrHookJs,
              injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START),
        ]),
        onWebViewCreated: (c) => DouyinLogin.instance.attach(c),
      ),
    );
  }
}