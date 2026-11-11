# 原存 · 去水印解析保存 App

支持 **小红书 / 微博 / 抖音 / X（推特）/ 闲鱼** 分享链接解析，保存 **原图 / 原视频 / Live 实况图**（非预览压缩版）。

> ⚠️ 合规提醒：解析与保存功能仅供个人学习、备份及保存本人有权使用的内容；
> 他人作品版权归原作者所有，请勿去除水印后二次分发或商用。

---

## 技术方案

| 层 | 选型 | 说明 |
|---|---|---|
| 跨端框架 | Flutter (Dart 3) | 一套代码出 iOS + Android |
| 解析层 | 纯 Dart HTTP | 手动跟随 30x 重定向展开短链，抓取 H5 页内嵌 JSON |
| 下载层 | 流式下载 | 边下边写盘，支持大视频，内存占用恒定 |
| 保存层 | Platform Channel | iOS: PHPhotoLibrary；Android: MediaStore |
| Live Photo | PHAssetCreationRequest | 三级回退：直接合成 → **元数据注入转换后合成**（AVAssetReader/Writer 注入 content.identifier + StillImageTime，支持推特 GIF 转 Live）→ 降级分开保存 |

## 目录结构

```
media_saver/
├── pubspec.yaml
├── lib/
│   ├── main.dart                     # 入口
│   ├── models/parsed_media.dart      # 统一解析结果模型
│   ├── theme/app_theme.dart          # 设计 Tokens（颜色/字号/间距/圆角）
│   ├── services/
│   │   ├── http_util.dart            # 重定向展开 + 移动端 UA + 流式下载
│   │   ├── parser_service.dart       # 平台识别与调度
│   │   ├── downloader.dart           # 原文件流式下载（含 Referer 处理）
│   │   ├── saver_channel.dart        # 原生保存通道封装
│   │   └── parsers/
│   │       ├── douyin_parser.dart    # _ROUTER_DATA → playwm→play 去水印
│   │       ├── xiaohongshu_parser.dart # __INITIAL_STATE__ → imageList/livePhotoUrl
│   │       ├── weibo_parser.dart     # m.weibo.cn show 接口 → large 原图 + mp4_720p
│   │       ├── twitter_parser.dart   # syndication/fxtwitter → name=orig 原图 + 最高码率 mp4 + GIF→Live
│   │       └── xianyu_parser.dart    # og:image + 内嵌 JSON（受限模式）
│   └── screens/
│       ├── home_screen.dart          # 粘贴链接解析首页
│       └── result_screen.dart        # 网格预览 + 保存（含视频预览页）
├── native/
│   ├── ios/AppDelegate.swift             # 替换 Runner 的 AppDelegate
│   └── ios/AppDelegate.swift             # AppDelegate + 相册保存 + Live Photo 合成（单文件）
│   └── android/MainActivity.kt           # MediaStore 保存
└── docs/平台解析链路说明.md              # 逆向链路与维护指南（重点阅读）
```

## 构建与巨魔（TrollStore）安装

### 方式一：GitHub Actions 云端构建（无 Mac 首选）

项目已内置 `.github/workflows/build.yml`，全自动出包（含原生代码注入与权限配置）：

1. 把整个 `media_saver/` 文件夹推到一个 GitHub 仓库（私有即可）
2. 仓库页 → **Actions** → 选 **build** → **Run workflow**
3. 跑完后在该次运行页面下载产物：
   - `media_saver_ios_ipa` → 未签名 IPA（巨魔可直接装）
   - `media_saver_apk` → Android 安装包
4. IPA 传到 iPhone（AirDrop/网盘），在巨魔商店中打开安装

### 方式二：本地构建（需 macOS + Xcode 15+）

```bash
cd media_saver
flutter create . --org com.mediastack --project-name media_saver --platforms ios,android

# 1) 用 native/ios/AppDelegate.swift 【整体替换】 ios/Runner/AppDelegate.swift（插件已合并在内，无需再加其他 Swift 文件）
# 3) 用 native/android/MainActivity.kt 替换 android 对应包路径下的 MainActivity.kt
# 4) ios/Runner/Info.plist 增加相册权限描述：
#    <key>NSPhotoLibraryAddUsageDescription</key>
#    <string>用于将解析的图片、视频和实况照片保存到你的相册</string>

flutter build ipa --release --no-codesign   # 巨魔安装无需签名
# 产物：build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app
```

### 巨魔侧载步骤

1. 打包出的 `Runner.app` 用 Finder/压缩工具打成 `Payload/Runner.app` → 改名 `Runner.ipa`（未签名即可）
2. 把 ipa 传到 iPhone（AirDrop/网盘均可），在巨魔商店（TrollStore）中打开安装
3. 无需开发者账号、无需签名、7 天不过期 —— 这类解析工具也因此不必走 App Store 审核

## 功能与状态

| 能力 | 抖音 | 小红书 | 微博 | X（推特） | 闲鱼 |
|---|---|---|---|---|---|
| 原图（原始分辨率） | ✅ 图集 | ✅ | ✅ large 原图 | ✅ name=orig | ⚠️ 仅主图 |
| 无水印原视频 | ✅ **原画**（App feed 接口，H5 兜底） | ✅ avg_bitrate 最高档 | ✅ 1080p 优先 | ✅ 最高码率 mp4 | ❌ |
| Live 实况图 | ✅ 图+配对视频 | ✅ livePhotoUrl（视频轨含水印，平台限制） | ✅ type=livephoto + videoSrc（已验证） | ✅ GIF 转真 Live | ❌ |

> 平台接口会不定期变更/加风控，字段失效时参照 `docs/平台解析链路说明.md` 用 mitmproxy 抓包更新。
> 小红书与微博的免登录方案已对照 GitHub 开源项目（xiaohongshu-cli、XHS-Downloader、
> weibo-crawler 系实现）验证：小红书匿名读 SSR 页面 + 分享链接自带 xsec_token；
> 微博移动端 UA 直连 + 被拒时访客系统自动换 SUB/SUBP，均无需用户登录。

## 上线须知

1. **巨魔/自用路线（推荐，当前项目即为此设计）**：免签侧载，无审核问题。
2. **App Store 审核**：此类应用极易被拒（Guideline 5.2.2 / 4.0），不建议走此路线。
3. **风控维护**：抖音与小红书对无 Cookie 请求有概率返回风控页，生产环境建议
   内置可更新的规则配置（接口地址 + 字段路径热更新），避免每次改字段都发版。
4. **闲鱼完整方案**：需 App 内嵌 WebView 打开商品页并拦截资源加载，见链路文档，属 P2 迭代。
