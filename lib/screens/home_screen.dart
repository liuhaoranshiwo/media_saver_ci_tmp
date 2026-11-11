import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/parsed_media.dart';
import '../services/parser_service.dart';
import '../services/ai_settings.dart';
import '../services/app_logger.dart';
import '../services/proxy_config.dart';
import '../services/saver_channel.dart';
import '../theme/app_theme.dart';
import 'result_screen.dart';

/// 首页：粘贴链接 → 解析
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _controller = TextEditingController();
  bool _loading = false;
  String? _error;
  bool _clipboardChecked = false;
  bool _hasProxy = false;

  @override
  void initState() {
    super.initState();
    _hasProxy = ProxyConfig.enabled;
    _checkClipboard();
    _showCrashLogIfAny();
  }

  /// 上次运行若发生未捕获崩溃，弹窗展示日志（方便用户截图反馈）
  Future<void> _showCrashLogIfAny() async {
    final log = await SaverChannel.getCrashLog();
    if (!mounted || log == null || log.trim().isEmpty) return;
    SaverChannel.clearCrashLog();
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('检测到上次异常退出'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(log,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('我知道了（欢迎截图反馈）'),
          ),
        ],
      ),
    );
  }

  Future<void> _checkClipboard() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text ?? '';
    if (text.contains('http') && mounted && !_clipboardChecked) {
      _clipboardChecked = true;
      setState(() => _controller.text = text.trim());
    }
  }

  Future<void> _parse() async {
    FocusScope.of(context).unfocus();
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _error = '请先粘贴分享链接或文案');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    AppLogger.setContext('解析: $text');
    AppLogger.log('parse', '开始解析');
    try {
      final result = await ParserService.parse(text);
      AppLogger.log('parse',
          '解析成功: ${result.items.length} 项, 类型=${result.items.map((i) => i.kind.name).join(",")}');
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ResultScreen(result: result),
      ));
    } on ParseException catch (e) {
      AppLogger.log('parse', '解析失败: ${e.message}');
      AppLogger.report(e.message);
      setState(() => _error = e.message);
    } catch (e) {
      AppLogger.log('parse', '解析异常: $e');
      AppLogger.report('解析异常: $e');
      setState(() => _error = '解析失败：网络异常或平台风控，请稍后重试');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openAiSettings() async {
    final baseCtrl = TextEditingController(text: AiSettings.baseUrl);
    final keyCtrl = TextEditingController(text: AiSettings.apiKey);
    final modelCtrl = TextEditingController(text: AiSettings.model);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设置'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '填自己的 Key，图片会直接发到该服务商，不经过任何中转。\n'
                '注意：DeepSeek 官方只有文本/识图，没有图像编辑接口；'
                '若要真正修复，请填支持 /v1/images/edits 的服务地址。',
                style: AppText.caption,
              ),
              const SizedBox(height: AppSpacing.m),
              TextField(
                controller: baseCtrl,
                decoration: const InputDecoration(
                  labelText: '服务地址',
                  hintText: 'https://api.deepseek.com',
                ),
              ),
              const SizedBox(height: AppSpacing.s),
              TextField(
                controller: keyCtrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'API Key'),
              ),
              const SizedBox(height: AppSpacing.s),
              TextField(
                controller: modelCtrl,
                decoration: const InputDecoration(
                  labelText: '模型名（可留空）',
                  hintText: 'gpt-image-1',
                ),
              ),
              // 2026-11-09：微博取图策略开关已移除 —— 全平台固定无水印直取，
              // 原样保存，无任何修补环节（微博 osj1080/oslarge、小红书 fileId 直链）
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await AiSettings.clearKey();
              if (ctx.mounted) Navigator.of(ctx).pop();
              if (mounted) setState(() {});
            },
            child: const Text('清除 Key'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              await AiSettings.save(
                base: baseCtrl.text,
                key: keyCtrl.text,
                mdl: modelCtrl.text,
              );
              if (ctx.mounted) Navigator.of(ctx).pop();
              if (mounted) {
                setState(() {});
                setState(() => _hasProxy = ProxyConfig.enabled);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    baseCtrl.dispose();
    keyCtrl.dispose();
    modelCtrl.dispose();
  }

  Future<void> _openProxySettings() async {
    final hostCtrl = TextEditingController(text: ProxyConfig.host ?? '');
    final portCtrl = TextEditingController(text: ProxyConfig.port ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('X（推特）代理', style: AppText.subtitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'X 的图片/视频在国内无法直连。若手机已开全局 VPN 则无需配置；'
                '否则填入本机/局域网代理（如 Shadowrocket、Surge 的 HTTP 端口）。',
                style: AppText.caption),
            const SizedBox(height: AppSpacing.m),
            TextField(
              controller: hostCtrl,
              decoration:
                  const InputDecoration(hintText: '代理地址，如 127.0.0.1'),
            ),
            const SizedBox(height: AppSpacing.s),
            TextField(
              controller: portCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(hintText: '端口，如 7890'),
            ),
            const SizedBox(height: AppSpacing.s),
            const Text('仅 X 相关域名走代理，其他平台始终直连。',
                style: AppText.caption),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('清除'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == true) {
      await ProxyConfig.save(hostCtrl.text, portCtrl.text);
    } else if (saved == false) {
      await ProxyConfig.save(null, null);
    }
    if (mounted) setState(() => _hasProxy = ProxyConfig.enabled);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('原存'),
        actions: [
          IconButton(
            tooltip: '设置（AI 去水印 / 微博取图）',
            icon: Icon(
                AiSettings.enabled ? Icons.auto_fix_high : Icons.auto_fix_off,
                color: AiSettings.enabled
                    ? AppColors.success
                    : AppColors.textTertiary),
            onPressed: _openAiSettings,
          ),
          IconButton(
            tooltip: 'X 代理设置',
            icon: Icon(_hasProxy ? Icons.vpn_key : Icons.vpn_key_off,
                color: _hasProxy ? AppColors.success : AppColors.textTertiary),
            onPressed: _openProxySettings,
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.l),
          children: [
            const SizedBox(height: AppSpacing.xl),
            Text('粘贴链接，保存原图', style: AppText.title.copyWith(fontSize: 26)),
            const SizedBox(height: AppSpacing.s),
            Text('支持小红书 / 微博 / 抖音 / 闲鱼，原图 · 原视频 · Live 图',
                style: AppText.secondary),
            const SizedBox(height: AppSpacing.xl),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    maxLines: 3,
                    minLines: 1,
                    style: AppText.body,
                    decoration: const InputDecoration(
                      hintText: '粘贴分享链接或整段分享文案…',
                    ),
                    onChanged: (_) => setState(() => _error = null),
                  ),
                ),
                if (_controller.text.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.close, color: AppColors.textTertiary),
                    onPressed: () {
                      _controller.clear();
                      setState(() => _error = null);
                    },
                  ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.s),
              Text(_error!,
                  style: AppText.body.copyWith(color: AppColors.danger)),
            ],
            const SizedBox(height: AppSpacing.l),
            FilledButton(
              onPressed: _loading ? null : _parse,
              child: _loading
                  ? const SizedBox(
                      width: 22, height: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.4, color: Colors.white))
                  : const Text('开始解析'),
            ),
            const SizedBox(height: AppSpacing.xxl),
            Row(
              children: [
                Text('支持的平台', style: AppText.subtitle),
                const Spacer(),
                Text('解析结果仅供个人使用', style: AppText.caption),
              ],
            ),
            const SizedBox(height: AppSpacing.m),
            const _PlatformChips(),
            const SizedBox(height: AppSpacing.xl),
            Container(
              padding: const EdgeInsets.all(AppSpacing.l),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadius.card),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('保存说明', style: AppText.subtitle),
                  const SizedBox(height: AppSpacing.s),
                  const _Bullet('图片保存为原始分辨率原图（非预览压缩图）'),
                  const _Bullet('视频保存为无水印原始码率视频'),
                  const _Bullet('Live 图默认存「图片 + 视频」，需要实况可点「合成实况照片」'),
                  const _Bullet('请尊重内容作者权益，勿用于二次分发'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlatformChips extends StatelessWidget {
  const _PlatformChips();

  @override
  Widget build(BuildContext context) {
    const platforms = [
      ('小红书', true),
      ('微博', true),
      ('抖音', true),
      ('X(推特)', true),
      ('闲鱼', false), // 受限：暂仅主图
    ];
    return LayoutBuilder(builder: (context, constraints) {
      // 每行 4 个，多余自动换行
      final cellWidth = (constraints.maxWidth - AppSpacing.s * 3) / 4;
      return Wrap(
        spacing: AppSpacing.s,
        runSpacing: AppSpacing.s,
        children: [
          for (final (name, ok) in platforms)
            SizedBox(
              width: cellWidth,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.m),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(AppRadius.chip),
                ),
                child: Column(
                  children: [
                    Text(name,
                        style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(ok ? '完整支持' : '受限支持',
                        style: AppText.caption.copyWith(
                            color: ok ? AppColors.success : AppColors.textTertiary)),
                  ],
                ),
              ),
            ),
        ],
      );
    });
  }
}

class _Bullet extends StatelessWidget {
  final String text;
  const _Bullet(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 7),
            child: Icon(Icons.circle, size: 5, color: AppColors.primary),
          ),
          const SizedBox(width: AppSpacing.s),
          Expanded(child: Text(text, style: AppText.secondary)),
        ],
      ),
    );
  }
}
