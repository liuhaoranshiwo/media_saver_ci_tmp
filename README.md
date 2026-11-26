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

### 抖音：作者主页作品抓取（build 121，2026-11-26）

识别 `/user/{sec_uid}` 主页链接（作品分享 URL query 里的 `sec_uid` 不算），
复用离屏 WebView 走桌面 `www.douyin.com/user/{secUid}` 页：

- **数据源**：页面自己发出的 `aweme/v1/web/aweme/post/` 响应（带 a_bogus 签名、
  含完整 `bit_rate` 10 档 / `play_addr` / `music` / `images`，与 detail 结构一致），
  hook 截获 + 按 `aweme_id` 去重累加。
- **翻页只能靠滚动**：自建 fetch 翻页已删除。实测页面发出的 `a_bogus` 是 184 字符、
  与完整参数强绑定；重放同 URL / `frontierSign` 重新签名 / 改 `max_cursor` / 去签名，
  **5 种变体全部返回 846KB HTML 风控页**，拿不到 JSON。
- **滚动容器定位（v4）**：桌面页 `body{overflow-y:hidden}`，
  `documentElement`/`body` 的 `scrollHeight == clientHeight`、`window.scrollY` 恒 0
  → `window.scrollBy` 完全无效。真正可滚的是**混淆类名容器**
  （作品网格 `div.yP5MkONE` + `route-scroll-container`），故 v4 用
  已知选择器快路 + **BFS 遍历（跳过叶子节点，budget 420）**+ `__capCands` 缓存；
  DFS 会失败（`body.children.length == 173`，预算被尾部叶子节点吃光）。
  滚到已知底部时先回弹 260px 再滚到底（同值赋值不产生 scroll 事件）。
- **匿名（未登录）**：服务端直接返回空列表
  `{"aweme_list":[],"has_more":0,"not_login_module":{...}}`，页面根本不会翻页
  → 必须登录。结果页提示"已抓取最近 20 件（作者共 N 件），扫码登录后可抓取全部"。
- **登录态**：首页原地扫码（离屏 WebView 取码 → `Image.memory` 原生渲染）→
  按原链接重新抓取，滚动到 `has_more=false` 全量。
- **抓全判定**：抓到的数量 < 作者总数 → 提示"未能抓全"并给重抓按钮；
  达到总数 → 提示"已抓取该作者全部 N 件作品"且不再显示重抓按钮。
  （不再依赖 `has_more`，避免被 `maxIdle` 截断却无任何提示的静默少给。）
- 每条作品复用单作品解析逻辑（`_extractItems`）：图集/实况/BGM 合成/多清晰度档位全部一致。

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
| 作者主页全部作品 | ✅ 登录后全量（滚动 v4 定位混淆容器，抓全/未抓全均有明确提示） | ❌ | ❌ | ❌ | ❌ |

## 已知限制

- **微博**：水印是 CDN 烧录的，去水印本质是"检测 + 内容感知填充"，
  水印压在强纹理/人脸细部时会有轻微模糊；检测不到时原样保存，绝不乱涂。
- **小红书实况视频轨**：平台侧视频轨本身可能带水印（XHS-Downloader 同样标注），
  静态帧是无水印原图。
- **抖音**：`slides` 分享路径需转 `www.douyin.com/note/{id}`；detail 接口必须带页面
  cookie（UIFID）才 200，捕获链路靠离屏 WebView 注入，冷启动首帧可能较慢。
- **抖音作者主页**：2026-11-26 起匿名已拿不到作品列表（服务端直接返回空体），
  必须先在首页扫码登录抖音；登录一次后 cookie 长期有效，之后直接从首页粘贴链接即可。
  **必须靠滚动加载，不能自建 fetch 翻页**（`a_bogus` 与完整参数强绑定，
  重放/重签/改参全部落到风控 HTML）；滚动驱动靠 BFS 定位混淆类名容器，
  平台改混淆规则时需重新探测容器。
  抓取耗时随作品数线性增长（每件作品解析到媒体项，128 件约 40~90s）。
- 平台接口会不定期变更，字段失效时参照 `docs/平台解析链路说明.md` 用 mitmproxy 抓包更新。

## 变更记录

- **v1.2.0 (build 121)**
  - 抖音作者主页**作品爬不全**修复：定位并修掉两个真 bug
    - ① `window.scrollBy` / `document.scrollingElement` **完全无效**
      —— 实测 `body{overflow-y:hidden}`，`scrollHeight == clientHeight == 900`，
      `window.scrollBy(0,2600)` 后 `window.scrollY` 仍为 0；v3 却把它们当主力兜底
      → 页面实际一下都没滚
    - ② 真容器是**混淆类名** `div.yP5MkONE`（作品网格）+ `route-scroll-container`
      —— v3 的 `[class*="scroll"]/[class*="list"]` 只命中后者，漏掉装作品卡片的网格
    - v4 定位策略：已知选择器快路 + BFS（**跳过叶子节点**，budget 420）
      + `__capCands` 缓存（`isConnected` 校验）；滚到已知底部先回弹 260px 再滚到底
    - 实测（390×844 视口直接跑脚本）：`cands:2 moved:2 tops:["366/366","57/57"]`
      → 第 2 轮 `tops:["366/366","105/105"]`（页面确实在追加）→ 第 3 轮 `moved:0`
    - 预算放宽：`budget 150→240s`、`maxIdle 6→8`、`maxItems 600→800`、匿名 `25→20s`
  - 删除自建 fetch 翻页死代码（`_pullPostsJs`）：5 种签名变体全部返回 846KB 风控页
  - 修静默少给：截断提示不再依赖 `has_more`，改判「已抓 < 作者总数」→ 提示重抓；
    抓全时提示「已抓取该作者全部 N 件作品」且隐藏重抓按钮
