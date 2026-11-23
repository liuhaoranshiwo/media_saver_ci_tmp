import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/app_logger.dart';
import '../theme/app_theme.dart';

/// 抖音扫码登录页（2026-11-12 新增，作者主页抓全部作品配套）
///
/// 背景：抖音桌面页匿名只发首批 20 条作品，翻页被服务端锁死；
/// 登录态（cookie 含 sessionid）后滚动/翻页可拿全部。
/// 用户扫码后 WebView 持久化 cookie，之后 DouyinCapture 走桌面主页即全量。
///
/// 交互：每 2s 轮询 www.douyin.com 的 cookie，检测到 sessionid 自动关闭
/// 返回 true；用户也可手动点"完成"（未检测到登录则提示）。
class DouyinLoginScreen extends StatefulWidget {
  const DouyinLoginScreen({super.key});

  @override
  State<DouyinLoginScreen> createState() => _DouyinLoginScreenState();
}

class _DouyinLoginScreenState extends State<DouyinLoginScreen> {
  InAppWebViewController? _controller;
  Timer? _poll;
  bool _done = false;
  String _hint = '打开抖音 App 扫码登录，登录成功后自动返回';
  bool _loggedIn = false;

  @override
  void initState() {
    super.initState();
    _startPolling();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_done || !mounted) return;
      final ok = await _checkSession();
      if (ok && mounted) {
        setState(() {
          _loggedIn = true;
          _hint = '登录成功 ✅ 正在返回…';
        });
        _done = true;
        _poll?.cancel();
        await Future.delayed(const Duration(milliseconds: 600));
        if (mounted) Navigator.of(context).pop(true);
      }
    });
  }

  Future<bool> _checkSession() async {
    try {
      // 6.0.0 钉版没有 loadAllCookies（6.1+ API），用 getCookies
      final cookies = await CookieManager.instance()
          .getCookies(url: WebUri('https://www.douyin.com'));
      final hasSession = cookies.any((c) =>
          c.name == 'sessionid' &&
          (c.value?.isNotEmpty ?? false) &&
          c.value != 'delete_me');
      // sid_guard 也在登录成功后出现，双确认降低误判
      final hasGuard = cookies.any((c) =>
          c.name == 'sid_guard' && (c.value?.isNotEmpty ?? false));
      return hasSession || hasGuard;
    } catch (e) {
      AppLogger.log('dy-login', 'cookie 轮询异常: $e');
      return false;
    }
  }

  Future<void> _onManualDone() async {
    final ok = await _checkSession();
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('未检测到登录态，请先扫码登录'),
        backgroundColor: AppColors.danger));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('登录抖音',
            style: TextStyle(fontSize: 16)),
        actions: [
          TextButton(
              onPressed: _onManualDone,
              child: Text(_loggedIn ? '完成' : '我已登录，检查',
                  style: const TextStyle(color: AppColors.primary))),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: AppColors.surface,
            child: Text(_hint, style: AppText.caption),
          ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest:
                  URLRequest(url: WebUri('https://www.douyin.com/')),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                transparentBackground: false,
                // 桌面 UA：www.douyin.com 首屏自动弹出二维码登录框
                // （探测实测 .douyin_login_new_class），移动 UA 会跳分享页无登录入口
                userAgent:
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
                // 登录页需要真渲染（二维码/输入框），不屏蔽资源
              ),
              onWebViewCreated: (c) {
                _controller = c;
                AppLogger.log('dy-login', '登录 WebView 就绪');
              },
            ),
          ),
        ],
      ),
    );
  }
}
