import 'dart:convert';
import '../http_util.dart';
import '../app_logger.dart';
import '../../models/parsed_media.dart';
import '../parser_service.dart';

/// 小红书解析器（免 Cookie 方案已被开源项目验证）
///
/// 免登录原理（参考 tamnd/xiaohongshu-cli、XHS-Downloader 的结论）：
/// - note 页面的 window.__INITIAL_STATE__ 是【服务端渲染】，匿名请求即可读到，
///   不需要任何 Cookie；签名 API（edith.xiaohongshu.com）才需要登录态 —— 我们不用它
/// - 唯一硬性要求：必须保留分享链接自带的 xsec_token 查询参数（缺失会 403/风控页）
///
/// 链路：
/// 1. 短链 xhslink.com/xxx → 30x → xiaohongshu.com/explore/{noteId}?xsec_token=...&xsec_source=...
///    （也支持 /discovery/item/、/user/profile/{uid}/{noteId} 形式）
/// 2. GET 该 H5 页（带移动端 UA）→ window.__INITIAL_STATE__
///    ⚠️ JSON 含字面量 undefined，需替换为 null 才能解析
/// 3. noteDetailMap[noteId].note：
///    - 图集：note.imageList[].urlDefault / url（CDN 原图，本身无水印）
///    - 实况图：note.imageList[].livePhoto（"true"）+ livePhotoUrl（配对视频）
//!     平台限制：小红书实况视频轨本身带水印（XHS-Downloader 同样标注"含水印"），无法去除
///    - 视频：note.media.video.media.stream.h264[].masterUrl（无水印，选码率最高档）
class XiaohongshuParser extends MediaParser {
  static final _noteId = RegExp(r'/(?:explore|discovery/item)/([0-9a-f]{24})');

