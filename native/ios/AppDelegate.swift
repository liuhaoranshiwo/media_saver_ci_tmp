// AppDelegate.swift
// flutter create . 生成 ios 平台目录后，用本文件【整体替换】ios/Runner/AppDelegate.swift
//
// 插件与 AppDelegate 合并在单文件内：这样无需修改 project.pbxproj
// （Xcode 只编译工程文件里列出的源码，直接往目录加新 .swift 不会被编译）。
//
// 职责：
//   saveImage / saveVideo —— 写入系统相册（PHPhotoLibrary，addOnly 权限即可）
//   saveLivePhoto         —— 合成为 iOS 实况照片，三级回退：
//       ① 直接 .photo + .pairedVideo 提交（上游本身就是合法实况资源时）
//       ② 失败 → AVAssetReader/Writer 重封装视频并注入 Apple 实况元数据
//          （content.identifier + StillImageTime 轨道），
//          静态帧缺失时（推特 GIF）用 AVAssetImageGenerator 抽首帧，再次提交
//       ③ 仍失败 → 图片与视频分开保存，返回 'separate' 由 UI 提示

import Flutter
import Photos
import AVFoundation
import UIKit
import Vision

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    installCrashLogger()
    GeneratedPluginRegistrant.register(with: self)
    LivePhotoSaverPlugin.register(
      with: registrar(forPlugin: "LivePhotoSaverPlugin")!)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// 未捕获异常记录到临时目录，下次启动 Dart 端读取并展示
  /// （用户截个图就能把崩溃原因发回来，不用连电脑取日志）
  private func installCrashLogger() {
    NSSetUncaughtExceptionHandler { exception in
      let dict: [String: Any] = [
        "name": exception.name.rawValue,
        "reason": exception.reason ?? "",
        "stack": exception.callStackSymbols.prefix(30).joined(separator: "\n"),
        "time": ISO8601DateFormatter().string(from: Date()),
      ]
      if let data = try? JSONSerialization.data(withJSONObject: dict) {
        try? data.write(to: FileManager.default.temporaryDirectory
          .appendingPathComponent("media_saver_crash.json"))
      }
    }
  }
}



/// 实况合成链路打点（写入临时目录 live_diag.log，可在"崩溃日志"里查看）
final class LiveDiag {
  static let shared = LiveDiag()
  private let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("live_diag.log")
  private let lock = NSLock()
  func log(_ s: String) {
    lock.lock(); defer { lock.unlock() }
    let line = "[\(Date().timeIntervalSince1970.rounded())] \(s)\n"
    if let h = try? FileHandle(forWritingTo: url) {
      h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
      try? Data(line.utf8).write(to: url)
    }
  }
  func reset() { try? FileManager.default.removeItem(at: url) }
  func read() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
}

/// 保证 FlutterResult 只被调用一次（重复调用会让 Flutter 侧 Future 异常；
/// 一次不调用则 UI 永久卡在"保存中…"）
final class OnceResult {
  private var done = false
  private let lock = NSLock()
  private let result: FlutterResult
  init(_ result: @escaping FlutterResult) { self.result = result }
  func fire(_ value: Any?) {
    lock.lock(); defer { lock.unlock() }
    if done { return }
    done = true
    result(value)
  }
  func fail(_ code: String, _ msg: String?) {
    fire(FlutterError(code: code, message: msg, details: nil))
  }
}

