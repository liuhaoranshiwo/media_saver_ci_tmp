import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'proxy_config.dart';

/// 统一 HTTP 工具：
/// 1. 手动跟随 30x 重定向，拿到最终 URL（解析 v.douyin.com / xhslink.com 短链必需）
/// 2. 统一移动端 UA，避免被返回 PC 降级页
/// 3. X（推特）域名按 ProxyConfig 走代理（国内网络 X 域名被墙；其他平台始终直连）
class HttpUtil {
  /// X 生态域名（解析源 + 媒体 CDN），启用代理时这些走代理
  static const _xHostPatterns = [
    'twimg.com', // pbs.twimg.com / video.twimg.com（媒体 CDN）
    'twitter.com',
    'x.com',
    't.co',
    'fxtwitter.com',
    'fixupx.com',
  ];

  static bool _needsProxy(Uri uri) {
    if (!ProxyConfig.enabled) return false;
    final host = uri.host.toLowerCase();
    return _xHostPatterns.any((p) => host == p || host.endsWith('.$p'));
  }

  /// 按代理配置构建 HttpClient（X 域名走代理，其余 DIRECT）
  static HttpClient newHttpClient({String? ua}) {
    final client = HttpClient();
    if (ua != null) client.userAgent = ua;
    client.connectionTimeout = const Duration(seconds: 15);
    if (ProxyConfig.enabled) {
      client.findProxy = (uri) =>
          _needsProxy(uri) ? 'PROXY ${ProxyConfig.proxyValue}' : 'DIRECT';
    }
    return client;
  }

  static http.Client _ioClient() {
    if (!ProxyConfig.enabled) return http.Client();
    final inner = HttpClient()
      ..findProxy = (uri) =>
          _needsProxy(uri) ? 'PROXY ${ProxyConfig.proxyValue}' : 'DIRECT';
    return IOClient(inner);
  }

  /// iOS Safari UA —— 各平台 H5 页对 UA 有判断
  static const String iosUa =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1';

  static const String androidUa =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  static Future<(String finalUrl, String body)> getWithRedirects(
    String url, {
    Map<String, String>? headers,
    int maxRedirects = 8,
    String ua = iosUa,
  }) async {
    var current = Uri.parse(url);
    final client = newHttpClient(ua: ua);

    try {
      for (var i = 0; i < maxRedirects; i++) {
        final req = await client.getUrl(current);
        req.followRedirects = false;
        req.headers.set(HttpHeaders.acceptHeader,
            'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8');
        req.headers.set(HttpHeaders.acceptLanguageHeader, 'zh-CN,zh;q=0.9');
        headers?.forEach(req.headers.set);

        final resp = await req.close().timeout(const Duration(seconds: 20));
        if (resp.isRedirect) {
          final loc = resp.headers.value(HttpHeaders.locationHeader);
          if (loc == null) throw const HttpException('重定向缺少 Location');
          current = current.resolve(loc);
          continue;
        }
        if (resp.statusCode != 200) {
          throw HttpException('HTTP ${resp.statusCode} : $current');
        }
        final body = await resp.transform(utf8.decoder).join();
        return (current.toString(), body);
      }
      throw HttpException('重定向次数超过 $maxRedirects');
    } finally {
      client.close();
    }
  }

