# 原存 · 去水印解析保存 App

支持 **小红书 / 微博 / 抖音 / X（推特）/ 闲鱼** 分享链接解析，保存 **原图 / 原视频 / Live 实况图**（非预览压缩版）。

> ⚠️ 合规提醒：解析与保存功能仅供个人学习、备份及保存本人有权使用的内容；
> 他人作品版权归原作者所有，请勿去除水印后二次分发或商用。

---

## 技术方案

| 层 | 选型 | 说明 |
|---|---|---|
| 跨端框架 | Flutter (Dart 3) | 一套代码出 iOS + Android |
| 解析层 | 纯 Dart HTTP | 手动跟随 30x 重定向展开短链，抓取 H5 页内嵌 JSON / 调详情接口 |
| 下载层 | 流式下载 | 边下边写盘，支持大视频，内存占用恒定；候选链 + 请求头阶梯回退 |
| 保存层 | Platform Channel | iOS: PHPhotoLibrary；Android: MediaStore |
| 去水印 | iOS 原生像素级 | 仅微博使用：顶帽检测白字 → PatchMatch 相干填充（详见下文） |

## 目录结构

```
media_saver/
├── pubspec.yaml
├── lib/
│   ├── main.dart                     # 入口
│   ├── models/parsed_media.dart      # 统一解析结果模型（含候选链 companionFallbackUrls）
│   ├── theme/app_theme.dart          # 设计 Tokens（颜色/字号/间距/圆角）
│   ├── services/
│   │   ├── http_util.dart            # 重定向展开 + 移动端 UA + 流式下载
│   │   ├── app_logger.dart           # 本地日志 + 失败自动上报 GitHub Issue
│   │   ├── parser_service.dart       # 平台识别与调度
│   │   ├── downloader.dart           # 流式下载（断点续传 + 候选链 + 请求头阶梯）
│   │   ├── douyin_capture.dart       # 抖音离屏 WebView 捕获（detail / DOM / 翻页）
│   │   ├── saver_channel.dart        # 原生保存通道封装
│   │   └── parsers/
│   │       ├── douyin_parser.dart      # SSR + detail + WebView 三路兜底
│   │       ├── xiaohongshu_parser.dart # __INITIAL_STATE__ → fileId 拼原图 / stream 取实况
│   │       ├── weibo_parser.dart       # m.weibo.cn show 接口 → large 原图 + mp4_720p
│   │       ├── twitter_parser.dart     # syndication/fxtwitter → name=orig + 最高码率 mp4
│   │       └── xianyu_parser.dart      # og:image + 内嵌 JSON（受限模式）
│   └── screens/
│       ├── home_screen.dart          # 粘贴链接解析首页
│       └── result_screen.dart        # 网格预览 + 保存（含视频预览页）
├── native/
│   ├── ios/AppDelegate.swift         # 【整体替换】Runner 的 AppDelegate：相册保存 + 实况合成 + 去水印
│   └── android/MainActivity.kt       # MediaStore 保存
└── docs/平台解析链路说明.md           # 逆向链路与维护指南（重点阅读）
```

## 各平台取流方案（当前实现）

| 平台 | 图片 | 视频 | 实况 |
|---|---|---|---|
| 小红书 | `imageList[i].fileId` → `sns-img-hw.xhscdn.com/{fileId}?imageView2/2/w/0/format/jpg`（**无水印原始上传**） | `media.video.media.stream` 最高档 + `consumer.originVideoKey` 原片 | `imageList[i].stream.h264[].masterUrl` + 静态帧原图 |
| 微博 | `large` 全分辨率原图（CDN 盖章水印 → 原生去水印） | `mp4_720p` / `f.video.weibocdn.com` | `type=livephoto` + `videoSrc` |
| 抖音 | 图集 `images[i].url_list` 无水印档 | ① 分享页 SSR `_ROUTER_DATA` ② WebView 捕获 detail（带 UIFID cookie）③ 桌面页 `note/{id}` 上下文 fetch ④ 分享页 detail 兜底 | `aweme_type=68 / media_type=42` → 每张图 `images[i].video.play_addr` 是实况视频；BGM 走 `music.play_url` 由原生合成 |
| X（推特） | `name=orig` | 最高码率 mp4 | GIF → 真 Live |

### 小红书：为什么必须用 fileId

笔记页给的是 **H5 带水印版**（`sns-webpic-qc/…/{日期}/{hash}/notes_pre_post/{fileId}!h5_1080jpg`，
1080px、正中压制「小红书」水印）。同一 `fileId` 在图片 CDN 根路径上是**原始上传文件**
（2160px、1.8MB、无水印）。`fileId` 字段新老页面都稳定存在，且就是 CDN 相对路径，
比从 H5 地址里反推日期/hash 前缀可靠。

