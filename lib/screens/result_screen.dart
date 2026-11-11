import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../models/parsed_media.dart';
import '../services/ai_inpaint_service.dart';
import '../services/ai_settings.dart';
import '../services/downloader.dart';
import '../services/saver_channel.dart';
import '../theme/app_theme.dart';

/// 解析结果页：媒体网格 + 点按预览 + 长按多选 + 保存
class ResultScreen extends StatefulWidget {
  final ParseResult result;
  const ResultScreen({super.key, required this.result});

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  final _downloading = <int, double>{};
  final _selected = <int>{};

  Future<void> _saveItems(List<int> indices) async {
    for (final i in indices) {
      if (!mounted) return;
      if (!_downloading.containsKey(i)) {
        await _saveItem(i);
      }
    }
  }

  /// 按需合成实况照片（默认保存走"图片+视频分开存"，这里手动触发合成）
  Future<void> _mergeLiveItems(List<int> indices) async {
    final lives = indices.where((i) => widget.result.items[i].isLivePhoto).toList();
    if (lives.isEmpty) {
      _showStatus('当前选择里没有 Live 图', error: true);
      return;
    }
    for (final i in lives) {
      if (!_downloading.containsKey(i)) {
        await _mergeLiveItem(i);
      }
    }
  }

  Future<void> _mergeLiveItem(int index) async {
    final item = widget.result.items[index];
    // 微博实况图：静态帧同样走 native 去水印（高画质无水印）
    final stripWatermark = widget.result.platform == ParsePlatform.weibo;
    if (!mounted) return;
    setState(() => _downloading[index] = 0);
    try {
      final liveUrl = item.companionUrl!;
      final liveExt = liveUrl.toLowerCase().contains('.mov') ? 'mov' : 'mp4';
      final videoFile = await Downloader.download(
          ParsedMediaItem(
              kind: MediaKind.video,
              url: liveUrl,
              ext: liveExt,
              fallbackUrls: item.companionFallbackUrls),
          onProgress: (r, t) {
        if (!mounted) return;
        setState(() => _downloading[index] = t > 0 ? r / t : 0);
      });
      String? imagePath;
      if (item.url.isNotEmpty) {
        try {
          imagePath = (await Downloader.download(
                  ParsedMediaItem(kind: MediaKind.image, url: item.url)))
              .path;
        } catch (_) {/* 交给原生从视频抽帧 */}
      }
      _showStatus('正在合成实况…');
      final mode = await SaverChannel.saveLivePhoto(
        imagePath: imagePath,
        videoPath: videoFile.path,
        removeWatermark: stripWatermark,
      );
      _showStatus(switch (mode) {
        'live' => '已合成为实况照片 ✅',
        'videoOnly' => '合成失败，已保存视频 ⚠️',
        'imageOnly' => '合成失败，已保存图片 ⚠️',
        _ => '合成失败，已分开保存图片 + 视频 ⚠️',
      });
    } catch (e) {
      _showStatus('合成失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _downloading.remove(index));
    }
  }

  /// AI 去水印：本地生成蒙版 → 调用户配置的接口 → 保存修复结果
  Future<void> _aiInpaintItems(List<int> indices) async {
    final targets =
        indices.where((i) => !widget.result.items[i].isVideo).toList();
    if (targets.isEmpty) {
      _showStatus('当前选择里没有图片', error: true);
      return;
    }
    for (final i in targets) {
      if (!_downloading.containsKey(i)) await _aiInpaintItem(i);
    }
  }

  Future<void> _aiInpaintItem(int index) async {
    final item = widget.result.items[index];
    if (!mounted) return;
    setState(() => _downloading[index] = 0);
    try {
      final file = await Downloader.download(item, onProgress: (r, t) {
        if (!mounted) return;
        setState(() => _downloading[index] = t > 0 ? r / t : 0);
      });
      // 下载源是小红书原图直链时图片本身无水印，AI/本地修补都只会误伤画面
      final srcHost =
          Uri.tryParse(Downloader.lastSourceUrl ?? '')?.host ?? '';
      final usedCleanOriginal = srcHost.contains('sns-img');
      if (usedCleanOriginal) {
        await SaverChannel.saveImage(file.path);
        _showStatus('原图直链无水印，已直接保存 ✅');
        return;
      }
      _showStatus('正在生成水印蒙版…');
      final maskPath = await SaverChannel.makeWatermarkMask(file.path);
      if (maskPath == null) {
        // 2026-11-09：未检测到水印 = 图本身干净，直接原样保存。
        // 不再走本地涂抹修补（用户要求：零二次处理）。
        await SaverChannel.saveImage(file.path);
        _showStatus('未检测到水印，已原样保存 ✅');
        return;
      }
      _showStatus('AI 修复中（可能需要十几秒）…');
      final fixed = await AiInpaintService.inpaint(
          imagePath: file.path, maskPath: maskPath);
      await SaverChannel.saveImage(fixed);
      _showStatus('AI 去水印已保存 ✅');
    } catch (e) {
      _showStatus(e.toString().replaceFirst('Exception: ', ''), error: true);
    } finally {
      if (mounted) setState(() => _downloading.remove(index));
    }
  }

  Future<void> _saveItem(int index) async {
    final item = widget.result.items[index];
    // 2026-11-09 高画质无水印方案：
    //   微博 = 下载 large 全分辨率原图 + native 精准去水印（stripWatermark），
    //         检测不到水印则原样保存，兼顾"高画质 + 无水印"；
    //   小红书/抖音 = 直接爬取无水印原始文件，零二次处理。
    final stripWatermark = widget.result.platform == ParsePlatform.weibo;
    if (!mounted) return;
    setState(() => _downloading[index] = 0);
    try {
      final file = await Downloader.download(item, onProgress: (r, t) {
        if (!mounted) return;
        setState(() => _downloading[index] = t > 0 ? r / t : 0);
      });

      String status;
      if (item.isLivePhoto) {
        // 2026-11-06 按用户要求：关闭实况合成，直接分开保存「图片 + 视频」。
        // 原因：微博实况视频不带苹果实况元数据，注入链路在设备上多次失败，
        // 且失败时会退回"分开保存"并给出误导性提示。分开存更可靠、可预期。
        _showStatus('正在保存实况（图片 + 视频）…');
        final liveUrl = item.companionUrl!;
        final liveExt = liveUrl.toLowerCase().contains('.mov') ? 'mov' : 'mp4';
        final videoFile = await Downloader.download(ParsedMediaItem(
            kind: MediaKind.video,
            url: liveUrl,
            ext: liveExt,
            fallbackUrls: item.companionFallbackUrls));

        var savedImage = false;
        var savedVideo = false;
        if (item.url.isNotEmpty) {
          try {
            final img = await Downloader.download(
                ParsedMediaItem(kind: MediaKind.image, url: item.url));
            await SaverChannel.saveImage(img.path,
                removeWatermark: stripWatermark);
            savedImage = true;
          } catch (_) {/* 静态帧拿不到就只存视频 */}
        }
        try {
          await SaverChannel.saveVideo(videoFile.path);
          savedVideo = true;
        } catch (_) {}

        status = savedImage && savedVideo
            ? '已保存图片 + 视频（实况合成已关闭）✅'
            : savedVideo
                ? '仅保存了视频（图片获取失败）⚠️'
                : savedImage
                    ? '仅保存了图片（视频保存失败）⚠️'
                    : '保存失败，请重试';
      } else if (item.isVideo) {
        // 抖音动图：play_addr 是无声画面，audioUrl 带 BGM 音轨 —— 下载后合成
        final audioUrl = item.audioUrl;
        if (audioUrl != null && audioUrl.isNotEmpty) {
          _showStatus('正在合成画面 + BGM…');
          final audioFile = await Downloader.download(ParsedMediaItem(
              kind: MediaKind.video, url: audioUrl, ext: 'mp3'));
          await SaverChannel.saveVideoWithAudio(file.path, audioFile.path);
          status = '视频已保存到相册 ✅（画面 + BGM）';
        } else {
          await SaverChannel.saveVideo(file.path);
          status = '视频已保存到相册 ✅';
        }
      } else {
        await SaverChannel.saveImage(file.path,
            removeWatermark: stripWatermark);
        status = stripWatermark
            ? '图片已保存到相册 ✅（高画质原图 + 去水印）'
            : '图片已保存到相册 ✅（原始文件，未做任何处理）';
      }
      _showStatus(status);
    } catch (e) {
      final msg = e is TimeoutException
          ? '保存超时，已停止等待。请打开相册确认是否已保存'
          : '保存失败：$e';
      _showStatus(msg, error: true);
    } finally {
      if (mounted) setState(() => _downloading.remove(index));
    }
  }

  void _showStatus(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: error ? AppColors.danger : AppColors.success));
  }

  void _toggleSelect(int index) {
    setState(() {
      if (_selected.contains(index)) {
        _selected.remove(index);
      } else {
        _selected.add(index);
      }
    });
  }

  void _openPreview(int index) {
    final item = widget.result.items[index];
    if (item.isVideo) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => _VideoPreviewScreen(item: item, onSave: () async {
          Navigator.of(context).pop();
          await _saveItem(index);
        }),
      ));
    } else if (item.url.isNotEmpty) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => _ImagePreviewScreen(
            url: item.url, isLive: item.isLivePhoto, onSave: () async {
          Navigator.of(context).pop();
          await _saveItem(index);
        }),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.result;
    final allIndices = List<int>.generate(r.items.length, (i) => i);
    final targets = _selected.isEmpty ? allIndices : _selected.toList();

    return Scaffold(
      appBar: AppBar(title: Text(_platformName(r.platform))),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.l),
              children: [
                Text(r.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.subtitle),
                const SizedBox(height: AppSpacing.xs),
                Text(r.author.isEmpty ? '未知作者' : '@${r.author}',
                    style: AppText.secondary),
                const SizedBox(height: AppSpacing.s),
                Text('点按预览 · 长按选择/取消', style: AppText.caption),
                const SizedBox(height: AppSpacing.m),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: AppSpacing.s,
                    crossAxisSpacing: AppSpacing.s,
                  ),
                  itemCount: r.items.length,
                  itemBuilder: (_, i) => _MediaCell(
                    item: r.items[i],
                    progress: _downloading[i],
                    selected: _selected.contains(i),
                    onTap: _downloading.containsKey(i)
                        ? null
                        : () => _openPreview(i),
                    onLongPress: () => _toggleSelect(i),
                  ),
                ),
                const SizedBox(height: AppSpacing.m),
                Container(
                  padding: const EdgeInsets.all(AppSpacing.m),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(AppRadius.chip),
                  ),
                  child: Text(
                    '共 ${r.items.length} 项：图片 ${r.imageCount} · '
                    '视频 ${r.items.where((e) => e.isVideo).length} · '
                    'Live ${r.items.where((e) => e.isLivePhoto).length}\n'
                    '所有文件均为原始分辨率/原始码率，仅供个人使用。',
                    style: AppText.caption),
                ),
              ],
            ),
          ),
          SafeArea(
            minimum: const EdgeInsets.all(AppSpacing.l),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 小红书已直取作者原始上传文件（无水印），不提供 AI 入口
                // （用户要求：小红书只走直接爬取，不调用任何接口）
                if (AiSettings.enabled &&
                    r.platform != ParsePlatform.xiaohongshu &&
                    targets.any((i) => !r.items[i].isVideo))
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.s),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _downloading.isNotEmpty
                            ? null
                            : () => _aiInpaintItems(targets),
                        icon: const Icon(Icons.auto_fix_high, size: 18),
                        label: const Text('AI 去水印（自带 Key）'),
                      ),
                    ),
                  ),
                if (targets.any((i) => r.items[i].isLivePhoto))
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.s),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _downloading.isNotEmpty
                            ? null
                            : () => _mergeLiveItems(targets),
                        icon: const Icon(Icons.motion_photos_on_outlined, size: 18),
                        label: const Text('合成实况照片'),
                      ),
                    ),
                  ),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _downloading.isNotEmpty
                        ? null
                        : () => _saveItems(targets),
                    child: Text(_downloading.isNotEmpty
                        ? '保存中…'
                        : _selected.isEmpty
                            ? '全部保存'
                            : '保存选中 (${_selected.length})'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _platformName(ParsePlatform p) => switch (p) {
        ParsePlatform.douyin => '抖音 · 解析结果',
        ParsePlatform.xiaohongshu => '小红书 · 解析结果',
        ParsePlatform.weibo => '微博 · 解析结果',
        ParsePlatform.xianyu => '闲鱼 · 解析结果',
        ParsePlatform.twitter => 'X（推特）· 解析结果',
        ParsePlatform.unknown => '解析结果',
      };
}

