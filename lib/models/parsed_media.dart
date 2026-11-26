/// 媒体数据模型：解析结果统一结构
/// 所有平台解析器输出统一的 ParseResult / ParsedMediaItem
library;

enum MediaKind { image, video, livePhoto }

enum ParsePlatform {
  douyin,
  xiaohongshu,
  weibo,
  xianyu,
  twitter,
  bilibili,
  unknown,
}

class ParsedMediaItem {
  final MediaKind kind;

  /// image: 图片地址；video: 视频地址（无水印）；livePhoto: 静态帧图片地址
  final String url;

  /// livePhoto 专用：配对的实况视频地址（MOV/MP4）
  final String? companionUrl;

  /// livePhoto 专用：实况视频的候选链（主域 403 时换备份域）
  final List<String> companionFallbackUrls;

  /// video 封面
  final String? coverUrl;

  /// 抖音动图专用：BGM 音轨地址（mp3）。抖音动图 play_addr 是无声画面
  /// （BGM 由播放器实时混音），保存时需下载此音轨与画面合成，得到
  /// "无水印 + 带 BGM"的完整视频。非空时保存走音视频合成。
  final String? audioUrl;

  final int? width;
  final int? height;

  /// 文件扩展名建议（不带点）
  final String ext;

  /// 候选地址链：url 下载失败（404/410 等）时按序尝试
  /// （微博无水印前缀 woriginal 不一定每张旧图都有，失败自动回退 large）
  final List<String> fallbackUrls;

  const ParsedMediaItem({
    required this.kind,
    required this.url,
    this.companionUrl,
    this.companionFallbackUrls = const [],
    this.coverUrl,
    this.audioUrl,
    this.width,
    this.height,
    this.ext = 'jpg',
    this.fallbackUrls = const [],
  });

  bool get isVideo => kind == MediaKind.video;
  bool get isLivePhoto => kind == MediaKind.livePhoto;
}

class ParseResult {
  final ParsePlatform platform;
  final String sourceUrl;
  final String title;
  final String author;
  final String? avatarUrl;
  final List<ParsedMediaItem> items;
  final DateTime parsedAt;

  /// 附加提示（结果页顶部展示）：
  /// 抖音作者主页匿名抓取时被登录墙截断 → "已抓取 N 件（共 M 件），登录后可抓全部"
  final String? notice;

  /// 此次抓取是否已完整（build 122）
  ///
  /// 结果页据此决定要不要给"重新抓取"入口。原先靠 `notice.contains('全部')`
  /// 判断，文案一改就失效（build 122 改口径时立刻踩到）→ 改成显式标志。
  final bool complete;

  /// 结果来自作者主页（多作品聚合，build 122）
  ///
  /// 作者主页的「作品数」与「媒体文件数」天然不等（一个图集拆成多项），
  /// 结果页需要据此补一句口径说明；单作品解析没有这个问题。
  final bool isProfile;

  const ParseResult({
    required this.platform,
    required this.sourceUrl,
    required this.title,
    required this.author,
    this.avatarUrl,
    required this.items,
    required this.parsedAt,
    this.notice,
    this.complete = false,
    this.isProfile = false,
  });

  bool get hasLivePhoto => items.any((e) => e.isLivePhoto);
  bool get hasVideo => items.any((e) => e.isVideo);
  int get imageCount => items.where((e) => !e.isVideo).length;
}

class ParseException implements Exception {
  final String message;

  /// 需要登录才能解析（首页据此渲染"登录"按钮，登录后自动重试）
  /// 2026-11-26：抖音匿名已不返回主页作品列表，只有登录后才能抓取
  final bool needLogin;

  ParseException(this.message, {this.needLogin = false});
  @override
  String toString() => message;
}
