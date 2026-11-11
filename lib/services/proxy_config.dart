import 'package:shared_preferences/shared_preferences.dart';

/// X（推特）代理配置
///
/// X 相关域名（x.com / twitter.com / twimg.com 等）在国内网络无法直连，
/// 解析与下载都需要代理。设计原则：只有 X 域名走代理，其他平台始终直连，
/// 不填代理时其他平台完全不受影响。手机开了全局 VPN 时无需配置。
class ProxyConfig {
  ProxyConfig._();

  static const _keyHost = 'x_proxy_host';
  static const _keyPort = 'x_proxy_port';

  static String? host;
  static String? port;

  static bool get enabled =>
      (host?.isNotEmpty ?? false) && (port?.isNotEmpty ?? false);

  static String get proxyValue => '$host:$port';

  static Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    host = sp.getString(_keyHost);
    port = sp.getString(_keyPort);
  }

  static Future<void> save(String? newHost, String? newPort) async {
    host = (newHost?.trim().isEmpty ?? true) ? null : newHost!.trim();
    port = (newPort?.trim().isEmpty ?? true) ? null : newPort!.trim();
    final sp = await SharedPreferences.getInstance();
    if (host == null) {
      await sp.remove(_keyHost);
    } else {
      await sp.setString(_keyHost, host!);
    }
    if (port == null) {
      await sp.remove(_keyPort);
    } else {
      await sp.setString(_keyPort, port!);
    }
  }
}