  /// POST JSON 并返回原始响应（状态码 + 全部 Set-Cookie + body）
  /// 抖音 ttwid 注册等需要读响应头的场景用
  static Future<(int status, List<String> setCookies, String body)>
      postJsonRaw(
    String url, {
    String? body,
    Map<String, String>? headers,
    String ua = iosUa,
  }) async {
    final client = newHttpClient(ua: ua);
    try {
      final req = await client.postUrl(Uri.parse(url));
      req.headers.set(
          HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
      req.headers.set(HttpHeaders.acceptHeader, '*/*');
      headers?.forEach(req.headers.set);
      if (body != null) {
        // ⚠️ 必须显式设 Content-Length：不设则 Dart 用 chunked 编码，
        // 字节系风控网关（ttwid register）会拒绝 chunked 请求体
        final bytes = utf8.encode(body);
        req.headers.set(HttpHeaders.contentLengthHeader, '${bytes.length}');
        req.add(bytes);
      }
      final resp = await req.close().timeout(const Duration(seconds: 20));
      final cookies = resp.headers[HttpHeaders.setCookieHeader] ?? const [];
      final text = await resp.transform(utf8.decoder).join();
      return (resp.statusCode, cookies, text);
    } finally {
      client.close();
    }
  }

  /// POST 表单（application/x-www-form-urlencoded），返回状态码 + Set-Cookie + body
  static Future<(int status, List<String> setCookies, String body)>
      postFormRaw(
    String url, {
    Map<String, String> fields = const {},
    Map<String, String>? headers,
    String ua = iosUa,
  }) async {
    final client = newHttpClient(ua: ua);
    try {
      final req = await client.postUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.contentTypeHeader,
          'application/x-www-form-urlencoded; charset=utf-8');
      req.headers.set(HttpHeaders.acceptHeader, '*/*');
      headers?.forEach(req.headers.set);
      final body = fields.entries
          .map((e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
          .join('&');
      final bytes = utf8.encode(body);
      req.headers.set(HttpHeaders.contentLengthHeader, '${bytes.length}');
      req.add(bytes);
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final cookies = resp.headers[HttpHeaders.setCookieHeader] ?? const [];
      final text = await resp.transform(utf8.decoder).join();
      return (resp.statusCode, cookies, text);
    } finally {
      client.close();
    }
  }

  /// GET 原始响应（手动跟随重定向，返回首个非 30x 响应的状态码 + Set-Cookie + body）
  /// 抖音 ttwid 回调页需要从 Set-Cookie 里取 ttwid
  static Future<(int status, List<String> setCookies, String body)> getRaw(
    String url, {
    Map<String, String>? headers,
    int maxRedirects = 8,
    String ua = iosUa,
  }) async {
    var current = Uri.parse(url);
    final client = newHttpClient(ua: ua);
    try {
      for (var i = 0; i < maxRedirects; i++) {
        final req = await client.getUrl(current);
        req.followRedirects = false;
        headers?.forEach(req.headers.set);
        final resp = await req.close().timeout(const Duration(seconds: 20));
        if (resp.isRedirect) {
          final loc = resp.headers.value(HttpHeaders.locationHeader);
          if (loc == null) throw const HttpException('重定向缺少 Location');
          current = current.resolve(loc);
          continue;
        }
        final cookies = resp.headers[HttpHeaders.setCookieHeader] ?? const [];
        final text = await resp.transform(utf8.decoder).join();
        return (resp.statusCode, cookies, text);
      }
      throw HttpException('重定向次数超过 $maxRedirects');
    } finally {
      client.close();
    }
  }

  /// 普通 JSON GET（微博 m.weibo.cn / X syndication 接口用）
  static Future<Map<String, dynamic>> getJson(
    String url, {
    Map<String, String>? headers,
    String ua = iosUa,
  }) async {
    final client = _ioClient();
    try {
      final resp = await client.get(
        Uri.parse(url),
        headers: {
          'User-Agent': ua,
          'Accept': 'application/json, text/plain, */*',
          ...?headers,
        },
      );
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode} : $url');
      }
      return jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  /// 流式下载文件到本地（用于原图/原视频保存，避免大文件占内存）
  static Future<http.StreamedResponse> downloadStream(String url,
      {String ua = iosUa, Map<String, String>? headers}) async {
    final client = _ioClient();
    final req = http.Request('GET', Uri.parse(url));
    req.headers.addAll({'User-Agent': ua, ...?headers});
    final resp = await client.send(req).timeout(const Duration(minutes: 10));
    // 注意：响应流被消费期间 client 不能 close，由调用方负责
    return resp;
  }

  static String? extractUrl(String text) {
    final m = RegExp(r'https?://[^\s，。,;；\u4e00-\u9fa5]+').firstMatch(text);
    return m?.group(0);
  }
}
