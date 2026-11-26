import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/app_logger.dart';
import '../services/douyin_login.dart';
import '../theme/app_theme.dart';

/// 抖音扫码登录对话框（首页 / 结果页共用，2026-11-26 新增）
///
/// 为什么不直接把网页嵌进来：抖音桌面登录弹窗实测宽约 620px，
/// 手机 390pt 视口下二维码右侧会被裁掉，标题也被压缩。
/// 所以改成「离屏 WebView 取码 → Flutter 原生渲染」：
///   1. main.dart 常驻一个屏幕外的 [DouyinLoginHost]
///   2. 它加载 www.douyin.com/user/self，桌面 UA 匿名访问会自动弹出扫码面板
///   3. 注入的 hook 把面板里的 data:image/png;base64 二维码抓给 Dart
///   4. 这里用 Image.memory 画出来，尺寸边距完全可控
///   5. 面板自己调 check_qrconnect 轮询扫码状态；我们只每 2s 查一次 cookie，
///      出现 sessionid/sid_guard 就算登录成功，自动关窗继续解析
///
/// 返回 true 表示已登录，调用方据此继续原操作。
///
/// [relogin] = true 时先清掉抖音登录 cookie 再进引导页 —— 已登录状态下
/// /user/self 会直接显示个人主页、不会弹扫码面板，换号必须走这条。
Future<bool> showDouyinLoginDialog(BuildContext context,
    {String? reason, bool relogin = false}) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (_) => _DouyinLoginDialog(reason: reason, relogin: relogin),
  );
  return ok == true;
}

class _DouyinLoginDialog extends StatefulWidget {
  final String? reason;
  final bool relogin;

  const _DouyinLoginDialog({this.reason, this.relogin = false});

  @override
  State<_DouyinLoginDialog> createState() => _DouyinLoginDialogState();
}

class _DouyinLoginDialogState extends State<_DouyinLoginDialog> {
  StreamSubscription<String>? _sub;
  StreamSubscription<int>? _loginSub;
  Timer? _poll;

  /// 二维码 src（data:image/png;base64,xxx 或 http(s) 兜底）
  String? _src;
  Uint8List? _bytes;

  /// 换码计数：作为 Image 的 key，保证换码后一定重绘（base64 变了但
  /// ImageCache 可能命中，key 变即换新 widget）
  int _seq = 0;

