import 'package:shared_preferences/shared_preferences.dart';

/// AI 去水印的接口配置（用户自带 Key，仅存本机）
///
/// 说明：DeepSeek 官方 API 只提供文本/识图能力，**没有图像编辑接口**
/// （2026-11 官方文档：image understanding is not image generation）。
/// 因此这里做成「地址可配置」的通用通道：
///   - 填 DeepSeek 地址 → 调用会明确返回"该服务不支持图像编辑"
///   - 填任意支持 POST /v1/images/edits 的服务（OpenAI、国内兼容代理等）→ 可用
class AiSettings {
  static const _kBase = 'ai_base_url';
  static const _kKey = 'ai_api_key';
  static const _kModel = 'ai_model';

  static String baseUrl = 'https://api.deepseek.com';
  static String apiKey = '';
  static String model = '';

  /// 是否已配置（有 key 才显示 AI 按钮）
  static bool get enabled => apiKey.trim().isNotEmpty;

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    baseUrl = p.getString(_kBase) ?? 'https://api.deepseek.com';
    apiKey = p.getString(_kKey) ?? '';
    model = p.getString(_kModel) ?? '';
  }

  static Future<void> save({
    required String base,
    required String key,
    required String mdl,
  }) async {
    final p = await SharedPreferences.getInstance();
    baseUrl = base.trim();
    apiKey = key.trim();
    model = mdl.trim();
    await p.setString(_kBase, baseUrl);
    await p.setString(_kKey, apiKey);
    await p.setString(_kModel, model);
  }

  static Future<void> clearKey() async {
    final p = await SharedPreferences.getInstance();
    apiKey = '';
    await p.setString(_kKey, '');
  }

  /// 显示用的脱敏 key
  static String get maskedKey {
    if (apiKey.length <= 8) return apiKey.isEmpty ? '未设置' : '****';
    return '${apiKey.substring(0, 4)}…${apiKey.substring(apiKey.length - 4)}';
  }
}
