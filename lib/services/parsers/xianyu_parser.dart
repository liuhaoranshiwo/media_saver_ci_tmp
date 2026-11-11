import 'dart:convert';
import '../http_util.dart';
import '../../models/parsed_media.dart';
import '../parser_service.dart';

/// 闲鱼解析器
///
/// ⚠️ 闲鱼与其他平台不同，是最难的一个：
/// 1. 商品详情数据走 mtop 接口（h5api.m.goofish.com/h5/mtop.taobao.detail.getdetail/）
///    请求需要 sign 签名 = md5(token & t & appKey & data)，token 来自 _m_h5_tk cookie，
///    且 appKey/版本号会轮换 —— 纯 HTTP 方案需要持续维护签名算法。
/// 2. 本版实现：拉取分享页 HTML，提取 og:image 主图 + 页面内嵌 JSON 中可直出的资源；
///    视频与多图走「受限模式」——提示用户在 App 内通过 WebView 打开并抓取。
/// 3. 完整方案建议：App 内嵌 WebView 打开商品页，监听图片/视频资源加载后由用户点选保存
//!    （WebView 方案为 P2 迭代，见 docs/平台解析链路说明.md）。
class XianyuParser extends MediaParser {
  @override
  Future<ParseResult> parse(String url) async {
    // 1. 展开淘口令/短链（2taobao.net / m.tb.cn 等中转）
    final (finalUrl, html) =
        await HttpUtil.getWithRedirects(url, ua: HttpUtil.androidUa);

    final items = <ParsedMediaItem>[];
    String title = '闲鱼商品';
    String author = '';

    // 2. og 标签（分享页几乎总是存在）
    final ogTitle =
        RegExp(r'<meta[^>]+property="og:title"[^>]+content="([^"]*)"')
            .firstMatch(html)
            ?.group(1);
    final ogImage =
        RegExp(r'<meta[^>]+property="og:image"[^>]+content="([^"]*)"')
            .firstMatch(html)
            ?.group(1);
    if (ogTitle != null && ogTitle.isNotEmpty) title = ogTitle;

    // 3. 页面内嵌 JSON 兜底（商品多图常在 __INIT_DATA__ / detailData 内）
    final initJson = _extractEmbeddedJson(html);
    if (initJson != null) {
      try {
        final images = _collectImageUrls(initJson);
        for (final u in images) {
          // 去掉缩放后缀，拿原图：img.alicdn.com/...jpg_400x400.jpg → .jpg
          final original = u.replaceAllMapped(
              RegExp(r'_\d+x\d+(q\d+)?\.(jpg|png|webp)$'), (m) => '.${m.group(2)}');
          if (items.every((e) => e.url != original)) {
            items.add(ParsedMediaItem(
              kind: MediaKind.image,
              url: original,
            ));
          }
        }
      } catch (_) {/* JSON 结构变化时静默降级到 og:image */}
    }

    if (items.isEmpty && ogImage != null && ogImage.isNotEmpty) {
      items.add(ParsedMediaItem(kind: MediaKind.image, url: ogImage));
    }

    if (items.isEmpty) {
      throw ParseException(
          '闲鱼商品资源解析受限：建议先复制链接在淘宝/闲鱼内打开，或等待后续版本（WebView 方案）');
    }

    return ParseResult(
      platform: ParsePlatform.xianyu,
      sourceUrl: url,
      title: title,
      author: author,
      items: items,
      parsedAt: DateTime.now(),
    );
  }

  Map<String, dynamic>? _extractEmbeddedJson(String html) {
    for (final key in ['__INIT_DATA__', 'window.__INITIAL_STATE__', '"itemDO"']) {
      final idx = html.indexOf(key);
      if (idx >= 0) {
        // 找到 key 后第一个 { 开始截取，尝试逐步扩展解析
        final start = html.indexOf('{', idx);
        if (start >= 0) {
          final candidate = html.substring(start);
          // 截到 </script> 前
          final end = candidate.indexOf('</script>');
          final raw = end > 0 ? candidate.substring(0, end) : candidate;
          try {
            return jsonDecode(raw.trim().endsWith(';')
                ? raw.substring(0, raw.length - 1)
                : raw) as Map<String, dynamic>;
          } catch (_) {
            // 不完整 JSON，尝试最小可解析片段
          }
        }
      }
    }
    return null;
  }

  void _collect(List<String> out, dynamic node, int depth) {
    if (depth > 8) return;
    if (node is Map) {
      for (final v in node.values) {
        _collect(out, v, depth + 1);
      }
    } else if (node is List) {
      for (final v in node) {
        _collect(out, v, depth + 1);
      }
    } else if (node is String) {
      if (RegExp(r'https?://img\.alicdn\.com/').hasMatch(node)) {
        out.add(node);
      }
    }
  }

  List<String> _collectImageUrls(Map<String, dynamic> json) {
    final out = <String>[];
    _collect(out, json, 0);
    return out;
  }
}
