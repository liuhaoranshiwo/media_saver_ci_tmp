import '../models/parsed_media.dart';
import 'parsers/douyin_parser.dart';
import 'parsers/xiaohongshu_parser.dart';
import 'parsers/weibo_parser.dart';
import 'parsers/xianyu_parser.dart';
import 'parsers/twitter_parser.dart';

/// 解析调度器：识别链接所属平台，路由到对应解析器
class ParserService {
  static final _parsers = <ParsePlatform, MediaParser>{
    ParsePlatform.douyin: DouyinParser(),
    ParsePlatform.xiaohongshu: XiaohongshuParser(),
    ParsePlatform.weibo: WeiboParser(),
    ParsePlatform.xianyu: XianyuParser(),
    ParsePlatform.twitter: TwitterParser(),
  };

  static ParsePlatform detect(String url) {
    final u = Uri.tryParse(url);
    if (u == null || u.host.isEmpty) return ParsePlatform.unknown;
    final host = u.host.toLowerCase();
    if (host.contains('douyin.com') || host.contains('iesdouyin.com')) {
      return ParsePlatform.douyin;
    }
    if (host.contains('xiaohongshu.com') ||
        host.contains('xhslink.com') ||
        host.contains('xhslink.cn')) {
      return ParsePlatform.xiaohongshu;
    }
    if (host.contains('weibo.com') || host.contains('weibo.cn')) {
      return ParsePlatform.weibo;
    }
    if (host.contains('goofish.com') || host.contains('idle.fish') ||
        host.contains('taobao.com') || host.contains('2taobao.net')) {
      return ParsePlatform.xianyu;
    }
    // X（推特）：x.com / twitter.com / 短链 t.co / 各类镜像域名
    if (host == 'x.com' ||
        host.endsWith('.x.com') ||
        host.contains('twitter.com') ||
        host.contains('fxtwitter.com') ||
        host.contains('fixupx.com') ||
        host == 't.co' ||
        host.endsWith('.t.co')) {
      return ParsePlatform.twitter;
    }
    return ParsePlatform.unknown;
  }

  /// 入口：传入分享文本（可能含文案+短链），返回解析结果
  static Future<ParseResult> parse(String shareText) async {
    final url = HttpUtilExtract.extractUrl(shareText);
    if (url == null) {
      throw ParseException('未在输入中找到链接，请粘贴完整的分享文案');
    }
    final platform = detect(url);
    if (platform == ParsePlatform.unknown) {
      throw ParseException('暂不支持该链接：仅支持小红书 / 微博 / 抖音 / 闲鱼 / X 分享链接');
    }
    return _parsers[platform]!.parse(url);
  }
}

/// 避免循环依赖的简单别名（复用 HttpUtil.extractUrl）
class HttpUtilExtract {
  static String? extractUrl(String text) {
    final m = RegExp(r'https?://[^\s，。,;；\u4e00-\u9fa5]+').firstMatch(text);
    return m?.group(0);
  }
}

abstract class MediaParser {
  Future<ParseResult> parse(String url);
}
