import 'dart:async';

import 'package:flutter/services.dart';

/// 原生保存通道
///
/// iOS: AppDelegate 内注册 LivePhotoSaverPlugin（Swift，见 native/ios/）
///   - saveImage / saveVideo / saveLivePhoto（PHAssetCreationRequest 合成实况）
///   - removeWatermark：微博图片水印移除（高画质无水印：下载 large 全分辨率原图
///     + native 精准去水印，检测不到水印则原样保存）；小红书/抖音不传（零处理）
/// Android: MainActivity.kt 内注册（MediaStore 插入相册）
///   - Android 无 Live Photo 概念，saveLivePhoto 降级为分开保存图片+视频
class SaverChannel {
  static const _channel = MethodChannel('com.mediastack.media_saver/saver');

  /// [removeWatermark] 仅微博图片为 true（native 检测+去水印，无则原样）；
  /// 其他平台省略（= false = 原样保存）
  static Future<void> saveImage(String path, {bool removeWatermark = false}) async {
    // 超时保护：原生若因 PhotoKit/图像处理卡住，这里兜底抛出，
    // 避免界面永久停在"保存中…"（原生另有 25s 看门狗）
    await _channel.invokeMethod('saveImage', {
      'path': path,
      'removeWatermark': removeWatermark,
    }).timeout(const Duration(seconds: 30));
  }

  /// 生成 AI 修复用蒙版（白底 + 水印区域透明）。返回 null 表示未检测到水印
  static Future<String?> makeWatermarkMask(String path) async {
    return await _channel.invokeMethod<String>('makeWatermarkMask', {'path': path});
  }

  static Future<void> saveVideo(String path) async {
    await _channel.invokeMethod('saveVideo', {'path': path})
        .timeout(const Duration(seconds: 30));
  }

  /// 保存"画面视频 + 音轨"合成结果（抖音动图：play_addr 无声画面 + BGM mp3）。
  /// 原生用 AVFoundation 把视频轨与音频轨合并后写入相册。
  static Future<void> saveVideoWithAudio(
      String videoPath, String audioPath) async {
    await _channel.invokeMethod('saveVideoWithAudio', {
      'videoPath': videoPath,
      'audioPath': audioPath,
    }).timeout(const Duration(seconds: 60));
  }

  /// 读取上次未捕获异常的崩溃记录（无则 null）。
  /// 崩溃日志由 iOS 端 NSSetUncaughtExceptionHandler 写入临时目录
  static Future<String?> getCrashLog() async {
    try {
      return await _channel.invokeMethod<String>('getCrashLog');
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearCrashLog() async {
    try {
      await _channel.invokeMethod('clearCrashLog');
    } catch (_) {}
  }

  /// 尝试合成为 iOS 实况（Live Photo）
  /// [imagePath] 可为空（如推特 GIF 无静态帧），原生会从视频抽取首帧
  /// [removeWatermark] 微博静态帧去水印（高画质无水印），其他平台 false
  /// 返回 'live' 成功合成；'separate' 降级为分开保存
  static Future<String> saveLivePhoto({
    String? imagePath,
    required String videoPath,
    bool removeWatermark = false,
  }) async {
    return await _channel.invokeMethod<String>('saveLivePhoto', {
      if (imagePath != null) 'imagePath': imagePath,
      'videoPath': videoPath,
      'removeWatermark': removeWatermark,
    }).timeout(const Duration(seconds: 45)) ??
        'separate';
  }
}
