import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'services/douyin_capture.dart';
import 'services/ai_settings.dart';
import 'services/app_logger.dart';
import 'services/app_settings.dart';
import 'services/proxy_config.dart';
import 'theme/app_theme.dart';
import 'screens/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ProxyConfig.load();
  await AiSettings.load();
  await AppSettings.load();
  AppLogger.log('app', '启动');
  // 崩溃/未捕获异常自动上报（只记日志，不改变任何行为）
  FlutterError.onError = (details) {
    final msg = '${details.exception}\n${details.stack ?? ''}';
    AppLogger.log('flutter-error', msg);
    AppLogger.report('Flutter异常: ${details.exception}');
  };
  PlatformDispatcher.instance.onError = (e, stack) {
    AppLogger.log('uncaught', '$e\n$stack');
    AppLogger.report('未捕获异常: $e');
    return true;
  };
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ),
  );
  runApp(const MediaSaverApp());
}

class MediaSaverApp extends StatelessWidget {
  const MediaSaverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '原存 · 去水印保存',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: Stack(
        children: [
          const HomeScreen(),
          // 抖音解析依赖的离屏 WebView（屏幕外，不可见，勿删）
          const DouyinCaptureView(),
        ],
      ),
    );
  }
}
