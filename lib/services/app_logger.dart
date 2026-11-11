import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../app_version.dart';

/// 应用日志：本地落盘 + 出问题时自动上报为 GitHub Issue。
///
/// 上报走 liuhaoranshiwo/media_saver 仓库的 Issues，我（后台）用 gh 工具直接读，
/// 无需你再截图/复制。日志只含诊断信息（链接、版本、错误、时间），不含你的 API Key。
class AppLogger {
  static final _buf = StringBuffer();
  static String _context = '';

  /// 设置本次上下文（如正在解析的链接、正在保存的项）
  static void setContext(String ctx) => _context = ctx;

  static void log(String tag, String msg) {
    final line =
        '[${DateTime.now().toIso8601String()}] $tag ${msg.length > 400 ? msg.substring(0, 400) : msg}';
    _buf.writeln(line);
    if (_buf.length > 40000) {
      final t = _buf.toString();
      _buf.clear();
      _buf.write(t.substring(t.length ~/ 2));
    }
  }

  /// 失败时上报（fire-and-forget，不阻塞 UI）
  static Future<void> report(String error) async {
    if (_ghToken.isEmpty) {
      return;
    }
    final body = '''
## 自动日志上报

- 版本：${AppVersion.full}
- 时间：${DateTime.now().toIso8601String()}
- 上下文：${_context.isEmpty ? '（无）' : _context}

### 错误
```
$error
```

### 日志
```
${_buf.toString()}
```
''';

    // 兜底：日志也写本地，供设置页查看/复制
    try {
      final dir = await getTemporaryDirectory();
      await File('${dir.path}/app_log.txt').writeAsString(body);
    } catch (_) {}

    try {
      await http
          .post(
        Uri.parse(
            'https://api.github.com/repos/liuhaoranshiwo/media_saver/issues'),
        headers: {
          'Authorization': 'Bearer $_ghToken',
          'Accept': 'application/vnd.github+json',
        },
        body: jsonEncode({
          'title': '[日志] ${AppVersion.full} $_context',
          'body': body,
        }),
      ).timeout(const Duration(seconds: 15));
    } catch (_) {
      // 上报失败不打扰用户
    }
  }

  static const _ghToken = '';
}