  bool _ready = true; // 离屏 WebView 是否就绪
  bool _booted = false;
  bool _success = false;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    // 面板可能已经加载过（上一次关窗只是换 about:blank，这里直接复用最近一张码）
    final existing = DouyinLogin.instance.lastQr;
    if (existing != null) _decode(existing);
    _sub = DouyinLogin.instance.qrStream.listen(_onQr);
    // 页面 JS 疑似登录（"登录成功"文案出现）→ 立刻查一次 cookie 做权威判定，
    // 不能直接判定成功（用户可能还没在手机 App 里点确认）
    _loginSub = DouyinLogin.instance.loginStream.listen((_) {
      if (mounted) _checkSession();
    });
    _boot();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _checkSession());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _sub?.cancel();
    _loginSub?.cancel();
    // 关窗即卸载离屏登录页（about:blank），避免常驻页面吃内存；
    // 只换页面不动 cookie，登录态保留。
    DouyinLogin.instance.stop();
    super.dispose();
  }

  Future<void> _boot() async {
    if (!mounted) return;
    // 换号扫码：先退出旧登录态，否则 /user/self 直接进个人主页不出码
    if (widget.relogin) {
      await DouyinLogin.instance.logout();
      if (mounted) {
        setState(() {
          _src = null;
          _bytes = null;
        });
      }
      await DouyinLogin.instance.start(force: true);
    } else {
      await DouyinLogin.instance.start();
    }
    if (!mounted) return;
    final ready = DouyinLogin.instance.attached;
    setState(() {
      _ready = ready;
      _booted = true;
    });
    if (!ready) AppLogger.log('dy-login', '登录对话框：离屏 WebView 未就绪');
  }

  void _onQr(String src) {
    if (!mounted) return;
    setState(() => _decode(src));
  }

  /// 解析 src → bytes，写入状态（调用方负责 setState）
  void _decode(String src) {
    Uint8List? bytes;
    if (src.startsWith('data:')) {
      final i = src.indexOf(',');
      if (i >= 0) {
        try {
          bytes = base64Decode(src.substring(i + 1));
        } catch (e) {
          AppLogger.log('dy-login', '二维码 base64 解码失败: $e');
        }
      }
    }
    _src = src;
    _bytes = bytes;
    _seq++;
  }

  Future<void> _checkSession() async {
    if (_success || _checking || !mounted) return;
    _checking = true;
    try {
      final ok = await DouyinLogin.checkSession();
      if (!ok || !mounted) return;
      await _onLoggedIn('cookie');
    } finally {
      _checking = false;
    }
  }

  /// 统一收口：cookie 确认存在登录态后走这里
  Future<void> _onLoggedIn(String from) async {
    if (_success || !mounted) return;
    setState(() => _success = true);
    _poll?.cancel();
    AppLogger.log('dy-login', '扫码登录成功（来源: $from）');
    await Future.delayed(const Duration(milliseconds: 700));
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _refresh() async {
    setState(() {
      _src = null;
      _bytes = null;
    });
    await DouyinLogin.instance.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.sizeOf(context).width;
    final panelW = screenW >= 400 ? 330.0 : screenW - 56;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Container(
        width: panelW,
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.card + 4),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.qr_code_2, size: 20, color: AppColors.primary),
                const SizedBox(width: AppSpacing.s),
                Text('登录抖音', style: AppText.subtitle),
                const Spacer(),
                SizedBox(
                  width: 32,
                  height: 32,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 20,
                    tooltip: '关闭',
                    icon: const Icon(Icons.close,
                        color: AppColors.textTertiary),
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s),
            Text(
              widget.reason ?? '登录后才会返回该作者的全部作品；扫码一次即可，之后保持登录。',
              textAlign: TextAlign.center,
              style: AppText.caption,
            ),
            const SizedBox(height: AppSpacing.l),
            _qrBox(),
            const SizedBox(height: AppSpacing.m),
            _statusLine(),
            const SizedBox(height: AppSpacing.s),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _success ? null : _refresh,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('刷新二维码'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('取消'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _qrBox() {
    const size = 208.0;

    if (_success) {
      return _box(
        size,
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(Icons.check_circle, size: 56, color: AppColors.success),
            SizedBox(height: AppSpacing.s),
            Text('登录成功', style: AppText.body),
          ],
        ),
      );
    }

    final bytes = _bytes;
    if (bytes != null) {
      return _box(
        size,
        Image.memory(
          bytes,
          key: ValueKey<int>(_seq),
          width: size - 16,
          height: size - 16,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) =>
              const Center(child: Text('二维码渲染失败', style: AppText.caption)),
        ),
      );
    }

    final src = _src;
    if (src != null) {
      // 兜底：万一以后抖音改成网络图地址
      return _box(
        size,
        Image.network(
          src,
          key: ValueKey<int>(_seq),
          width: size - 16,
          height: size - 16,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) =>
              const Center(child: Text('二维码加载失败', style: AppText.caption)),
        ),
      );
    }

    if (!_booted) {
      return _box(
        size,
        const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 2.4)),
            SizedBox(height: AppSpacing.m),
            Text('正在准备登录…', style: AppText.caption),
          ],
        ),
      );
    }

    if (!_ready) {
      return _box(
        size,
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 32, color: AppColors.danger),
            const SizedBox(height: AppSpacing.s),
            const Text('登录组件未就绪', style: AppText.caption),
            TextButton(onPressed: _boot, child: const Text('重试')),
          ],
        ),
      );
    }

    return _box(
      size,
      const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 2.4)),
          SizedBox(height: AppSpacing.m),
          Text('正在获取二维码…', style: AppText.caption),
        ],
      ),
    );
  }

  Widget _box(double size, Widget child) {
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(AppSpacing.s),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(AppRadius.chip + 4),
        border: Border.all(color: AppColors.divider),
      ),
      child: Center(child: child),
    );
  }

  Widget _statusLine() {
    final String text;
    final Color color;
    if (_success) {
      text = '已登录，正在继续…';
      color = AppColors.success;
    } else if (_bytes != null) {
      text = '打开抖音 App → 右上角「扫一扫」→ 确认登录';
      color = AppColors.textSecondary;
    } else if (_src != null) {
      text = '二维码加载中…';
      color = AppColors.textTertiary;
    } else {
      text = '二维码约 5 分钟有效，过期会自动换新';
      color = AppColors.textTertiary;
    }
    return Text(text, textAlign: TextAlign.center,
        style: AppText.caption.copyWith(color: color));
  }
}