  @override
  Future<ParseResult> parse(String url) async {
    final (finalUrl, html) =
        await HttpUtil.getWithRedirects(url, ua: HttpUtil.iosUa);

    final m = _noteId.firstMatch(finalUrl);
    String? noteId = m?.group(1);
    if (noteId == null) {
      // 兜底：从任意路径取 24 位 hex
      noteId =
          RegExp(r'([0-9a-f]{24})').firstMatch(finalUrl)?.group(1);
    }
    if (noteId == null) {
      throw ParseException('小红书链接中未找到笔记 ID');
    }

    final stateJson = _extractInitialState(html);
    if (stateJson == null) {
      throw ParseException('小红书页面数据获取失败（可能需要重新分享链接）');
    }
    // __INITIAL_STATE__ 中含字面量 undefined，需替换为 null 才是合法 JSON
    final cleaned = stateJson.replaceAll(RegExp(r'\bundefined\b'), 'null');
    final data = jsonDecode(cleaned) as Map<String, dynamic>;

    // 2026-11 页面改版：/explore/ 仍是 noteDetailMap，/discovery/item/ 变成
    // noteData.data.noteData —— 两条路径都试
    Map<String, dynamic>? note;
    final noteDetailMap = data['noteDetailMap'] as Map<String, dynamic>?;
    if (noteDetailMap != null) {
      for (final v in noteDetailMap.values) {
        final n = ((v as Map)['note']) as Map<String, dynamic>?;
        if (n != null) {
          note = n;
          break;
        }
      }
    }
    if (note == null) {
      final nd = data['noteData'] as Map<String, dynamic>?;
      final inner = ((nd?['data'] ?? const {}) as Map)['noteData'];
      if (inner is Map && inner.isNotEmpty) {
        note = inner.cast<String, dynamic>();
      }
    }
    if (note == null) throw ParseException('未找到笔记正文数据');

    final title = (note['title'] as String?) ?? (note['desc'] as String?) ?? '小红书笔记';
    final userMap = (note['user'] ?? const {}) as Map;
    final author = (userMap['nickname'] ?? userMap['nickName']) as String? ?? '';

    final items = <ParsedMediaItem>[];

    // ---- 视频（先于图片判断！2026-11-06 实测：视频笔记的 imageList 里
    // 会放 1 张【带水印封面图】，若先输出图片，视频分支就被跳过 →
    // "视频识别成照片"。视频笔记只应输出视频。）----
    Map<String, dynamic>? video =
        note['media'] is Map ? (note['media'] as Map)['video'] as Map<String, dynamic>? : null;
    video ??= note['video'] is Map ? note['video'] as Map<String, dynamic>? : null;
    final stream = (((video?['media'] ?? const {}) as Map)['stream'])
        as Map<String, dynamic>?;

    if (stream != null) {
      // 跨编码收集全部档位选最高：像素面积优先，同面积看码率，同码率偏好 h264
      // 字段兼容：新结构驼峰 avgBitrate/videoBitrate，旧结构下划线 avg_bitrate
      // ⚠️ 2026-11-06 实测：masterUrl 的 sns-video-* 域已 CDN 防链（403
      // Forbid_code 001100），backup 域 sns-bak-v1.xhscdn.com 仍可用（206），
      // 且每档 backupUrls（字符串化数组）含备用直链 → 构造候选链让下载器回退
      String? bestMaster;
      int bestPx = -1, bestBr = -1;
      var bestIsH264 = false;
      final extraBackups = <String>[];
      for (final key in ['h264', 'h265', 'av1', 'vkey']) {
        final arr = stream[key] as List?;
        if (arr == null) continue;
        for (final v in arr) {
          if (v is! Map) continue;
          final map = v.cast<String, dynamic>();
          final rawUrl = map['masterUrl'] as String?;
          if (rawUrl == null || rawUrl.isEmpty) continue;
          final w = _intOf(map['width']) ?? 0;
          final h = _intOf(map['height']) ?? 0;
          final br = _intOf(map['videoBitrate']) ??
              _intOf(map['avgBitrate']) ??
              _intOf(map['avg_bitrate']) ??
              0;
          final px = w * h;
          final isH264 = key == 'h264';
          final better = px > bestPx ||
              (px == bestPx && br > bestBr) ||
              (px == bestPx && br == bestBr && isH264 && !bestIsH264);
          if (better) {
            bestPx = px;
            bestBr = br;
            bestIsH264 = isH264;
            bestMaster = rawUrl;
          }
          // 收集各档 backupUrls（字段是字符串化数组，如 "['http://...']"）
          final rawBackups = map['backupUrls'];
          if (rawBackups is String && rawBackups.isNotEmpty) {
            for (final m2
                in RegExp(r'https?://[^\s\]]+').allMatches(rawBackups)) {
              var u = m2.group(0)!;
              while (u.endsWith("'")) {
                u = u.substring(0, u.length - 1);
              }
              if (u.isNotEmpty && !extraBackups.contains(u)) {
                extraBackups.add(u);
              }
            }
          }
        }
      }
      if (bestMaster != null) {
        final candidates = <String>[];

        // ⭐ 原片优先（2026-11-06 实测）：note.video.consumer.originVideoKey
        // 形如 pre_post/1040g0cg...，在 sns-video-hw / -bd 上直接就是作者上传的原文件。
        // 实测同一条笔记：流地址 720x960 / 187kbps（且带"小红书号"水印），
        // 原片 https://sns-video-hw.xhscdn.com/{key} = 2160x2880 / 6.6Mbps / 25MB，无水印。
        final originKey =
            (((video?['consumer'] ?? const {}) as Map)['originVideoKey'])
                as String?;
        if (originKey != null && originKey.isNotEmpty) {
          for (final host in ['sns-video-hw', 'sns-video-bd']) {
            final u = 'https://$host.xhscdn.com/$originKey';
            if (!candidates.contains(u)) candidates.add(u);
          }
        }

        final master = _httpsify(bestMaster);
        if (!candidates.contains(master)) candidates.add(master);
        // 域改写到备份域（同路径）
        final bakUrl = bestMaster
            .replaceAll(RegExp(r'sns-video-[a-z0-9]+'), 'sns-bak-v1');
        final bakHttps = _httpsify(bakUrl);
        if (!candidates.contains(bakHttps)) candidates.add(bakHttps);
        for (final u in extraBackups) {
          final hu = _httpsify(u);
          if (!candidates.contains(hu)) candidates.add(hu);
        }
        // 封面仅作展示（视频笔记的 imageList 图带小红书水印，不当素材输出）
        String? cover;
        for (final raw in (note['imageList'] as List? ?? const [])) {
          if (raw is! Map) continue;
          for (final k in ['urlDefault', 'url', 'urlPre']) {
            final val = (raw as Map)[k];
            if (val is String && val.isNotEmpty) {
              cover = val;
              break;
            }
          }
          if (cover != null) break;
        }
        final vi = video?['image'];
        if (cover == null && vi is Map) {
          final fu = vi['firstUrl'];
          if (fu is String && fu.isNotEmpty) cover = fu;
        }
        items.add(ParsedMediaItem(
          kind: MediaKind.video,
          url: candidates.first,
          fallbackUrls: candidates.sublist(1),
          coverUrl: cover,
          ext: 'mp4',
        ));
      }
    }

    // ---- 图集（仅非视频笔记）----
    if (items.isEmpty) {
      final imageList = note['imageList'] as List? ?? const [];
      for (final raw in imageList) {
        final img = raw as Map<String, dynamic>;
        // 2026-11 改版后 urlDefault 可能为空串，需按序回退到 url/urlPre
        String? imageUrl;
        for (final k in ['urlDefault', 'url', 'urlPre']) {
          final v = img[k];
          if (v is String && v.isNotEmpty) {
            imageUrl = v;
            break;
          }
        }
        if (imageUrl == null) continue;
        final isLive =
            img['livePhoto'] == true || img['livePhoto'] == 'true';
        final liveUrl = img['livePhotoUrl'] as String?;
        // 2026-11-06 实测：urlDefault 带 CDN 处理参数（!nd_dft_wlteh_webp_3
        // 或 ?imageView2/2/w/1080/format/webp）——是压缩版！
        // 去掉参数后同一资源返回原始上传文件（506KB→916KB 实测）
        final candidates = _originalCandidates(imageUrl);
        // 诊断：记录原图直链是否拼出来了（候选>1 且首选为 sns-img 域 = 拼出）
        final firstHost = Uri.tryParse(candidates.first)?.host ?? '?';
        AppLogger.log('xhs',
            '图${items.length + 1}: 候选${candidates.length}个 首选=$firstHost '
            '原始=${Uri.tryParse(imageUrl)?.host ?? '?'}');
        items.add(ParsedMediaItem(
          kind: isLive && liveUrl != null
              ? MediaKind.livePhoto
              : MediaKind.image,
          url: candidates.first,
          fallbackUrls: candidates.sublist(1),
          companionUrl: isLive ? liveUrl : null,
          width: (img['width'] as num?)?.toInt(),
          height: (img['height'] as num?)?.toInt(),
        ));
      }
    }

    if (items.isEmpty) throw ParseException('未解析到可下载的图片或视频');

    return ParseResult(
      platform: ParsePlatform.xiaohongshu,
      sourceUrl: url,
      title: title,
      author: author,
      items: items,
      parsedAt: DateTime.now(),
    );
  }