- **v1.2.0 (build 120)**
  - 抖音登录改为**首页原地扫码**（不再跳整页登录页）
    - 原因：抖音桌面登录弹窗实测宽约 620px，390pt 窄屏下二维码右侧被裁、
      标题被压，且要退出页面才能回首页，操作被打断
    - 方案：离屏 WebView 加载 `www.douyin.com/user/self`（桌面 UA 匿名访问
      会自动弹扫码面板，实测免点击）→ 注入 hook 抓面板里的
      `data:image/png;base64` 二维码 → Flutter `Image.memory` 原生渲染
    - 面板自己轮询 `check_qrconnect`；App 侧每 2s 查 cookie
      (`sessionid`/`sid_guard`) + 页面 JS 双通道确认，命中即自动关窗继续解析
    - 首页新增常驻「登录抖音（扫码）」卡片与右上角入口；已登录可换号
      （换号先清登录 cookie，否则 `/user/self` 直接进个人主页不出码）
    - 解析命中"需要登录"时**自动弹码**，扫完自动重试原链接（只自动弹一次）
- **v1.2.0 (build 119)**
  - 抖音主页：**必须登录**（2026-11-26 实测平台已对匿名关闭作品列表）
    - 桌面 `aweme/post` 匿名返回 `{"aweme_list":[],"has_more":0,
      "not_login_module":{"guide_login_tip_exist":true}}`（1027B 空体）
    - 移动 v2 匿名仅 6 条、条目无 `play_addr`、翻页 `status_code 11110 shark_fail_1`
    - 新增：识别到"需要登录"时首页错误区直接给「登录抖音后重试」按钮，
      扫码成功自动重新解析（不再出现"解析失败且无入口"）
  - 新版桌面页已无 `_ROUTER_DATA`（只有不含作者信息的 `RENDER_DATA`）→
    作者昵称/作品数改从移动分享页 `userInfoRes.user_info` 读取（先加载移动页再切桌面）
  - 滚动驱动 v3：修掉 v2 遍历全 DOM（`div,section,main`）导致的 layout 风暴
    （真机 WebView 卡死/JS 超时），只操作 window + scrollingElement + ≤12 个候选容器
  - 匿名时只探测 25s（服务端必返回空），不空等 150s；空结果写入诊断日志
- **v1.2.0 (build 118)**
  - 抖音主页抓取调优（真机反馈"抓不全"）：
    - 滚动驱动升级：`scrollBy` 不触发 wheel 事件（探测的翻页请求是真实滚轮
      输入触发的）→ 改派发 `WheelEvent` + 可滚动容器滚到底回弹 + 点"加载更多"，
      一轮内双次滚动
    - 每轮等待 6→8s、空转容忍 4→6 轮、预算 100→150s（128 件 ≈ 7 页）
    - 抓取前读 cookie 记录登录态日志（区分"没登录"与"登录但翻页失效"）
    - 提示条区分场景：未登录 → "登录后抓取全部"；已登录中断 → "重新抓取"，
      重抓按钮自动检测登录态分流（已登录不再重复弹扫码页）
- **v1.2.0 (build 117)**
  - 新功能：**抖音作者主页全部作品抓取**。识别 `/user/{sec_uid}` 链接，
    桌面主页 hook 截获 `aweme/post` 响应（签名请求、bit_rate/play_addr/music/images
    完整，与 detail 结构一致），免签 fetch + 滚动双驱动翻页。
    匿名锁 20 条（探测实测），结果页提示并内置扫码登录页（轮询 `sessionid`
    自动返回）→ 登录后按原链接重抓全量到 `has_more=false`。
  - 结果页重构：`CustomScrollView + SliverGrid` 惰性构建（主页结果可达数百项），
    AppBar 增加"全选/清空"。
- **v1.2.0 (build 116)**
  - 小红书：实况图改读 `imageList[i].stream`（新版 H5 已无 `livePhotoUrl` 字段，
    旧逻辑永远判成普通图片 → "live 图提取不到"）；普通图统一用 `fileId` 拼无水印原图
    （实测 4 条笔记候选 #0 全部 200，体积是 H5 版 3~5 倍）。
  - 微博：去水印检测换为顶帽 + α 覆盖率（修高亮背景下白字残留）。
    真图调参结论：α 阈值 **0.35**、结构元 **lineH/14** —— 0.15 会把格纹高光选进来，
    `lineH/8` 结构元反而更差。回归样本见 `docs/samples/`。
  - 抖音：slides 作品（`aweme_type=68`）不再被识别成照片 —— 去视口过滤、detail 注入
    延长到 15s、新增分享页 detail 兜底。
- **v1.2.0 (build 112)** 抖音"全解析错目标"：视口过滤推荐流 + detail 作品 ID 校验 + 严格配对。
- **v1.2.0 (build 110)** 微博去水印主路径升级为像素级检测 + 真实纹理填充。