class _MediaCell extends StatelessWidget {
  final ParsedMediaItem item;
  final double? progress;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback onLongPress;

  const _MediaCell({
    required this.item,
    this.progress,
    required this.selected,
    this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final display = item.isVideo ? (item.coverUrl ?? item.url) : item.url;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.chip),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (display.isEmpty)
              Container(
                color: AppColors.divider,
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.animation,
                        size: 28, color: AppColors.textTertiary),
                    SizedBox(height: 4),
                    Text('GIF · 实况', style: AppText.caption),
                  ],
                ),
              )
            else
              Image.network(display, fit: BoxFit.cover,
                loadingBuilder: (_, child, ev) =>
                    ev == null ? child : Container(color: AppColors.divider),
                errorBuilder: (_, __, ___) => Container(
                  color: AppColors.divider,
                  child: const Icon(Icons.broken_image_outlined,
                      color: AppColors.textTertiary),
                ),
              ),
            if (item.isVideo)
              const Center(
                child: Icon(Icons.play_circle_fill,
                    size: 36, color: Colors.white70),
              ),
            if (item.isLivePhoto)
              Positioned(
                top: 6, left: 6,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.liveBadge,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('LIVE',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w700)),
                ),
              ),
            if (selected)
              Container(color: Colors.white.withOpacity(0.25)),
            if (selected)
              const Positioned(
                top: 6, right: 6,
                child: CircleAvatar(
                  radius: 10,
                  backgroundColor: AppColors.primary,
                  child: Icon(Icons.check, size: 14, color: Colors.white),
                ),
              ),
            if (progress != null)
              Container(
                color: Colors.black45,
                child: Center(
                  child: SizedBox(
                    width: 28, height: 28,
                    child: CircularProgressIndicator(
                        value: progress == 0 ? null : progress,
                        strokeWidth: 2.6, color: Colors.white),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 图片全屏预览（可缩放），确认后保存
class _ImagePreviewScreen extends StatefulWidget {
  final String url;
  final bool isLive;
  final Future<void> Function() onSave;
  const _ImagePreviewScreen(
      {required this.url, required this.isLive, required this.onSave});

  @override
  State<_ImagePreviewScreen> createState() => _ImagePreviewScreenState();
}

class _ImagePreviewScreenState extends State<_ImagePreviewScreen> {
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(widget.isLive ? '实况图预览' : '图片预览',
            style: const TextStyle(color: Colors.white, fontSize: 16)),
      ),
      body: InteractiveViewer(
        maxScale: 5,
        child: Center(
          child: Image.network(widget.url, fit: BoxFit.contain,
            loadingBuilder: (_, child, ev) => ev == null
                ? child
                : const Center(
                    child: CircularProgressIndicator(color: Colors.white)),
            errorBuilder: (_, __, ___) => const Center(
                child: Text('预览加载失败（X 图片需要配置代理）',
                    style: TextStyle(color: Colors.white54))),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.all(AppSpacing.l),
        child: FilledButton(
          onPressed: _saving
              ? null
              : () async {
                  setState(() => _saving = true);
                  await widget.onSave();
                },
          child: Text(_saving ? '保存中…' : '保存原图'),
        ),
      ),
    );
  }
}

/// 视频预览（保存前确认内容）
class _VideoPreviewScreen extends StatefulWidget {
  final ParsedMediaItem item;
  final Future<void> Function() onSave;
  const _VideoPreviewScreen({required this.item, required this.onSave});

  @override
  State<_VideoPreviewScreen> createState() => _VideoPreviewScreenState();
}

class _VideoPreviewScreenState extends State<_VideoPreviewScreen> {
  VideoPlayerController? _controller;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final c = VideoPlayerController.networkUrl(Uri.parse(widget.item.url));
    _controller = c;
    c.initialize().then((_) {
      if (mounted) {
        setState(() {});
        c.play();
      }
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('视频预览',
            style: TextStyle(color: Colors.white, fontSize: 16)),
      ),
      body: Center(
        child: c != null && c.value.isInitialized
            ? AspectRatio(
                aspectRatio: c.value.aspectRatio, child: VideoPlayer(c))
            : const CircularProgressIndicator(color: Colors.white),
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.all(AppSpacing.l),
        child: FilledButton(
          onPressed: _saving
              ? null
              : () async {
                  setState(() => _saving = true);
                  await widget.onSave();
                },
          child: Text(_saving ? '保存中…' : '保存原视频'),
        ),
      ),
    );
  }
}