  /// 小红书图片原图直取（2026-11-06 实测有效）。
  ///
  /// 关键发现：笔记页给的 urlDefault/url 都是 **H5 带水印版**
  /// （`sns-webpic-qc/…/{日期}/{hash}/notes_pre_post/{fileId}!h5_1080jpg`，
  ///  1080×1080、正中压制「小红书」水印）。
  /// 而同一 fileId 在图片 CDN 上还有 **原始上传文件**：
  ///   `https://sns-img-hw.xhscdn.com/notes_pre_post/{fileId}?imageView2/2/w/0/format/jpg`
  ///   → 2160×2160、1.15MB、**完全无水印**（HEIC 版 1.85MB 亦无水印）
  /// 因此不再依赖"删参数"这种碰运气做法，直接按 fileId 拼原图地址。
  static List<String> _originalCandidates(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.pathSegments.isEmpty) return [raw];

    // 真实资源路径 = 去掉 CDN 的「日期/hash」前缀与 `!处理后缀`
    const markers = ['notes_pre_post', 'notes_uhdr', 'spectrum', 'CRATER'];
    final segs = uri.pathSegments.map((e) => e.split('!').first).toList();
    final idx = segs.indexWhere((e) => markers.contains(e));
    if (idx < 0) {
      // 2026-11-09 新形态（移动分享页）：路径无 marker，末段即 fileId
      // （如 1040g008327ami786n8c05nehs1808avfacnnfi8!h5_1080jpg）。
      // fileId 直接拼 CDN 根路径 = 无水印原图（SSR 内嵌的 sns-na-i1 直链
      // 同为 fileId 根路径可证；真机实测 200 / 1.5MB vs H5 版 344KB）。
      // 旧逻辑此时只返回 raw（带水印 H5 图），导致保存环节触发涂抹修补糊脸。
      final fid = uri.pathSegments.last.split('!').first;
      if (fid.length >= 40) {
        const jpg = '?imageView2/2/w/0/format/jpg';
        return [
          _httpsify('https://sns-img-hw.xhscdn.com/$fid$jpg'),
          _httpsify('https://sns-img-bd.xhscdn.com/$fid$jpg'),
          raw, // 兜底：带水印 H5 图
        ];
      }
      return [raw]; // 未知形态：保持原样，交给下载器
    }

    final realPath = segs.sublist(idx).join('/');
    const jpg = '?imageView2/2/w/0/format/jpg';   // w/0 = 原始宽度
    final out = <String>[];
    void add(String u) {
      final h = _httpsify(u);
      if (!out.contains(h)) out.add(h);
    }

    add('https://sns-img-hw.xhscdn.com/$realPath$jpg');
    add('https://sns-img-bd.xhscdn.com/$realPath$jpg');
    // 注意：不带 format=jpg 会返回 HEIC，而文件按 .jpg 命名会 UTI 不符
    // （PhotoKit 可能拒收），因此只保留 JPEG 变体
    add(raw);                                          // 最后才用带水印的 H5 版
    return out;
  }

  String? _extractInitialState(String html) {
    final m = RegExp(r'window\.__INITIAL_STATE__\s*=\s*(\{[\s\S]*?\})\s*</script>')
        .firstMatch(html);
    return m?.group(1);
  }

  static int? _intOf(Object? v) =>
      v is num ? v.toInt() : int.tryParse('${v ?? ''}');

  /// http→https 强制升级（iOS ATS 拦截 http 请求；xhscdn 支持 https）
  static String _httpsify(String u) =>
      u.startsWith('http://') ? 'https://${u.substring(7)}' : u;
}
