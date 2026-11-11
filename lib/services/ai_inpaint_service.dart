import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'ai_settings.dart';

/// AI 图像修复（自带 Key）
///
/// 协议：POST {baseUrl}/v1/images/edits（multipart）
///   - image: 原图
///   - mask : 黑白/带 alpha 的蒙版，**透明区域 = 需要重绘**（OpenAI 语义）
///   - model/prompt/size/n
/// 返回：data[0].b64_json 或 data[0].url，落到临时文件后返回路径。
class AiInpaintService {
  /// 抛出的异常都带可读原因，UI 直接展示
  static Future<String> inpaint({
    required String imagePath,
    required String maskPath,
    String prompt = 'remove the watermark text and logo, '
        'keep the original texture, lighting and everything else unchanged',
  }) async {
    if (!AiSettings.enabled) {
      throw Exception('未配置 AI Key，请先在设置里填写');
    }
    final base = AiSettings.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse('$base/v1/images/edits');
    if (uri == null || !uri.hasScheme) {
      throw Exception('服务地址无效：${AiSettings.baseUrl}');
    }

    final req = http.MultipartRequest('POST', uri);
    req.headers['Authorization'] = 'Bearer ${AiSettings.apiKey}';
    req.fields['prompt'] = prompt;
    req.fields['n'] = '1';
    req.fields['size'] = 'auto';
    req.fields['response_format'] = 'b64_json';
    if (AiSettings.model.trim().isNotEmpty) {
      req.fields['model'] = AiSettings.model.trim();
    }
    req.files.add(await http.MultipartFile.fromPath('image', imagePath));
    req.files.add(await http.MultipartFile.fromPath('mask', maskPath));

    http.Response res;
    try {
      final streamed = await req.send().timeout(const Duration(seconds: 90));
      res = await http.Response.fromStream(streamed);
    } on TimeoutException {
      throw Exception('AI 服务响应超时（90 秒）');
    } catch (e) {
      throw Exception('请求失败：$e');
    }

    if (res.statusCode == 401 || res.statusCode == 403) {
      throw Exception('Key 无效或无权限（HTTP ${res.statusCode}）');
    }
    if (res.statusCode == 404 || res.statusCode == 405) {
      throw Exception(
          '该服务没有图像编辑接口（HTTP ${res.statusCode}）。\n'
          'DeepSeek 官方只提供文本/识图，不能修图；请改填支持 /v1/images/edits 的服务地址。');
    }
    if (res.statusCode != 200) {
      final msg = _briefError(res.body);
      if (msg.contains('model') && msg.contains('not')) {
        throw Exception('该服务不支持这个模型：$msg');
      }
      throw Exception('AI 服务返回 HTTP ${res.statusCode}：$msg');
    }

    Map<String, dynamic> body;
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw Exception('AI 返回不是合法 JSON');
    }

    final data = body['data'];
    if (data is! List || data.isEmpty) {
      final err = body['error'];
      throw Exception('AI 未返回图片：${_briefError(jsonEncode(err ?? body))}');
    }
    final first = data.first as Map;
    final b64 = first['b64_json'] as String?;
    final url = first['url'] as String?;

    final dir = await getTemporaryDirectory();
    final out = File('${dir.path}/ai_fix_${DateTime.now().millisecondsSinceEpoch}.png');

    if (b64 != null && b64.isNotEmpty) {
      await out.writeAsBytes(base64Decode(b64));
      return out.path;
    }
    if (url != null && url.isNotEmpty) {
      final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 60));
      if (r.statusCode != 200) throw Exception('下载修复结果失败：HTTP ${r.statusCode}');
      await out.writeAsBytes(r.bodyBytes);
      return out.path;
    }
    throw Exception('AI 返回里没有图片数据');
  }

  static String _briefError(String raw) {
    var s = raw.trim();
    if (s.length > 240) s = s.substring(0, 240);
    return s.replaceAll(RegExp(r'\s+'), ' ');
  }
}
