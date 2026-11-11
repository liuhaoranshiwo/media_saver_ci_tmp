// MainActivity.kt
// flutter create . 生成 android 平台目录后，用本文件替换
// android/app/src/main/kotlin/com/mediastack/media_saver/MainActivity.kt
// （路径需与 applicationId 一致，flutter create --org com.mediastack --project-name media_saver）
//
// 说明：Android 无系统级 Live Photo，saveLivePhoto 降级为分开保存图片 + 视频。
// 分区存储（Android 10+）用 MediaStore，无需 WRITE_EXTERNAL_STORAGE。

package com.mediastack.media_saver

import android.content.ContentValues
import android.os.Build
import android.provider.MediaStore
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "com.mediastack.media_saver/saver"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "saveImage", "saveVideo" -> {
                            val path = call.argument<String>("path")
                                ?: run { result.error("BAD_ARGS", "缺少 path", null); return@setMethodCallHandler }
                            val file = File(path)
                            if (!file.exists()) {
                                result.error("FILE_NOT_FOUND", "文件不存在: $path", null); return@setMethodCallHandler
                            }
                            insertMedia(file, call.method == "saveVideo")
                            result.success(null)
                        }
                        "saveLivePhoto" -> {
                            // Android 无系统级 Live Photo：图片（可选）+ 视频分开保存
                            val imagePath = call.argument<String>("imagePath")
                            val videoPath = call.argument<String>("videoPath")
                                ?: run { result.error("BAD_ARGS", "缺少 videoPath", null); return@setMethodCallHandler }
                            if (imagePath != null) {
                                val img = File(imagePath)
                                if (img.exists()) insertMedia(img, false)
                            }
                            insertMedia(File(videoPath), true)
                            result.success("separate")
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("SAVE_FAILED", e.message, null)
                }
            }
    }

    private fun insertMedia(file: File, isVideo: Boolean) {
        val resolver = applicationContext.contentResolver
        val collection =
            if (isVideo) MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            else MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, file.name)
            put(
                MediaStore.MediaColumns.MIME_TYPE,
                if (isVideo) "video/mp4"
                else if (file.extension.equals("png", true)) "image/png" else "image/jpeg"
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(
                    MediaStore.MediaColumns.RELATIVE_PATH,
                    if (isVideo) "Movies/MediaSaver" else "Pictures/MediaSaver"
                )
            }
        }

        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("MediaStore 插入失败")
        resolver.openOutputStream(uri)?.use { out ->
            file.inputStream().use { it.copyTo(out) }
        }
    }
}