### 微博：去水印算法（v10，2026-11-11）

微博水印由 CDN 在 `large/original/woriginal` 等所有档位上统一烧录，**没有无水印直链**
（`oslarge` 例外，但只有 ~690px），只能像素级还原：

1. **检测**：`lum − opening(lum, r)`（顶帽）。开运算抹掉比结构元细的亮结构，
   剩下的就是背景下包络；差值即细亮笔画强度。除以 `255 − 背景` 得"白字覆盖率 α"，
   只处理 α 足够大的像素 —— 白字压白底本来就看不见，留着察觉不到，不必去改画面。
   > 旧版用「比 9px 局部中值亮 margin」判断，在白发/白裙/白墙等高亮背景下
   > 白字与背景亮度几乎相同 → 判不出来 → 残留白色字块（用户反馈的"涂抹感"）。
2. **形态过滤**：4 邻接连通域，按字号（行高）筛掉噪点与大片高光。
3. **填充**：`coherentPatchFillROI`（PatchMatch 相干复制，rounds 4 / search 96）拷真实纹理，
   掩码过大时退回洋葱扩散。第二遍用弱阈值复扫残影。
4. 任一步不确定（无水印 / 白色内容过多 / GIF / 解码失败 / 修补后整体接近纯白）都原样保存，不做破坏。

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

# 1) 用 native/ios/AppDelegate.swift 【整体替换】 ios/Runner/AppDelegate.swift
# 2) 用 native/android/MainActivity.kt 替换 android 对应包路径下的 MainActivity.kt
# 3) ios/Runner/Info.plist 增加相册权限描述：
#    <key>NSPhotoLibraryAddUsageDescription</key>
#    <string>用于将解析的图片、视频和实况照片保存到你的相册</string>

flutter build ipa --release --no-codesign   # 巨魔安装无需签名
```

### 巨魔侧载步骤

1. 打包出的 `Runner.app` 用 Finder/压缩工具打成 `Payload/Runner.app` → 改名 `Runner.ipa`（未签名即可）
2. 把 ipa 传到 iPhone（AirDrop/网盘均可），在巨魔商店（TrollStore）中打开安装
3. 无需开发者账号、无需签名、7 天不过期

## 功能与状态

| 能力 | 抖音 | 小红书 | 微博 | X（推特） | 闲鱼 |
|---|---|---|---|---|---|
| 原图（原始分辨率） | ✅ 图集 | ✅ fileId 原图（无水印） | ✅ large 原图 + 原生去水印 | ✅ name=orig | ⚠️ 仅主图 |
| 无水印原视频 | ✅ 原画 | ✅ originVideoKey / 最高档 | ✅ 1080p 优先 | ✅ 最高码率 mp4 | ❌ |
| Live 实况图 | ✅ 图 + 配对视频（含 BGM 合成） | ✅ 图 + `stream` 视频轨 | ✅ type=livephoto + videoSrc | ✅ GIF 转真 Live | ❌ |

## 已知限制

- **微博**：水印是 CDN 烧录的，去水印本质是"检测 + 内容感知填充"，
  水印压在强纹理/人脸细部时会有轻微模糊；检测不到时原样保存，绝不乱涂。
- **小红书实况视频轨**：平台侧视频轨本身可能带水印（XHS-Downloader 同样标注），
  静态帧是无水印原图。
- **抖音**：`slides` 分享路径需转 `www.douyin.com/note/{id}`；detail 接口必须带页面
  cookie（UIFID）才 200，捕获链路靠离屏 WebView 注入，冷启动首帧可能较慢。
- 平台接口会不定期变更，字段失效时参照 `docs/平台解析链路说明.md` 用 mitmproxy 抓包更新。

## 变更记录

- **v1.2.0 (build 114)**
  - 小红书：实况图改读 `imageList[i].stream`（新版 H5 已无 `livePhotoUrl` 字段，
    旧逻辑永远判成普通图片 → "live 图提取不到"）；普通图统一用 `fileId` 拼无水印原图。
  - 微博：去水印检测换为顶帽 + α 覆盖率（修高亮背景下白字残留），PatchMatch 参数增强。
  - 抖音：slides 作品（`aweme_type=68`）不再被识别成照片 —— 去视口过滤、detail 注入
    延长到 15s、新增分享页 detail 兜底。
- **v1.2.0 (build 112)** 抖音"全解析错目标"：视口过滤推荐流 + detail 作品 ID 校验 + 严格配对。
- **v1.2.0 (build 110)** 微博去水印主路径升级为像素级检测 + 真实纹理填充。