public class LivePhotoSaverPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.mediastack.media_saver/saver",
      binaryMessenger: registrar.messenger())
    let instance = LivePhotoSaverPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "saveImage":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "缺少 path", details: nil)); return
      }
      saveImage(path: path,
                removeWatermark: args["removeWatermark"] as? Bool ?? false,
                result: result)

    case "saveVideo":
      guard let path = (call.arguments as? [String: Any])?["path"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "缺少 path", details: nil)); return
      }
      saveVideo(path: path, result: result)

    case "saveVideoWithAudio":
      guard let args = call.arguments as? [String: Any],
            let videoPath = args["videoPath"] as? String,
            let audioPath = args["audioPath"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "缺少 videoPath/audioPath", details: nil)); return
      }
      saveVideoWithAudio(videoPath: videoPath, audioPath: audioPath, result: result)

    case "saveLivePhoto":
      guard let args = call.arguments as? [String: Any],
            let videoPath = args["videoPath"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "缺少 videoPath", details: nil)); return
      }
      let imagePath = args["imagePath"] as? String
      saveLivePhoto(imagePath: imagePath, videoPath: videoPath,
                    removeWatermark: args["removeWatermark"] as? Bool ?? false,
                    result: result)

    case "makeWatermarkMask":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "缺少 path", details: nil)); return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        let out = self.buildWatermarkMask(path: path)
        DispatchQueue.main.async { result(out) }
      }

    case "getCrashLog":
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("media_saver_crash.json")
      var text = ""
      if let data = try? Data(contentsOf: url),
         let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        text = """
        时间: \(dict["time"] ?? "")
        类型: \(dict["name"] ?? "")
        原因: \(dict["reason"] ?? "")

        \(dict["stack"] ?? "")
        """
      }
      // 实况合成诊断（每次保存都会累积，定位失败环节用）
      let diag = LiveDiag.shared.read()
      if !diag.isEmpty {
        text += "\n\n==== 实况诊断 ====\n" + diag
      }
      result(text.isEmpty ? nil : text)

    case "clearCrashLog":
      LiveDiag.shared.reset()
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("media_saver_crash.json")
      try? FileManager.default.removeItem(at: url)
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - 权限

  private func requestPhotoAuth(_ completion: @escaping (Bool) -> Void) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      DispatchQueue.main.async {
        completion(status == .authorized || status == .limited)
      }
    }
  }

  // MARK: - 普通保存

  private func saveImage(path: String, removeWatermark: Bool,
                         result: @escaping FlutterResult) {
    let once = OnceResult(result)
    // 看门狗：25s 未回调就明确失败，避免 UI 永久"保存中…"
    DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
      once.fail("SAVE_TIMEOUT", "保存超时，请到相册确认是否已保存")
    }
    requestPhotoAuth { ok in
      guard ok else {
        once.fail("NO_PERMISSION", "相册权限被拒绝"); return
      }
      let commit: (String) -> Void = { finalPath in
        // PhotoKit 仅原生支持 jpeg/png/heic/gif；webp/avif（抖音图集直链即 webp:
        // ~tplv-dy-lqen-new:...:q80.webp）直接入库会静默失败，先转 JPEG
        let safePath = self.normalizeForPhotoKit(finalPath)
        let url = URL(fileURLWithPath: safePath)
        PHPhotoLibrary.shared().performChanges({
          PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
        }) { ok2, error in
          DispatchQueue.main.async {
            ok2 ? once.fire(nil)
                : once.fail("SAVE_FAILED", error?.localizedDescription)
          }
        }
      }
      if removeWatermark {
        DispatchQueue.global(qos: .userInitiated).async {
          // autoreleasepool：解码/重编码产生的 CoreGraphics 对象及时释放，避免大图内存堆积
          var cleaned = path
          autoreleasepool {
            cleaned = self.cleanWeiboWatermark(path: path)
          }
          commit(cleaned)
        }
      } else {
        commit(path)
      }
    }
  }

  private func saveVideo(path: String, result: @escaping FlutterResult) {
    let once = OnceResult(result)
    DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
      once.fail("SAVE_TIMEOUT", "视频保存超时，请到相册确认")
    }
    let url = URL(fileURLWithPath: path)
    requestPhotoAuth { ok in
      guard ok else {
        once.fail("NO_PERMISSION", "相册权限被拒绝"); return
      }
      PHPhotoLibrary.shared().performChanges({
        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
      }) { ok2, error in
        DispatchQueue.main.async {
          ok2 ? once.fire(nil)
              : once.fail("SAVE_FAILED", error?.localizedDescription)
        }
      }
    }
  }

  /// 保存"画面视频 + 音轨"合成结果（抖音动图：play_addr 无声画面 + BGM mp3）。
  /// 用 AVFoundation 把视频轨与音频轨合并，导出 mp4 后写入相册。
  private func saveVideoWithAudio(videoPath: String, audioPath: String,
                                  result: @escaping FlutterResult) {
    let once = OnceResult(result)
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
      once.fail("SAVE_TIMEOUT", "音视频合成超时，请到相册确认")
    }
    requestPhotoAuth { ok in
      guard ok else {
        once.fail("NO_PERMISSION", "相册权限被拒绝"); return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        let videoURL = URL(fileURLWithPath: videoPath)
        let audioURL = URL(fileURLWithPath: audioPath)
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)

        guard let videoTrack = videoAsset.tracks(withMediaType: .video).first else {
          once.fail("NO_VIDEO", "视频轨读取失败"); return
        }
        let comp = AVMutableComposition()
        guard let cv = comp.addMutableTrack(withMediaType: .video,
                                            preferredTrackID: kCMPersistentTrackID_Invalid) else {
          once.fail("NO_VIDEO", "视频轨创建失败"); return
        }
        let videoDuration = videoAsset.duration
        do {
          try cv.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration),
                                 of: videoTrack, at: .zero)
        } catch {
          once.fail("VIDEO_INSERT", error.localizedDescription); return
        }
        // 保留竖屏方向（抖音实况视频带 90° 旋转的 preferredTransform）
        cv.preferredTransform = videoTrack.preferredTransform

        // 音轨：BGM 比画面长则截取到画面时长；比画面短则循环补足
        if let audioTrack = audioAsset.tracks(withMediaType: .audio).first,
           let ca = comp.addMutableTrack(withMediaType: .audio,
                                         preferredTrackID: kCMPersistentTrackID_Invalid) {
          let audioDuration = audioAsset.duration
          var remaining = videoDuration
          var at = CMTime.zero
          var guardCount = 0
          while CMTimeCompare(remaining, .zero) > 0 && guardCount < 100 {
            guardCount += 1
            let seg = CMTimeMinimum(audioDuration, remaining)
            if CMTimeCompare(seg, .zero) <= 0 { break }
            do {
              try ca.insertTimeRange(CMTimeRange(start: .zero, duration: seg),
                                     of: audioTrack, at: at)
            } catch { break }
            at = CMTimeAdd(at, seg)
            remaining = CMTimeSubtract(remaining, seg)
          }
        }

        guard let exporter = AVAssetExportSession(asset: comp,
                                                  presetName: AVAssetExportPresetHighestQuality) else {
          once.fail("EXPORT", "导出器创建失败"); return
        }
        let outURL = FileManager.default.temporaryDirectory
          .appendingPathComponent("mux_\(UUID().uuidString).mp4")
        exporter.outputURL = outURL
        exporter.outputFileType = .mp4
        exporter.exportAsynchronously {
          DispatchQueue.main.async {
            guard exporter.status == .completed else {
              once.fail("EXPORT_FAILED", exporter.error?.localizedDescription); return
            }
            PHPhotoLibrary.shared().performChanges({
              PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outURL)
            }) { ok2, error in
              DispatchQueue.main.async {
                try? FileManager.default.removeItem(at: outURL)
                ok2 ? once.fire(nil)
                    : once.fail("SAVE_FAILED", error?.localizedDescription)
              }
            }
          }
        }
      }
    }
  }

  // MARK: - Live Photo（三级回退）

  private func saveLivePhoto(imagePath: String?, videoPath: String,
                             removeWatermark: Bool,
                             result: @escaping FlutterResult) {
    let once = OnceResult(result)
    // 看门狗：实况链路含转码/注入，40s 仍未回调就明确失败，避免 UI 永久"保存中…"
    DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
      once.fail("SAVE_TIMEOUT", "实况保存超时，请到相册确认")
    }
    requestPhotoAuth { ok in
      guard ok else {
        once.fail("NO_PERMISSION", "相册权限被拒绝"); return
      }

      // 0. 图片标准化：webp/HEIC 异常等不支持格式重编码为 JPEG。
      // ⚠️ 2026-11-06：webp 直接提交 .photo 会失败，降级保存时
      // creationRequestForAssetFromImage 也会【静默失败】→ 相册只剩视频。
      var imagePath = imagePath
      if let p = imagePath {
        imagePath = self.normalizeImageForLivePhoto(p)
      }
      // 0.5 图片缺失时先抽视频首帧补上，杜绝"只有视频"的实况
      let videoFile = self.normalizedLiveVideoFile(URL(fileURLWithPath: videoPath))
      LiveDiag.shared.log("live start image=\(imagePath?.split(separator: "/").last ?? "-") video=\(videoFile.lastPathComponent)")
      if imagePath == nil {
        imagePath = self.extractFirstFrame(asset: AVURLAsset(url: videoFile))?.path
        LiveDiag.shared.log("frame extracted -> \(imagePath == nil ? "nil" : "ok")")
      }

      let run: (String?) -> Void = { cleanedImagePath in
        let videoURL = videoFile
        let imageURL = cleanedImagePath.map { URL(fileURLWithPath: $0) }

        let asset = AVURLAsset(url: videoURL)
        // 只有视频自带 Apple 实况元数据时，直接提交才有可能成功；
        // 否则 PhotoKit 必定返回 -1，白跑一次事务还可能污染相册状态。
        let hasLiveMeta = asset.metadata.contains {
          $0.identifier == .quickTimeMetadataContentIdentifier
        }
        LiveDiag.shared.log("hasLiveMeta=\(hasLiveMeta)")

        let tryConvert: () -> Void = {
          // ② 元数据注入后重试
          self.convertVideoForLivePhoto(asset: asset) { convertedURL in
            guard let convertedURL = convertedURL else {
              self.separateSave(imageURL: imageURL, videoURL: videoURL, result: { once.fire($0) }); return
            }
            let frame: URL?
            if let imageURL = imageURL {
              frame = imageURL
            } else {
              frame = self.extractFirstFrame(asset: asset)
            }
            guard let frameURL = frame else {
              self.separateSave(imageURL: imageURL, videoURL: videoURL, result: { once.fire($0) }); return
            }
            self.createLiveAsset(imageURL: frameURL, videoURL: convertedURL) { ok2 in
              if ok2 {
                once.fire("live")
              } else {
                // ③ 分开保存
                self.separateSave(imageURL: frameURL, videoURL: videoURL, result: { once.fire($0) })
              }
            }
          }
        }

        if hasLiveMeta {
          // ① 直接合成
          self.createLiveAsset(imageURL: imageURL, videoURL: videoURL) { ok1 in
            if ok1 { once.fire("live") } else { tryConvert() }
          }
        } else {
          tryConvert()
        }
      }

      if removeWatermark, let ip = imagePath {
        DispatchQueue.global(qos: .userInitiated).async {
          run(self.cleanWeiboWatermark(path: ip))
        }
      } else {
        run(imagePath)
      }
    }
  }


  /// 生成"AI 图像修复"用的蒙版 PNG：
  /// Vision 定位水印文本框 → 框内（略膨胀）alpha=0（表示需要重绘），其余 alpha=255。
  /// 返回 null 表示没检测到水印（调用方应提示改用本地修补）。
  private func buildWatermarkMask(path: String) -> String? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = cg.width, h = cg.height
    let boxes = detectWatermarkTextBoxes(cg, w: w, h: h)
    if boxes.isEmpty {
      LiveDiag.shared.log("mask: no watermark box")
      return nil
    }

    // 白底 + 透明洞的 RGBA 缓冲
    let bpr = w * 4
    var buf = [UInt8](repeating: 255, count: bpr * h)
    for r in boxes {
      let pad = 6
      let x0 = max(0, Int(r.minX) - pad), x1 = min(w - 1, Int(r.maxX) + pad)
      let y0 = max(0, Int(r.minY) - pad), y1 = min(h - 1, Int(r.maxY) + pad)
      if x1 <= x0 || y1 <= y0 { continue }
      for y in y0...y1 {
        let row = y * bpr
        for x in x0...x1 {
          let o = row + x * 4
          buf[o] = 0; buf[o + 1] = 0; buf[o + 2] = 0; buf[o + 3] = 0
        }
      }
    }
    LiveDiag.shared.log("mask: \(boxes.count) boxes, \(w)x\(h)")

    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: bpr, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let outImage = ctx.makeImage() else { return nil }
    let outURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("wm_mask_\(UUID().uuidString).png")
    guard let dest = CGImageDestinationCreateWithURL(
      outURL as CFURL, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, outImage, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return outURL.path
  }

  /// 提交 .photo + .pairedVideo，返回是否成功。
  /// ⚠️ imageURL 为空时直接返回失败：只提交 pairedVideo 会生成
  /// "只有视频"的实况（这正是用户反馈"只导出视频"的一条根因）。

  /// 实况配对视频必须容器与扩展名一致：微博实况下载下来常是
  /// "内容 QuickTime MOV、文件名 .mp4"（Dart 侧按 ext=mp4 命名），
  /// PhotoKit 会因 UTI 不匹配而拒收 .pairedVideo → 退回"分开保存"。
  /// 这里按 ftyp 品牌嗅探真实容器，必要时复制成正确扩展名的临时文件。
  private func normalizedLiveVideoFile(_ url: URL) -> URL {
    guard let fh = try? FileHandle(forReadingFrom: url) else { return url }
    let head = (try? fh.read(upToCount: 16)) ?? Data()
    try? fh.close()
    guard head.count >= 12 else { return url }
    let brand = String(data: head.subdata(in: 8..<12), encoding: .ascii) ?? ""
    let isQuickTime = brand.contains("qt")
    let ext = url.pathExtension.lowercased()
    let want = isQuickTime ? "mov" : "mp4"
    LiveDiag.shared.log("video brand=\(brand) ext=\(ext) want=\(want)")
    if ext == want || (want == "mp4" && (ext == "m4v")) { return url }
    let dst = FileManager.default.temporaryDirectory
      .appendingPathComponent("live_src_\(UUID().uuidString).\(want)")
    do {
      try FileManager.default.copyItem(at: url, to: dst)
      LiveDiag.shared.log("video copied -> \(dst.lastPathComponent)")
      return dst
    } catch {
      LiveDiag.shared.log("video copy failed: \(error.localizedDescription)")
      return url
    }
  }

  private func createLiveAsset(imageURL: URL?, videoURL: URL,
                               completion: @escaping (Bool) -> Void) {
    guard imageURL != nil else {
      DispatchQueue.main.async { completion(false) }
      return
    }
    PHPhotoLibrary.shared().performChanges({
      let request = PHAssetCreationRequest.forAsset()
      let options = PHAssetResourceCreationOptions()
      options.shouldMoveFile = false
      request.addResource(with: .photo, fileURL: imageURL!, options: options)
      request.addResource(with: .pairedVideo, fileURL: videoURL, options: options)
    }) { ok, err in
      LiveDiag.shared.log("createLiveAsset ok=\(ok) err=\(err?.localizedDescription ?? "-")")
      DispatchQueue.main.async { completion(ok) }
    }
  }

  /// 图片与视频分开保存（保底方案，内容不丢）。
  /// 两者各自独立事务：图片失败不影响视频落盘，且能感知图片是否真的存上。
  private func separateSave(imageURL: URL?, videoURL: URL,
                            result: @escaping FlutterResult) {
    PHPhotoLibrary.shared().performChanges({
      PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
    }) { okVideo, _ in
      guard let imageURL = imageURL else {
        DispatchQueue.main.async {
          okVideo ? result("videoOnly")
                  : result(FlutterError(code: "SAVE_FAILED", message: "视频保存失败", details: nil))
        }
        return
      }
      let safeImage = self.normalizeForPhotoKit(imageURL.path)
      PHPhotoLibrary.shared().performChanges({
        PHAssetChangeRequest.creationRequestForAssetFromImage(
          atFileURL: URL(fileURLWithPath: safeImage))
      }) { okImage, _ in
        DispatchQueue.main.async {
          // 至少视频存上了就算成功；图片静默失败时明确告知
          if okVideo && okImage {
            result("separate")
          } else if okVideo {
            result("videoOnly")
          } else if okImage {
            result("imageOnly")
          } else {
            result(FlutterError(code: "SAVE_FAILED", message: "图片与视频均保存失败", details: nil))
          }
        }
      }
    }
  }

  /// 图片格式标准化：webp/GIF 静帧/损坏数据等重编码为高质量 JPEG。

  /// 重编码时保留原始 EXIF（设备型号、拍摄时间、GPS 等）。
  /// 不保留 PixelWidth/Height/颜色配置这些派生字段，避免与目标尺寸冲突。
  private func preservedMetadata(from src: CGImageSource,
                                 quality: Double = 1.0) -> CFDictionary {
    var out: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
    if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
      for key in [kCGImagePropertyExifDictionary,
                  kCGImagePropertyGPSDictionary,
                  kCGImagePropertyTIFFDictionary,
                  kCGImagePropertyIPTCDictionary] {
        if let v = props[key] { out[key] = v }
      }
    }
    return out as CFDictionary
  }

  /// JPEG/HEIC/PNG 原样返回（.photo 可直接提交）。
  private func normalizeImageForLivePhoto(_ path: String) -> String {
    let url = URL(fileURLWithPath: path)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return path }
    let uti = CGImageSourceGetType(src) as String? ?? ""
    if uti == "public.jpeg" || uti == "public.heic" || uti == "public.png" {
      return path
    }
    guard let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return path }
    let outURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("lp_\(UUID().uuidString).jpg")
    guard let dest = CGImageDestinationCreateWithURL(
      outURL as CFURL, "public.jpeg" as CFString, 1, nil) else { return path }
    CGImageDestinationAddImage(dest, cg, preservedMetadata(from: src))
    guard CGImageDestinationFinalize(dest) else { return path }
    return outURL.path
  }

  /// 入库前格式归一化：PhotoKit 原生只认 jpeg/png/heic/gif，
  /// webp/avif 等（抖音图集直链为 q80 webp）需解码重编码为 JPEG，
  /// 否则 creationRequestForAssetFromImage 静默失败（performChanges 返回成功但相册无图）。
  private func normalizeForPhotoKit(_ path: String) -> String {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
      return path
    }
    let uti = CGImageSourceGetType(src) as String? ?? ""
    let native: Set<String> = ["public.jpeg", "public.png", "public.heic",
                               "com.compuserve.gif"]
    if native.contains(uti) { return path }
    // 动图（webp 动图）取首帧
    guard let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return path }
    // 先铺白底再绘制：webp/avif 的透明区域直接编码成 JPEG 会变成白块/黑块
    let iw = cg.width, ih = cg.height
    guard let ctx = CGContext(data: nil, width: iw, height: ih, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
      return path
    }
    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: iw, height: ih))
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: iw, height: ih))
    guard let flat = ctx.makeImage() else { return path }
    let outURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("pk_\(UUID().uuidString).jpg")
    guard let dest = CGImageDestinationCreateWithURL(
      outURL as CFURL, "public.jpeg" as CFString, 1, nil) else { return path }
    CGImageDestinationAddImage(dest, flat, preservedMetadata(from: src))
    guard CGImageDestinationFinalize(dest) else { return path }
    return outURL.path
  }

  // MARK: - 视频抽帧
  /// 抽取视频首帧存为 JPEG，失败返回 nil
  private func extractFirstFrame(asset: AVAsset) -> URL? {
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
    do {
      let cgImage = try gen.copyCGImage(
        at: CMTime(seconds: 0.05, preferredTimescale: 600), actualTime: nil)
      guard let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.95)
      else { return nil }
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("live_frame_\(UUID().uuidString).jpg")
      try data.write(to: url)
      return url
    } catch {
      return nil
    }
  }

  // MARK: - 实况元数据注入

  /// 用 AVAssetReader/Writer 转封装为 MOV，并注入 Apple 实况元数据：
  ///   1. 文件级元数据 com.apple.quicktime.content.identifier = UUID
  ///   2. metadata 轨道写入 StillImageTime（值 0，时间 0）
  /// 成功返回临时 MOV 路径，失败返回 nil
  ///
  /// ⚠️ 两个关键点（都曾是闪退来源）：
  ///   a) finishWriting 绝不能在输入未 markAsFinished 时调用，否则抛
  ///      NSInternalInconsistencyException（NSException 无法捕获 → 秒退）。
  ///      必须 视频+音频+元数据 三个输入全部完成后才收尾，状态机防重入。
  ///   b) 采用【零解码转封装】：reader/writer 的 outputSettings 传 nil，
  ///      直接搬运原始编码帧（不逐帧解码重编码）。内存占用从数百 MB 降到几 MB，
  ///      杜绝大视频内存峰值被系统杀进程，且原画质原码率无损。
  private func convertVideoForLivePhoto(asset: AVAsset,
                                        completion: @escaping (URL?) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
      let outURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("live_\(UUID().uuidString).mov")

      func fail(_ cleanup: Bool = true) {
        if cleanup { try? FileManager.default.removeItem(at: outURL) }
        DispatchQueue.main.async { completion(nil) }
      }

      LiveDiag.shared.log("convert start")
      do {
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
          LiveDiag.shared.log("convert fail: no video track")
          throw NSError(domain: "LivePhoto", code: -1)
        }
        LiveDiag.shared.log("convert track natural=\(videoTrack.naturalSize) transform=\(videoTrack.preferredTransform)")

        let reader = try AVAssetReader(asset: asset)
        LiveDiag.shared.log("convert reader created")
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        guard reader.canAdd(videoOutput) else {
          LiveDiag.shared.log("convert fail: reader cannot add video output")
          throw NSError(domain: "LivePhoto", code: -3)
        }
        reader.add(videoOutput)
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack = asset.tracks(withMediaType: .audio).first {
          let o = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
          if reader.canAdd(o) { reader.add(o); audioOutput = o }
        }

        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)

        // 文件级实况标识
        let contentId = AVMutableMetadataItem()
        contentId.identifier = .quickTimeMetadataContentIdentifier
        contentId.value = UUID().uuidString as NSString
        contentId.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [contentId]

        // nil 输出设置 = 原始编码流直通（不重编码、不解码）
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = videoTrack.preferredTransform   // 保留竖拍旋转
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
          let i = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
          i.expectsMediaDataInRealTime = false
          if writer.canAdd(i) { writer.add(i); audioInput = i }
        }

        // StillImageTime 元数据轨道（append 需经 MetadataAdaptor）
        // ⚠️ 崩溃黑匣子实锤（2026-11-06）：outputSettings 为 nil 时 writer 不知道
        // metadata 轨道的源格式，AVAssetWriterInputMetadataAdaptor 初始化直接抛
        // "Cannot create a new metadata adaptor with an asset writer that does
        //  not carry a source format hint"（NSInvalidArgumentException 闪退）。
        // 必须构造 mdta 格式描述作为 sourceFormatHint。
        var metaDesc: CMFormatDescription?
        // kCMMetadataInfoKey_DataType / kCMMetadataFormatType_QuickTimeMetadata
        // 未导出到 Swift，用字面量："dataType" 与四字符码 'mdta'
        // ⚠️ 实测（用户设备日志）：这里传 'mdta' 会返回 -12710（参数无效），
        // 必须是 kCMMetadataFormatType_Boxed = 'mebx'。
        let mdtaType: FourCharCode = {
          let s = Array("mebx".utf8)
          return (UInt32(s[0]) << 24) | (UInt32(s[1]) << 16) | (UInt32(s[2]) << 8) | UInt32(s[3])
        }()
        // ⚠️ 规格必须是「键名 + 数据类型」，不是元数据类型本身。
        // 之前写成 ["dataType": "mdta"] 是错的：mdta 是 metadataType（四个字符码），
        // 不是 dataType（应为 UTI 形式）。这会让 writer 建出一条无法被 Photos
        // 识别的"空标签"元数据轨 → 实况配对失败 → 退回"分开保存"。
        // 该标识符在 Swift SDK 未导出常量（旧文件里的 .quickTimeMetadataStillImageTime
        // 从未被编译过），必须用字面量；键名是连字符 still-image-time
        let stillId = "mdta/com.apple.quicktime.still-image-time"
        let mdtaSpec: [String: Any] = [
          "identifier": stillId,
          "dataType": kCMMetadataBaseDataType_SInt8 as String,
        ]
        let specStatus = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
          allocator: kCFAllocatorDefault,
          metadataType: mdtaType,
          metadataSpecifications: [mdtaSpec] as CFArray,
          formatDescriptionOut: &metaDesc)
        if specStatus != noErr || metaDesc == nil {
          LiveDiag.shared.log("meta spec(identifier) failed status=\(specStatus), retry dataType-only")
          let simple: [String: Any] = ["dataType": kCMMetadataBaseDataType_SInt8 as String]
          let st2 = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault, metadataType: mdtaType,
            metadataSpecifications: [simple] as CFArray,
            formatDescriptionOut: &metaDesc)
          LiveDiag.shared.log("meta spec retry status=\(st2)")
        }
        guard let hint = metaDesc else {
          LiveDiag.shared.log("convert fail: no mdta format description")
          throw NSError(domain: "LivePhoto", code: -4)
        }
        LiveDiag.shared.log("meta spec ok")
        let metaInput = AVAssetWriterInput(
          mediaType: .metadata, outputSettings: nil, sourceFormatHint: hint)
        writer.add(metaInput)
        let metaAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metaInput)

        let stillTime = AVMutableMetadataItem()
        // 该标识符在部分 SDK 版本无 Swift 常量名，使用原始 mdta 键名
        stillTime.key = "com.apple.quicktime.still-image-time" as NSString
        stillTime.keySpace = AVMetadataKeySpace.quickTimeMetadata
        stillTime.dataType = kCMMetadataBaseDataType_SInt8 as String
        stillTime.value = NSNumber(value: Int8(0))
        let timedGroup = AVTimedMetadataGroup(
          items: [stillTime],
          timeRange: CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: 0.1, preferredTimescale: 600)))

        let started = writer.startWriting()
        let reading = reader.startReading()
        LiveDiag.shared.log("convert startWriting=\(started) startReading=\(reading) writerStatus=\(writer.status.rawValue) err=\(writer.error?.localizedDescription ?? "-")")
        guard started, reading else {
          throw NSError(domain: "LivePhoto", code: -2)
        }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "livephoto.convert")
        let state = ConversionState()

        // 时序说明（2026-11-06 回归修正）：
        // 初版能正常合成，其做法是【视频写完之后】追加 StillImageTime，
        // 且只在 isReadyForMoreMediaData 时才 append。改成"开写后立即追加"
        // 反而让 writer 拒绝该元数据 → Photos 判定非法实况 → 退回分开保存。
        // 这里恢复已验证时序，仅保留 sourceFormatHint（避免 adaptor 初始化闪退）。

        // 收尾：等 视频+音频 全部 markAsFinished 后写元数据轨道，最后 finishWriting
        func maybeFinish() {
          guard !state.finishing else { return }
          guard state.videoDone else { return }
          if audioInput != nil && !state.audioDone { return }
          state.finishing = true
          if !state.metaDone {
            state.metaDone = true
            if metaInput.isReadyForMoreMediaData {
              let appended = metaAdaptor.append(timedGroup)   // 视频写完后补元数据（初版时序）
              LiveDiag.shared.log("meta append=\(appended)")
            } else {
              LiveDiag.shared.log("meta not ready, skipped")
            }
            metaInput.markAsFinished()
          }
          writer.finishWriting {
            DispatchQueue.main.async {
              if writer.status == .completed {
                LiveDiag.shared.log("convert done ok -> \(outURL.lastPathComponent)")
                completion(outURL)
              } else {
                LiveDiag.shared.log("convert failed status=\(writer.status.rawValue) err=\(writer.error?.localizedDescription ?? "-")")
                try? FileManager.default.removeItem(at: outURL)
                completion(nil)
              }
            }
          }
        }

        // 通用搬运：input ready 时从 output 取样本直通写入
        func drain(_ input: AVAssetWriterInput,
                   _ output: AVAssetReaderTrackOutput,
                   onDone: @escaping () -> Void) {
          input.requestMediaDataWhenReady(on: queue) {
            while input.isReadyForMoreMediaData {
              if let s = output.copyNextSampleBuffer() {
                if !input.append(s) {
                  // append 失败（编码异常）：中止读取并安全收尾
                  reader.cancelReading()
                  onDone()
                  return
                }
              } else {
                onDone()
                return
              }
            }
          }
        }

        // 看门狗：音频轨异常时 requestMediaDataWhenReady 可能永不回调 →
        // 强制收尾，避免保存流程卡死（用户会以为闪退）
        DispatchQueue.global().asyncAfter(deadline: .now() + 12) {
          if !state.finishing {
            state.videoDone = true
            state.audioDone = true
            videoInput.markAsFinished()
            audioInput?.markAsFinished()
            maybeFinish()
          }
        }

        drain(videoInput, videoOutput) {
          guard !state.videoDone else { return }
          state.videoDone = true
          videoInput.markAsFinished()
          maybeFinish()
        }
        if let ao = audioOutput, let ai = audioInput {
          drain(ai, ao) {
            guard !state.audioDone else { return }
            state.audioDone = true
            ai.markAsFinished()
            maybeFinish()
          }
        }
      } catch {
        LiveDiag.shared.log("convert threw: \(error.localizedDescription)")
        fail()
      }
    }
  }

  // MARK: - 微博水印移除（图像修复）

  /// 检测并移除微博"图片水印"（@昵称+logo，半透明白色，上传时烧进像素）。
  /// 2026-11-06 起扫描【全图】（实测水印位置不固定：中部/九宫格任意处）。
  /// 2026-11-11 v9 主路径：逐像素 9px 局部中值检测水印笔画 → PatchMatch
  /// 真实纹理填充（medianHeal），残影弱阈值复扫。失败时退回旧填充链：
  ///   strokeHeal（背景检出+射线+PatchMatch）→ patchInpaint → inpaintRegion
  /// （v7 反混合在真图上有块状伪影且除不净，已废弃。）
  /// 像素行带法兜底不变（Vision 未命中时）。
  /// 任一步不确定（无水印/白色内容过多/GIF 动图/解码失败）都原样返回，不做破坏。
  /// 返回处理后的新临时文件路径（未处理则原路径）。
  private func cleanWeiboWatermark(path: String) -> String {
    let url = URL(fileURLWithPath: path)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return path }
    if CGImageSourceGetCount(src) > 1 { return path } // GIF 动图不动
    guard let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return path }
    let w = cg.width, h = cg.height
    if w < 80 || h < 80 { return path }
    // 超大图不做像素级修补：内存与耗时不可控，直接保存原图（宁可不修也不闪退）
    if w * h > 30_000_000 { return path }

    let bpr = w * 4
    var buf = [UInt8](repeating: 0, count: bpr * h)
    let decoded = buf.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) -> Bool in
      guard let base = ptr.baseAddress else { return false }
      guard let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: bpr, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
      ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    guard decoded else { return path }
    // JPEG 无 alpha 通道：预乘缓冲里 alpha<255 的区域在编码时会被压成白色/发灰。
    // 解码后统一把 alpha 置满，保证输出与原始视觉一致。
    var ai = 3
    while ai < buf.count { buf[ai] = 255; ai += 4 }

    // CoreGraphics 缓冲区原点在左下角。
    // 2026-11-06：水印位置不再固定底部（实测有博主水印压在图片中部），
    // 扫描区扩为全图；防误伤策略见下方 v2 注释（行带限定修补）。
    let scanH = h
    let scanPx = w * scanH

    // 三遍递进阈值（主体 → 残影 → 淡残影），后两遍在已修补的图上重新检测。
    // 2026-11-06 v2 重构（行带限定修补）：
    //   全图扫描 + 【只修补落在同一水平带内的组件像素】。
    //   真水印 = 一行字符，组件中心 y 高度聚集；天空/白墙碎片散布全图不聚带。
    //   修补范围被钳制在细窄行带内 → 浅色图不可能再被整块误修成空白，
    //   因此闸门大幅放宽（聚集度 0.45、组件数上限 300、带内面积 ≤12%）。
    //   minSize 降低到 scanPx/20000（细笔画小字水印不再被过滤掉）。
    let passes: [(mn: Int, sat: Int, minSize: Int)] = [
      (135, 70, max(80, scanPx / 20000)),
      (118, 64, max(60, scanPx / 30000)),
      (108, 60, max(50, scanPx / 40000)),
    ]
    let bandHalf = Double(scanH) * 0.04
    var didAny = false
    var didAnyVision = false
    // ① 结构化路线（2026-11-06 新增，主路径）：
    //   微博作者水印形态固定 = 「微博 logo + @昵称」，位置只在中部水平带或右下角。
    //   用 Vision 文字识别直接定位这一行，只修补框内笔画像素 —— 不靠盲猜阈值，
    //   也不会误伤照片自带的正文/界面文字（那些不含 @昵称 形态或不在水印区）。
    var wmBoxes: [CGRect] = []
    autoreleasepool {
      wmBoxes = detectWatermarkTextBoxes(cg, w: w, h: h)
    }
    if !wmBoxes.isEmpty {
      // 框面积过大（>40% 画面）= 多半不是水印而是误检，直接放弃修补
      var boxArea = 0.0
      for r in wmBoxes { boxArea += Double(r.width * r.height) }
      if boxArea > Double(w * h) * 0.4 { return path }
      // 主路径 v9（2026-11-11）：逐像素局部中值检测 + PatchMatch 真实纹理填充。
      // v7 反混合在真图上有块状伪影且除不净，已废弃。
      if medianHeal(&buf, w: w, h: h, boxes: wmBoxes) {
        didAnyVision = true
      } else if strokeHeal(&buf, w: w, h: h, boxes: wmBoxes) {
        didAnyVision = true
      } else {
        var mask = [Bool](repeating: false, count: w * h)
        for r in wmBoxes {
          let x0 = max(0, Int(r.minX)), x1 = min(w - 1, Int(r.maxX))
          let y0 = max(0, Int(r.minY)), y1 = min(h - 1, Int(r.maxY))
          if x1 <= x0 || y1 <= y0 { continue }
          for y in y0...y1 { for x in x0...x1 { mask[y * w + x] = true } }
        }
        if patchInpaint(&buf, w: w, h: h, mask: mask) {
          didAnyVision = true
        } else {
          dilate(&mask, w: w, h: h, radius: 3)
          inpaintRegion(&buf, mask: mask, w: w, regionH: h)
          didAnyVision = true
        }
      }
    }

    // ② 兜底：像素行带法（Vision 未命中时，处理风格化/极端构图的水印）
    if !didAnyVision {
      for p in passes {
      var pm = detectWatermarkMask(buf, w: w, regionH: scanH,
                                   mnThreshold: p.mn, satThreshold: p.sat)
      let (comps, label, centerY) =
          keepLargeComponents(&pm, w: w, h: scanH, minSize: p.minSize)
      var cnt = 0
      for v in pm where v { cnt += 1 }
      if cnt < 25 || comps.count > 300 { continue }

      // 找组件中心最聚集的水平带
      let centers = comps.map { Double($0.minY + $0.maxY) / 2.0 }
      var bestRatio = 0.0
      var bandAt = 0.0
      for c in centers {
        var inBand = 0
        for cj in centers where abs(cj - c) <= bandHalf { inBand += 1 }
        let r = Double(inBand) / Double(centers.count)
        if r > bestRatio { bestRatio = r; bandAt = c }
      }
      // 行聚集闸门：至少 45% 组件在同一带内
      if bestRatio < 0.45 { continue }

      // 只保留带内组件的像素 → 修补严格限定在水印行
      var bandIds = Set<Int>()
      for (cid, cy) in centerY where abs(cy - bandAt) <= bandHalf {
        bandIds.insert(cid)
      }
      if bandIds.count < 2 { continue }
      var pmBand = [Bool](repeating: false, count: w * scanH)
      var bandPixels = 0
      for i in 0..<(w * scanH) where pm[i] && bandIds.contains(label[i]) {
        pmBand[i] = true
        bandPixels += 1
      }
      // 带内面积保护：超过 12% 图像面积视为误检（整条地平线等）
      if Double(bandPixels) > Double(scanPx) * 0.12 { continue }

      dilate(&pmBand, w: w, h: scanH, radius: 3)
      if !patchInpaint(&buf, w: w, h: scanH, mask: pmBand) {
        inpaintRegion(&buf, mask: pmBand, w: w, regionH: scanH)
      }
      didAny = true
      }
    }
    if didAnyVision { didAny = true }
    if !didAny { return path }

    // 安全校验：修补结果若整体接近纯白（填充异常），直接放弃修补，保存原图
    var sumL = 0, samples = 0
    var si = 0
    while si + 3 < buf.count {
      sumL += Int(buf[si]) + Int(buf[si + 1]) + Int(buf[si + 2])
      samples += 3
      si += 4 * 37          // 稀疏采样，成本可忽略
    }
    if samples > 0 && sumL / samples > 235 { return path }

    // 写回 JPEG
    guard let outCtx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                 bytesPerRow: bpr, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let img = outCtx.makeImage() else { return path }
    let outURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("wm_\(UUID().uuidString).jpg")
    guard let dest = CGImageDestinationCreateWithURL(
      outURL as CFURL, "public.jpeg" as CFString, 1, nil) else { return path }
    CGImageDestinationAddImage(dest, img, preservedMetadata(from: src))
    guard CGImageDestinationFinalize(dest) else { return path }
    return outURL.path
  }

  /// 用 Vision 定位微博水印文字行（「微博 logo + @昵称」）。
  /// 判据：文本含 @ / 微博 / weibo；位于中部水平带(纵 30%~70%)或底部 30%；
  /// 文字行高度 ≤6% 图高。返回像素矩形，坐标系 = 位图缓冲区（内存第 0 行 = 图像顶部），
  /// 因此 Vision 的归一化坐标（原点左下）需要 y 翻转。
  private func detectWatermarkTextBoxes(_ cg: CGImage, w: Int, h: Int) -> [CGRect] {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.recognitionLanguages = ["zh-Hans", "en-US"]
    req.usesLanguageCorrection = false
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    guard (try? handler.perform([req])) != nil, let obs = req.results else { return [] }
    var boxes: [CGRect] = []
    for o in obs {
      guard let s = o.topCandidates(1).first?.string, !s.isEmpty else { continue }
      let lower = s.lowercased()
      // 2026-11-09：本函数现在只对微博调用（小红书/抖音走直取无水印、零处理）。
      // 水印标记只保留微博专属的「@昵称 + 微博/weibo」，移除 小红书/xhs/redbook
      // —— 否则微博配图里作者自己写的"小红书"等文字会被误判为水印而糊掉。
      let hasMarker = s.contains("@") || s.contains("微博") || lower.contains("weibo")
      guard hasMarker else { continue }
      let bb = o.boundingBox
      let inCenter = bb.minY > 0.30 && bb.maxY < 0.70
      let inBottom = bb.maxY < 0.32
      guard inCenter || inBottom, bb.height <= 0.06, bb.width <= 0.7 else { continue }
      let bh = bb.height * CGFloat(h)
      let padX = max(6.0, bh * 0.4)
      // 微博 logo 在文字左侧，宽度约等于行高 → 向左扩 1.3 倍行高覆盖图标
      let x0 = bb.minX * CGFloat(w) - bh * 1.3 - padX
      let x1 = bb.maxX * CGFloat(w) + padX
      let yTop = (1 - bb.maxY) * CGFloat(h) - padX
      let yBot = (1 - bb.minY) * CGFloat(h) + padX
      let rx0 = max(0, x0), ry0 = max(0, yTop)
      let rect = CGRect(x: rx0, y: ry0,
                        width: min(CGFloat(w - 1), x1) - rx0,
                        height: min(CGFloat(h - 1), yBot) - ry0)
      if rect.width > 6 && rect.height > 6 { boxes.append(rect) }
    }
    return boxes
  }

  /// 微博水印清除 v9（2026-11-11，主路径）：逐像素局部中值检测 + PatchMatch 真实纹理填充。
  ///
  /// v7 反混合在真图上失败（真机"水印去不掉"）：24px 块中值背景在纹理区
  /// 误差大 → 块状伪影；白裙等大面积亮背景被误当水印；α 估计不稳。
  /// v9 改用【逐像素 9px 窗口中值】做局部背景：笔画宽 2-4px，窗口内中值
  /// 恒为背景 → 纹理区也稳；大面积亮背景（白裙）局部中值同样亮，天然排除。
  ///
  /// 流程（ROI 局部内存，同 v6 内存约束）：
  ///   ① 9px 逐像素中值背景 → 候选 = lum > bg+12 且低饱和(≤80)
  ///   ② 连通域过滤：只留"笔画状"组件（6px ≤ 面积 ≤ 行高²*1.5，高 ≤ 行高*1.5）
  ///   ③ 膨胀 2px 覆盖抗锯齿边缘
  ///   ④ PatchMatch 相干复制填真实纹理（coherentPatchFillROI）；
  ///      掩码过大时退回 ROI 内洋葱扩散
  ///   ⑤ 残影复扫一遍（bg+8 弱阈值）
  /// 真图验证（2000x1333 微博演出照，水印"@昵称+logo"压在红白演出服上）：
  ///   文字/logo 主体去除干净、无块伪影；Python 扩散填充已可用，Swift
  ///   PatchMatch 拷真实纹理效果更好。失败时退回 strokeHeal 旧链。
  private func medianHeal(_ buf: inout [UInt8], w: Int, h: Int,
                          boxes: [CGRect]) -> Bool {
    if boxes.isEmpty { return false }
    var rx0 = w, rx1 = 0, ry0 = h, ry1 = 0
    for r in boxes {
      rx0 = min(rx0, max(0, Int(r.minX)))
      rx1 = max(rx1, min(w - 1, Int(r.maxX)))
      ry0 = min(ry0, max(0, Int(r.minY)))
      ry1 = max(ry1, min(h - 1, Int(r.maxY)))
    }
    if rx1 <= rx0 || ry1 <= ry0 { return false }
    let lineH = ry1 - ry0 + 1
    // ROI 垂直内边距收紧（半行高）：减少文字上方高光纹理的误检
    let padY = max(6, lineH / 2)
    let ex0 = max(0, rx0 - 8), ex1 = min(w - 1, rx1 + 8)
    let ey0 = max(0, ry0 - padY), ey1 = min(h - 1, ry1 + padY)
    let lw = ex1 - ex0 + 1, lh = ey1 - ey0 + 1
    if lw < 8 || lh < 6 { return false }
    if lw * lh > 6_000_000 { return false }

    @inline(__always) func ridx(_ x: Int, _ y: Int) -> Int { (y - ey0) * lw + (x - ex0) }
    @inline(__always) func gidx(_ x: Int, _ y: Int) -> Int { y * w + x }

    var lum = [UInt8](repeating: 0, count: lw * lh)
    func refreshLum() {
      for y in ey0...ey1 {
        let row = y * w
        let base = (y - ey0) * lw
        for x in ex0...ex1 {
          let o = (row + x) * 4
          lum[base + x - ex0] = UInt8((Int(buf[o]) * 77 + Int(buf[o + 1]) * 150 + Int(buf[o + 2]) * 29) >> 8)
        }
      }
    }
    refreshLum()

    // ---- 背景下包络：灰度开运算（erode→dilate）----
    // 2026-11-11 v10（取代 9px 中值背景）：
    //   旧版判据是「比局部中值亮 margin」，在白发/白裙/白墙这类高亮背景下
    //   白字与背景亮度几乎一样 → 笔画判不出来 → 残留白色字块（用户反馈的
    //   "涂抹悬浮的白色文字"）。改用顶帽（top-hat）：
    //   开运算会抹掉所有「比结构元细」的亮结构，剩下的是背景下包络；
    //   lum - opening = 细亮结构（笔画）的强度，与大块高光无关。
    //   再除以 (255 - 背景) 得到该像素的"白字覆盖率 alpha"，
    //   只处理 alpha 足够大（肉眼可见）的部分 —— 白字压白底本来就看不见，
    //   留着也察觉不到，避免为了不可见的残影去大改画面。
    func morph(_ src: [UInt8], _ r: Int, _ isMin: Bool) -> [UInt8] {
      var tmp = [UInt8](repeating: 0, count: lw * lh)
      var out = [UInt8](repeating: 0, count: lw * lh)
      for y in 0..<lh {
        let row = y * lw
        for x in 0..<lw {
          var v = src[row + x]
          let x0 = max(0, x - r), x1 = min(lw - 1, x + r)
          for xx in x0...x1 {
            let s = src[row + xx]
            if isMin { if s < v { v = s } } else { if s > v { v = s } }
          }
          tmp[row + x] = v
        }
      }
      for x in 0..<lw {
        for y in 0..<lh {
          var v = tmp[y * lw + x]
          let y0 = max(0, y - r), y1 = min(lh - 1, y + r)
          for yy in y0...y1 {
            let s = tmp[yy * lw + x]
            if isMin { if s < v { v = s } } else { if s > v { v = s } }
          }
          out[y * lw + x] = v
        }
      }
      return out
    }

    // 结构元半径 ≈ 笔画宽度的一半（笔画约 2~4 个 lineH/10）
    let kr = max(4, min(11, lineH / 6))
    var healedAny = false

    // 两遍：主阈值 → 残影弱阈值
    for pass in 0..<2 {
      // 开运算：腐蚀(取min) 再膨胀(取max) → 抹掉细亮结构
      let ero = morph(lum, kr, true)
      let opening = morph(ero, kr, false)
      let tTop = pass == 0 ? 16 : 10        // 顶帽强度下限
      let tAlpha = pass == 0 ? 0.15 : 0.09  // 白字覆盖率下限

      var cand = [Bool](repeating: false, count: lw * lh)
      for y in ey0...ey1 {
        for x in ex0...ex1 {
          let r = ridx(x, y)
          let o = gidx(x, y) * 4
          let rr = Int(buf[o]), gg = Int(buf[o + 1]), bb = Int(buf[o + 2])
          let mx = max(rr, max(gg, bb)), mn = min(rr, min(gg, bb))
          if (mx - mn) > 80 { continue }   // 彩色高光不是白字
          let top = Int(lum[r]) - Int(opening[r])
          if top < tTop { continue }
          let alpha = Double(top) / Double(max(1, 255 - Int(opening[r])))
          if alpha >= tAlpha { cand[r] = true }
        }
      }
      // 4 邻接连通域 + 笔画形态过滤
      var seen = [Bool](repeating: false, count: lw * lh)
      var mask = [Bool](repeating: false, count: lw * lh)
      let maxArea = lineH * lineH * 3 / 2
      var stack = [Int]()
      for r0 in 0..<(lw * lh) {
        if !cand[r0] || seen[r0] { continue }
        stack.removeAll(keepingCapacity: true)
        stack.append(r0)
        seen[r0] = true
        var pix = [Int]()
        var minY = lh, maxY = 0
        while let r = stack.popLast() {
          pix.append(r)
          let py = r / lw
          if py < minY { minY = py }
          if py > maxY { maxY = py }
          let px = r % lw
          if px > 0 {
            let q = r - 1
            if cand[q] && !seen[q] { seen[q] = true; stack.append(q) }
          }
          if px < lw - 1 {
            let q = r + 1
            if cand[q] && !seen[q] { seen[q] = true; stack.append(q) }
          }
          if py > 0 {
            let q = r - lw
            if cand[q] && !seen[q] { seen[q] = true; stack.append(q) }
          }
          if py < lh - 1 {
            let q = r + lw
            if cand[q] && !seen[q] { seen[q] = true; stack.append(q) }
          }
        }
        let hgt = maxY - minY + 1
        if pix.count >= 10 && pix.count <= maxArea && hgt <= lineH * 3 / 2 {
          for r in pix { mask[r] = true }
        }
      }
      var cnt = 0
      for v in mask where v { cnt += 1 }
      if cnt < 12 { continue }

      // 膨胀 2px
      var dil = mask
      for y in 0..<lh {
        for x in 0..<lw where mask[y * lw + x] {
          for yy in max(0, y - 2)...min(lh - 1, y + 2) {
            for xx in max(0, x - 2)...min(lw - 1, x + 2) {
              dil[yy * lw + xx] = true
            }
          }
        }
      }

      // PatchMatch 填真实纹理；掩码过大（内部 >120k 直接跳过）时退回洋葱扩散
      var dcnt = 0
      for v in dil where v { dcnt += 1 }
      if dcnt <= 110_000 {
        coherentPatchFillROI(&buf, w: w, h: h, ex0: ex0, ex1: ex1, ey0: ey0, ey1: ey1,
                             mask: dil, rounds: 4, half: 3, search: 96)
      } else {
        // 洋葱扩散（ROI 局部）：逐圈用非掩码邻域均值填充
        var remaining = dil
        for _ in 0..<60 {
          var next = [Bool](repeating: false, count: lw * lh)
          var left = 0
          for y in 0..<lh {
            for x in 0..<lw where remaining[y * lw + x] {
              var ar = 0, ag = 0, ab = 0, n = 0
              for dy in -1...1 {
                for dx in -1...1 {
                  if dy == 0 && dx == 0 { continue }
                  let yy = y + dy, xx = x + dx
                  if yy < 0 || yy >= lh || xx < 0 || xx >= lw { continue }
                  if remaining[yy * lw + xx] { continue }
                  let o = gidx(xx + ex0, yy + ey0) * 4
                  ar += Int(buf[o]); ag += Int(buf[o + 1]); ab += Int(buf[o + 2]); n += 1
                }
              }
              if n > 0 {
                let o = gidx(x + ex0, y + ey0) * 4
                buf[o] = UInt8(clamping: ar / n)
                buf[o + 1] = UInt8(clamping: ag / n)
                buf[o + 2] = UInt8(clamping: ab / n)
              } else {
                next[y * lw + x] = true
                left += 1
              }
            }
          }
          if left == 0 { break }
          remaining = next
        }
      }
      healedAny = true
      refreshLum()
    }
    return healedAny
  }


  /// 水印清除主算法（2026-11-06 v6：ROI 局部内存 + 相干复制）。
  ///
  /// ⚠️ 内存约束（崩溃修复）：不要再按整幅图分配数组。
  ///   一张 4000x5000 的照片，整图 Bool/Float 数组每个就是 20-80MB，
  ///   叠加 snap/base 副本会瞬间超过 jetsam 限制，被系统直接 kill（无异常日志的"闪退"）。
  ///   这里所有中间数组都只按 ROI（Vision 框）尺寸分配。
  ///
  /// 流程：
  ///   ① 局部背景（ROI 内分块中值）→ 检出"比周围亮且低饱和"的笔画像素
  ///   ② 24 方向射线插值初始化（结构正确、不错位）
  ///   ③ 迭代 3 轮：重检残影（logo 这类实心图形一次填不净）
  ///   ④ 相干复制（PatchMatch）：拷贝真实像素保住颗粒细节
  private func strokeHeal(_ buf: inout [UInt8], w: Int, h: Int,
                          boxes: [CGRect]) -> Bool {
    if boxes.isEmpty { return false }
    let t0 = Date()
    var rx0 = w, rx1 = 0, ry0 = h, ry1 = 0
    for r in boxes {
      rx0 = min(rx0, max(0, Int(r.minX)))
      rx1 = max(rx1, min(w - 1, Int(r.maxX)))
      ry0 = min(ry0, max(0, Int(r.minY)))
      ry1 = max(ry1, min(h - 1, Int(r.maxY)))
    }
    if rx1 <= rx0 || ry1 <= ry0 { return false }

    let padY = max(8, (ry1 - ry0))
    let ex0 = max(0, rx0 - 8), ex1 = min(w - 1, rx1 + 8)
    let ey0 = max(0, ry0 - padY), ey1 = min(h - 1, ry1 + padY)
    let lw = ex1 - ex0 + 1, lh = ey1 - ey0 + 1
    if lw < 8 || lh < 6 { return false }
    // 面积预算：ROI 过大时只处理上/下半（水印行本身很窄，正常不会触发）
    if lw * lh > 6_000_000 { return false }

    @inline(__always) func ridx(_ x: Int, _ y: Int) -> Int { (y - ey0) * lw + (x - ex0) }
    @inline(__always) func gidx(_ x: Int, _ y: Int) -> Int { y * w + x }

    // ROI 亮度
    var lum = [UInt8](repeating: 0, count: lw * lh)
    for y in ey0...ey1 {
      let row = y * w
      let base = (y - ey0) * lw
      for x in ex0...ex1 {
        let o = (row + x) * 4
        lum[base + x - ex0] = UInt8((Int(buf[o]) * 77 + Int(buf[o + 1]) * 150 + Int(buf[o + 2]) * 29) >> 8)
      }
    }

    // ① ROI 内分块中值背景
    let bs = 24
    let gw = (lw + bs - 1) / bs, gh = (lh + bs - 1) / bs
    var grid = [UInt8](repeating: 0, count: gw * gh)
    var samples = [UInt8]()
    samples.reserveCapacity(bs * bs)
    for gy in 0..<gh {
      for gx in 0..<gw {
        samples.removeAll(keepingCapacity: true)
        let x0 = gx * bs, x1 = min(lw, x0 + bs)
        let y0 = gy * bs, y1 = min(lh, y0 + bs)
        for y in y0..<y1 {
          let row = y * lw
          for x in x0..<x1 { samples.append(lum[row + x]) }
        }
        if samples.isEmpty { continue }
        samples.sort()
        grid[gy * gw + gx] = samples[samples.count / 2]
      }
    }
    func bgAt(_ x: Int, _ y: Int) -> Int {
      let fx = min(max(0.0, Double(x - ex0) / Double(bs) - 0.5), Double(gw - 1))
      let fy = min(max(0.0, Double(y - ey0) / Double(bs) - 0.5), Double(gh - 1))
      let x0 = Int(fx), y0 = Int(fy)
      let x1 = min(gw - 1, x0 + 1), y1 = min(gh - 1, y0 + 1)
      let tx = fx - Double(x0), ty = fy - Double(y0)
      let v00 = Double(grid[y0 * gw + x0]), v10 = Double(grid[y0 * gw + x1])
      let v01 = Double(grid[y1 * gw + x0]), v11 = Double(grid[y1 * gw + x1])
      let top = v00 * (1 - tx) + v10 * tx
      let bot = v01 * (1 - tx) + v11 * tx
      return Int(top * (1 - ty) + bot * ty)
    }

    var dirs = [(Double, Double)]()
    for k in 0..<24 {
      let a = Double(k) * Double.pi / 12.0
      dirs.append((sin(a), cos(a)))
    }
    let maxStep = max(24, min(120, (ry1 - ry0) * 4))

    var healedMask = [Bool](repeating: false, count: lw * lh)   // ROI 局部
    var healedAny = false

    for pass in 0..<3 {
      var mask = [Bool](repeating: false, count: lw * lh)
      var count = 0
      for y in ey0...ey1 {
        for x in ex0...ex1 {
          let r = ridx(x, y)
          let o = gidx(x, y) * 4
          let rr = Int(buf[o]), gg = Int(buf[o + 1]), bb = Int(buf[o + 2])
          let mx = max(rr, max(gg, bb)), mn = min(rr, min(gg, bb))
          if Int(lum[r]) > bgAt(x, y) + 10 && (mx - mn) <= 70 {
            mask[r] = true
            count += 1
          }
        }
      }
      if count == 0 { break }

      let rad = pass == 0 ? 3 : 2
      var dil = mask
      for y in ey0...ey1 {
        for x in ex0...ex1 where mask[ridx(x, y)] {
          let yy0 = max(ey0, y - rad), yy1 = min(ey1, y + rad)
          let xx0 = max(ex0, x - rad), xx1 = min(ex1, x + rad)
          for yy in yy0...yy1 {
            for xx in xx0...xx1 { dil[ridx(xx, yy)] = true }
          }
        }
      }

      // ② 射线插值（读取当前 buf；本轮回填写入 buf）
      var filled = 0
      for y in ey0...ey1 {
        for x in ex0...ex1 where dil[ridx(x, y)] {
          var ar = 0.0, ag = 0.0, ab = 0.0, aw = 0.0
          for (dy, dx) in dirs {
            var st = 1
            while st <= maxStep {
              let yy = y + Int((dy * Double(st)).rounded())
              let xx = x + Int((dx * Double(st)).rounded())
              if yy < ey0 || yy > ey1 || xx < ex0 || xx > ex1 { break }
              if !dil[ridx(xx, yy)] {
                let o = gidx(xx, yy) * 4
                let wt = 1.0 / Double(st * st)
                ar += wt * Double(buf[o]); ag += wt * Double(buf[o + 1]); ab += wt * Double(buf[o + 2])
                aw += wt
                break
              }
              st += 1
            }
          }
          if aw > 1e-6 {
            let o = gidx(x, y) * 4
            buf[o] = UInt8(clamping: Int((ar / aw).rounded()))
            buf[o + 1] = UInt8(clamping: Int((ag / aw).rounded()))
            buf[o + 2] = UInt8(clamping: Int((ab / aw).rounded()))
            filled += 1
          }
        }
      }
      if filled == 0 { break }
      healedAny = true
      for r in 0..<(lw * lh) where dil[r] { healedMask[r] = true }
      // 刷新亮度
      for y in ey0...ey1 {
        for x in ex0...ex1 {
          let o = gidx(x, y) * 4
          lum[ridx(x, y)] = UInt8((Int(buf[o]) * 77 + Int(buf[o + 1]) * 150 + Int(buf[o + 2]) * 29) >> 8)
        }
      }
    }
    if !healedAny { return false }

    // ③ 相干复制（真实像素拷贝，保细节）
    //    时间预算 6s：超过则跳过（宁可略平滑，也不能让保存流程超时/看起来卡死）
    if Date().timeIntervalSince(t0) < 6.0 {
      // patch 5x5→7x7、轮次 2→3、搜索半径 40→64：结构更准、纹理更连续
      coherentPatchFillROI(&buf, w: w, h: h, ex0: ex0, ex1: ex1, ey0: ey0, ey1: ey1,
                           mask: healedMask, rounds: 3, half: 3, search: 64)
    }
    return true
  }

  /// ROI 局部的相干复制填充：PatchMatch 求 NNF → patch 整体写入（重叠 50% 混合）。
  /// 全程只用 ROI 尺寸的数组，内存恒定。
  private func coherentPatchFillROI(_ buf: inout [UInt8], w: Int, h: Int,
                                    ex0: Int, ex1: Int, ey0: Int, ey1: Int,
                                    mask: [Bool], rounds: Int, half: Int, search: Int) {
    let lw = ex1 - ex0 + 1, lh = ey1 - ey0 + 1
    @inline(__always) func ridx(_ x: Int, _ y: Int) -> Int { (y - ey0) * lw + (x - ex0) }

    // 洞内像素（ROI 局部坐标）
    var ys = [Int32](), xs = [Int32]()
    for y in ey0...ey1 {
      for x in ex0...ex1 where mask[ridx(x, y)] {
        ys.append(Int32(y)); xs.append(Int32(x))
      }
    }
    let n = ys.count
    if n == 0 || n > 120_000 { return }   // 过大直接跳过，保时延

    // 复制源快照（ROI 局部，3 通道）
    var base = [UInt8](repeating: 0, count: lw * lh * 3)
    for y in ey0...ey1 {
      for x in ex0...ex1 {
        let o = (y * w + x) * 4
        let b = ridx(x, y) * 3
        base[b] = buf[o]; base[b + 1] = buf[o + 1]; base[b + 2] = buf[o + 2]
      }
    }
    var outRGB = base

    // 候选中心（ROI 内、不在 mask 里）
    var candIdx = [Int32]()
    for y in ey0...ey1 {
      for x in ex0...ex1 where !mask[ridx(x, y)] {
        candIdx.append(Int32(ridx(x, y)))
      }
    }
    if candIdx.isEmpty { return }

    var (offX, offY, bestD) = ([Int32](repeating: 0, count: n),
                               [Int32](repeating: 0, count: n),
                               [Double](repeating: 1e18, count: n))
    var written = [Bool](repeating: false, count: lw * lh)

    for round in 0..<rounds {
      let fillConf = 0.15 + 0.25 * Double(round)

      // 距离：ROI 局部，5x5，洞内低置信
      func dist(_ i: Int, _ cy: Int, _ cx: Int) -> Double {
        let y = Int(ys[i]), x = Int(xs[i])
        if y - half < ey0 || y + half > ey1 || x - half < ex0 || x + half > ex1 { return 1e18 }
        if cy - half < ey0 || cy + half > ey1 || cx - half < ex0 || cx + half > ex1 { return 1e18 }
        var d = 0.0, wsum = 0.0
        for dy in -half...half {
          for dx in -half...half {
            let q = ridx(x + dx, y + dy)
            let s = ridx(cx + dx, cy + dy)
            let wt = mask[q] ? fillConf : 1.0
            let dr = Double(Int(base[q * 3]) - Int(base[s * 3]))
            let dg = Double(Int(base[q * 3 + 1]) - Int(base[s * 3 + 1]))
            let db = Double(Int(base[q * 3 + 2]) - Int(base[s * 3 + 2]))
            d += (dr * dr + dg * dg + db * db) * wt
            wsum += wt
          }
        }
        return wsum > 0 ? d / wsum : 1e18
      }

      // 初始化
      for i in 0..<n {
        for _ in 0..<4 {
          let c = Int(candIdx[Int.random(in: 0..<candIdx.count)])
          let cy = ey0 + c / lw, cx = ex0 + c % lw
          let d = dist(i, cy, cx)
          if d < bestD[i] { bestD[i] = d; offY[i] = Int32(cy - Int(ys[i])); offX[i] = Int32(cx - Int(xs[i])) }
        }
      }
      // 传播 + 随机
      for it in 0..<2 {
        let rad = max(2, search >> (it + 1))
        let forward = it % 2 == 0
        let seq = forward ? Array(0..<n) : Array((0..<n).reversed())
        for i in seq {
          var by = Int(ys[i]) + Int(offY[i]), bx = Int(xs[i]) + Int(offX[i])
          var bd = bestD[i]
          for j in [i - 1, i + 1] where j >= 0 && j < n {
            let cy = Int(ys[j]) + Int(offY[j]), cx = Int(xs[j]) + Int(offX[j])
            if cy < ey0 || cy > ey1 || cx < ex0 || cx > ex1 { continue }
            if mask[ridx(cx, cy)] { continue }
            let d = dist(i, cy, cx)
            if d < bd { bd = d; by = cy; bx = cx }
          }
          for _ in 0..<3 {
            let cy = by + Int.random(in: -rad...rad)
            let cx = bx + Int.random(in: -rad...rad)
            if cy < ey0 || cy > ey1 || cx < ex0 || cx > ex1 { continue }
            if mask[ridx(cx, cy)] { continue }
            let d = dist(i, cy, cx)
            if d < bd { bd = d; by = cy; bx = cx }
          }
          bestD[i] = bd
          offY[i] = Int32(by - Int(ys[i])); offX[i] = Int32(bx - Int(xs[i]))
        }
      }
      // patch 写入（按质量从优到劣；未写过直接拷贝，重叠 50%）
      let order = (0..<n).sorted { bestD[$0] < bestD[$1] }
      for i in order {
        let y = Int(ys[i]), x = Int(xs[i])
        let sy = y + Int(offY[i]), sx = x + Int(offX[i])
        for dy in -half...half {
          let qy = y + dy, ry = sy + dy
          if qy < ey0 || qy > ey1 || ry < ey0 || ry > ey1 { continue }
          for dx in -half...half {
            let qx = x + dx, rx = sx + dx
            if qx < ex0 || qx > ex1 || rx < ex0 || rx > ex1 { continue }
            let q = ridx(qx, qy)
            if !mask[q] { continue }
            let s = ridx(rx, ry)
            if written[q] {
              for c in 0..<3 {
                outRGB[q * 3 + c] = UInt8(clamping: Int((0.5 * Double(outRGB[q * 3 + c])
                                                        + 0.5 * Double(base[s * 3 + c])).rounded()))
              }
            } else {
              outRGB[q * 3] = base[s * 3]
              outRGB[q * 3 + 1] = base[s * 3 + 1]
              outRGB[q * 3 + 2] = base[s * 3 + 2]
              written[q] = true
            }
          }
        }
      }
      // 下一轮以本轮结果作为样例源
      base = outRGB
    }

    // 写回
    for y in ey0...ey1 {
      for x in ex0...ex1 where mask[ridx(x, y)] {
        let o = (y * w + x) * 4
        let b = ridx(x, y) * 3
        buf[o] = outRGB[b]; buf[o + 1] = outRGB[b + 1]; buf[o + 2] = outRGB[b + 2]
      }
    }
  }

  /// PatchMatch 样例修补（exemplar inpainting）。
  /// 对 mask 覆盖的像素，在小邻域内为每个像素搜索最相似的"干净 patch"，
  /// 再按相似度加权合成填充 —— 保留背景纹理，不留扩散填充的模糊残影。
  /// 返回 false 表示区域过大/无可用样例，调用方应回退到 inpaintRegion。
  private func patchInpaint(_ buf: inout [UInt8], w: Int, h: Int,
                            mask: [Bool]) -> Bool {
    // 1) mask 包围盒
    var minX = w, maxX = -1, minY = h, maxY = -1
    for y in 0..<h {
      let row = y * w
      for x in 0..<w where mask[row + x] {
        if x < minX { minX = x }
        if x > maxX { maxX = x }
        if y < minY { minY = y }
        if y > maxY { maxY = y }
      }
    }
    if maxX < minX || maxY < minY { return false }
    let bw = maxX - minX + 1, bh = maxY - minY + 1
    // 面积/规模上限：过大区域样例修补不可靠且耗时
    if Double(bw * bh) > Double(w * h) * 0.15 { return false }
    if bw > 4096 || bh > 2048 { return false }

    // 只读快照：嵌套函数不能捕获 inout 参数，且投票必须基于原始像素
    let src = buf
    let half = 2                 // patch 5x5
    let pad = half * 2
    let sx0 = max(half, minX - pad), sx1 = min(w - 1 - half, maxX + pad)
    let sy0 = max(half, minY - pad), sy1 = min(h - 1 - half, maxY + pad)
    let rw = sx1 - sx0 + 1, rh = sy1 - sy0 + 1
    if rw <= half * 2 || rh <= half * 2 { return false }

    // 目标像素列表（区域内被 mask 的像素）
    var targets: [Int] = []
    for y in sy0...sy1 {
      let row = y * w
      for x in sx0...sx1 where mask[row + x] { targets.append(row + x) }
    }
    if targets.isEmpty || targets.count > 160_000 { return false }
    // 像素 → targets 下标（传播时 O(1) 查邻居）
    var targetIndex = [Int32](repeating: -1, count: w * h)
    for (i, p) in targets.enumerated() { targetIndex[p] = Int32(i) }

    // 2) 搜索窗口：围绕包围盒外扩（水印是横条，上下有干净背景可取样）
    let search = max(16, min(max(bh * 4, 24), 160))
    let ex0 = max(half, sx0 - search), ex1 = min(w - 1 - half, sx1 + search)
    let ey0 = max(half, sy0 - search), ey1 = min(h - 1 - half, sy1 + search)
    if ex1 <= ex0 || ey1 <= ey0 { return false }

    // 3) 有效样例位置（patch 完全不在 mask 内）
    var validPatch = [Bool](repeating: false, count: w * h) // 仅按需查表
    var anyValid = false
    for y in ey0...ey1 {
      for x in ex0...ex1 {
        var ok = true
        vloop: for dy in -half...half {
          for dx in -half...half {
            if mask[(y + dy) * w + (x + dx)] { ok = false; break vloop }
          }
        }
        if ok { validPatch[y * w + x] = true; anyValid = true }
      }
    }
    if !anyValid { return false }

    func patchDist(_ tx: Int, _ ty: Int, _ sx: Int, _ sy: Int) -> Int {
      var d = 0
      for dy in -half...half {
        let ti = (ty + dy) * w
        let si = (sy + dy) * w
        for dx in -half...half {
          let i = (ti + tx + dx) * 4
          let j = (si + sx + dx) * 4
          let dr = Int(src[i]) - Int(src[j])
          let dg = Int(src[i + 1]) - Int(src[j + 1])
          let db = Int(src[i + 2]) - Int(src[j + 2])
          d += dr * dr + dg * dg + db * db
          if d > 400_000 { return d }
        }
      }
      return d
    }

    // 4) NNF 初始化（随机）
    let n = targets.count
    var offX = [Int32](repeating: 0, count: n)
    var offY = [Int32](repeating: 0, count: n)
    var bestD = [Int](repeating: Int.max, count: n)
    var rng = SystemRandomNumberGenerator()
    for i in 0..<n {
      let p = targets[i]
      let ty = p / w, tx = p % w
      for _ in 0..<8 {
        let sx = Int.random(in: ex0...ex1, using: &rng)
        let sy = Int.random(in: ey0...ey1, using: &rng)
        if !validPatch[sy * w + sx] { continue }
        let d = patchDist(tx, ty, sx, sy)
        if d < bestD[i] {
          bestD[i] = d
          offX[i] = Int32(sx - tx)
          offY[i] = Int32(sy - ty)
        }
      }
      if bestD[i] == Int.max { offX[i] = 0; offY[i] = 0 }
    }

    // 5) 传播 + 随机搜索 3 轮（半径递减）
    for iter in 0..<3 {
      let rad = max(4, search >> (iter + 1))
      for i in 0..<n {
        let p = targets[i]
        let ty = p / w, tx = p % w
        var bx = tx + Int(offX[i]), by = ty + Int(offY[i])
        var bd = bestD[i]
        // 传播：左/上邻居的偏移
        for (nx, ny) in [(tx - 1, ty), (tx, ty - 1)] {
          if nx < sx0 || ny < sy0 { continue }
          let j = Int(targetIndex[ny * w + nx])
          if j < 0 { continue }
          let cx = nx + Int(offX[j]), cy = ny + Int(offY[j])
          if cx < ex0 || cx > ex1 || cy < ey0 || cy > ey1 { continue }
          if !validPatch[cy * w + cx] { continue }
          let d = patchDist(tx, ty, cx, cy)
          if d < bd { bd = d; bx = cx; by = cy }
        }
        // 随机搜索
        for _ in 0..<4 {
          let rx = bx + Int.random(in: -rad...rad, using: &rng)
          let ry = by + Int.random(in: -rad...rad, using: &rng)
          if rx < ex0 || rx > ex1 || ry < ey0 || ry > ey1 { continue }
          if !validPatch[ry * w + rx] { continue }
          let d = patchDist(tx, ty, rx, ry)
          if d < bd { bd = d; bx = rx; by = ry }
        }
        bestD[i] = bd
        offX[i] = Int32(bx - tx)
        offY[i] = Int32(by - ty)
      }
    }

    // 6) 按相似度加权投票合成
    var accR = [Float](repeating: 0, count: rw * rh)
    var accG = [Float](repeating: 0, count: rw * rh)
    var accB = [Float](repeating: 0, count: rw * rh)
    var accW = [Float](repeating: 0, count: rw * rh)
    for i in 0..<n {
      let p = targets[i]
      let ty = p / w, tx = p % w
      let sx = tx + Int(offX[i]), sy = ty + Int(offY[i])
      let wgt = 1.0 / (1.0 + Double(min(bestD[i], 1_000_000)) / 30_000.0)
      for dy in -half...half {
        let qy = ty + dy
        if qy < sy0 || qy > sy1 { continue }
        for dx in -half...half {
          let qx = tx + dx
          if qx < sx0 || qx > sx1 { continue }
          let q = qy * w + qx
          if !mask[q] { continue }
          let li = (qy - sy0) * rw + (qx - sx0)
          let si = ((sy + dy) * w + (sx + dx)) * 4
          accR[li] += Float(wgt) * Float(src[si])
          accG[li] += Float(wgt) * Float(src[si + 1])
          accB[li] += Float(wgt) * Float(src[si + 2])
          accW[li] += Float(wgt)
        }
      }
    }

    // 7) 写回（无票的像素用包围盒内最近有效像素色兜底）
    var fallback = (r: UInt8(128), g: UInt8(128), b: UInt8(128))
    if let firstValid = validPatch.indices.first(where: { validPatch[$0] }) {
      let i = firstValid * 4
      fallback = (src[i], src[i + 1], src[i + 2])
    }
    var filled = 0, hollow = 0
    for y in sy0...sy1 {
      for x in sx0...sx1 where mask[y * w + x] {
        let li = (y - sy0) * rw + (x - sx0)
        let i = (y * w + x) * 4
        if accW[li] > 0.0001 {
          buf[i] = UInt8(clamping: Int(accR[li] / accW[li]))
          buf[i + 1] = UInt8(clamping: Int(accG[li] / accW[li]))
          buf[i + 2] = UInt8(clamping: Int(accB[li] / accW[li]))
          filled += 1
        } else {
          buf[i] = fallback.r; buf[i + 1] = fallback.g; buf[i + 2] = fallback.b
          hollow += 1
        }
      }
    }
    // 兜底色占比过高 = 样例搜索失败（会留下灰块）→ 让调用方回退扩散修补
    if hollow > 0 && Double(hollow) > Double(filled + hollow) * 0.05 {
      buf = src
      return false
    }
    return true
  }

  /// 检测"亮且低饱和"的候选水印像素（扫描高度由调用方决定，现为全图）
  private func detectWatermarkMask(_ buf: [UInt8], w: Int, regionH: Int,
                                   mnThreshold: Int, satThreshold: Int) -> [Bool] {
    var mask = [Bool](repeating: false, count: w * regionH)
    let bpr = w * 4
    for y in 0..<regionH {
      let row = y * bpr
      for x in 0..<w {
        let i = row + x * 4
        let r = Int(buf[i]), g = Int(buf[i + 1]), b = Int(buf[i + 2])
        let mn = min(r, min(g, b)), mx = max(r, max(g, b))
        if mn >= mnThreshold && (mx - mn) <= satThreshold {
          mask[y * w + x] = true
        }
      }
    }
    return mask
  }

  /// 连通域过滤：保留像素数 ≥ minSize 且【组件高度 ≤ 12% 图高】的组件。
  /// 返回保留组件的 bbox 列表 + 每像素组件标签（供行带过滤）+ 每组件中心 y。
  private func keepLargeComponents(_ mask: inout [Bool], w: Int, h: Int,
                                   minSize: Int) -> (comps: [(minX: Int, maxX: Int,
                                                             minY: Int, maxY: Int,
                                                             size: Int)],
                                                     label: [Int],
                                                     centerY: [Int: Double]) {
    let maxCompH = max(8, Int(Double(h) * 0.12))
    var label = [Int](repeating: -1, count: w * h)
    var stack = [Int]()
    var compId = 0
    var compSize: [Int] = [0]
    var compMinY: [Int] = [0]
    var compMaxY: [Int] = [0]
    var compMinX: [Int] = [0]
    var compMaxX: [Int] = [0]
    for start in 0..<(w * h) where mask[start] && label[start] == -1 {
      compId += 1
      compSize.append(0)
      compMinY.append(Int.max)
      compMaxY.append(-1)
      compMinX.append(Int.max)
      compMaxX.append(-1)
      stack.append(start)
      label[start] = compId
      while let p = stack.popLast() {
        compSize[compId] += 1
        let py = p / w, px = p % w
        if py < compMinY[compId] { compMinY[compId] = py }
        if py > compMaxY[compId] { compMaxY[compId] = py }
        if px < compMinX[compId] { compMinX[compId] = px }
        if px > compMaxX[compId] { compMaxX[compId] = px }
        for (dy, dx) in [(0, 1), (0, -1), (1, 0), (-1, 0)] {
          let nx = px + dx, ny = py + dy
          if nx < 0 || nx >= w || ny < 0 || ny >= h { continue }
          let q = ny * w + nx
          if mask[q] && label[q] == -1 {
            label[q] = compId
            stack.append(q)
          }
        }
      }
    }
    // 过滤：像素数不足或组件过高（大片亮区）→ 清除
    for p in 0..<(w * h) where mask[p] {
      let c = label[p]
      if compSize[c] < minSize { mask[p] = false; continue }
      if compMaxY[c] - compMinY[c] > maxCompH { mask[p] = false; continue }
    }
    // 收集通过过滤的组件 bbox（按 compId 去重），并记录每组件中心 y
    var comps = [(minX: Int, maxX: Int, minY: Int, maxY: Int, size: Int)]()
    var compCenterOfId = [Int: Double]()
    var seen = Set<Int>()
    for p in 0..<(w * h) where mask[p] {
      let c = label[p]
      if seen.insert(c).inserted {
        comps.append((compMinX[c], compMaxX[c], compMinY[c], compMaxY[c], compSize[c]))
        compCenterOfId[c] = Double(compMinY[c] + compMaxY[c]) / 2.0
      }
    }
    return (comps, label, compCenterOfId)
  }

  /// 形态学膨胀（scatter：对每个命中像素标记邻域，代价 = 命中数×核面积）
  private func dilate(_ mask: inout [Bool], w: Int, h: Int, radius: Int) {
    var out = mask
    for y in 0..<h {
      for x in 0..<w where mask[y * w + x] {
        let y0 = max(0, y - radius), y1 = min(h - 1, y + radius)
        let x0 = max(0, x - radius), x1 = min(w - 1, x + radius)
        for yy in y0...y1 {
          let base = yy * w
          for xx in x0...x1 { out[base + xx] = true }
        }
      }
    }
    mask = out
  }

  /// 图像修复（在整块 mask 的 bbox 内）：
  /// ① 洋葱剥皮：每轮用周围已知像素填边界环（从真实纹理向内收敛）
  /// ② 高斯-赛德尔扩散平滑 22 轮，让填充融入周围纹理
  private func inpaintRegion(_ buf: inout [UInt8], mask: [Bool], w: Int, regionH: Int) {
    let bpr = w * 4
    var work = mask // 逐步清零的"未知"集合
    var minX = w, maxX = 0, minY = regionH, maxY = 0
    var remaining = 0
    for y in 0..<regionH {
      for x in 0..<w where work[y * w + x] {
        if x < minX { minX = x }
        if x > maxX { maxX = x }
        if y < minY { minY = y }
        if y > maxY { maxY = y }
        remaining += 1
      }
    }
    minX = max(0, minX - 4); maxX = min(w - 1, maxX + 4)
    minY = max(0, minY - 4); maxY = min(regionH - 1, maxY + 4)

    // ① 洋葱剥皮
    while remaining > 0 {
      var filledThisRound = [(Int, UInt8, UInt8, UInt8)]()
      for y in minY...maxY {
        for x in minX...maxX where work[y * w + x] {
          var sr = 0, sg = 0, sb = 0, n = 0
          for (dy, dx) in [(0, 1), (0, -1), (1, 0), (-1, 0)] {
            let nx = x + dx, ny = y + dy
            if nx < 0 || nx >= w || ny < 0 || ny >= regionH { continue }
            if work[ny * w + nx] { continue } // 邻居还未知
            let i = ny * bpr + nx * 4
            sr += Int(buf[i]); sg += Int(buf[i + 1]); sb += Int(buf[i + 2]); n += 1
          }
          if n > 0 {
            filledThisRound.append((y * w + x, UInt8(sr / n), UInt8(sg / n), UInt8(sb / n)))
          }
        }
      }
      if filledThisRound.isEmpty { break } // 剩余孤岛，放弃（几乎不可能）
      for (p, r, g, b) in filledThisRound {
        let i = (p / w) * bpr + (p % w) * 4
        buf[i] = r; buf[i + 1] = g; buf[i + 2] = b
        work[p] = false
        remaining -= 1
      }
    }

    // ② 扩散平滑（只平滑原 mask 区域）
    for _ in 0..<22 {
      for y in minY...maxY {
        for x in minX...maxX {
          let p = y * w + x
          guard mask[p] else { continue }
          var sr = 0, sg = 0, sb = 0, n = 0
          for (dy, dx) in [(0, 1), (0, -1), (1, 0), (-1, 0)] {
            let nx = x + dx, ny = y + dy
            if nx < 0 || nx >= w || ny < 0 || ny >= regionH { continue }
            let i = ny * bpr + nx * 4
            sr += Int(buf[i]); sg += Int(buf[i + 1]); sb += Int(buf[i + 2]); n += 1
          }
          if n > 0 {
            let i = (p / w) * bpr + (p % w) * 4
            buf[i] = UInt8(sr / n); buf[i + 1] = UInt8(sg / n); buf[i + 2] = UInt8(sb / n)
          }
        }
      }
    }
  }

  /// 转换流程状态（防 requestMediaDataWhenReady 回调重入）
  private final class ConversionState {
    var videoDone = false
    var audioDone = false
    var metaDone = false
    var finishing = false
  }
}
