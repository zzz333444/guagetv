# 呱壳 GuageTV（iOS 版 TVBox 壳）

目标：iOS 上能加载 TVBox 配置、能跑 Python Spider（.py 源）的播放器壳，最终产物 IPA。

## 硬约束（先说清）
- 编 IPA 必须 macOS + Xcode，本工程在 Linux 上只能写、不能编。
- IPA 装到手机必须签名：个人用走 SideStore/AltStore + 自己 Apple ID（免费证书，SideStore 可自动续签），或付费开发者账号。
- 内嵌 Python 用 python-apple-support 的 Python.xcframework；壳本身不带任何内容源。

## 架构
- `GuageTV/Sources/ConfigLoader.swift`：解析 TVBox 配置 JSON（spider / sites / lives / parses）。
- `GuageTV/Sources/SpiderBridge.swift`：Swift ↔ Python 桥。把 Spider 的 13 个接口统一成 JSON 进 / JSON 出。
- `GuageTV/Python/spider_runner.py`：Python 侧执行器。加载用户 .py 文件里的 `class Spider`，按接口名调用，异常兜底，返回 JSON 字符串。
- `GuageTV/Sources/PlayerView.swift`：AVPlayer 播放页（m3u8/mp4 原生支持，可带 header）。

## 构建路线（二选一）
1. **云端编译**：把本工程推到 GitHub，`.github/workflows/build.yml` 用 macOS runner 出未签名 IPA，再用 SideStore 在手机上以自己的 Apple ID 签名安装。
2. **本地 Mac**：装 XcodeGen → `xcodegen generate` → Xcode 打开构建。

## 规则支持矩阵（目标）
| 规则 | 运行时 | 状态 |
|---|---|---|
| TVBox 配置 JSON（sites/lives/parses/flags/ads/doh） | 原生解析 | 阶段 0 已全字段 |
| CMS 站 type 0/1（XML/JSON 采集接口） | 原生请求 | 阶段 2 |
| Python Spider（type 3 .py） | 内嵌 CPython + spider_runner | 桥已验通，阶段 1 接运行时 |
| JS Spider（type 3 .js） | JavaScriptCore 桥 | 阶段 2 |
| drpy（type 4） | 同 JS 引擎 + drpy 运行时 | 阶段 2 |
| 猫源（CatPawOpen 配置+JS spider） | MaoYuanAdapter 转换 + JS 引擎 | 适配器已写，阶段 2 |
| 直播 lives（m3u/txt + EPG） | 原生解析 + AVPlayer | 阶段 3 |
| **Jar Spider（csp_ / .jar）** | **无 JVM，iOS 系统级不支持** | **不支持（平台限制）** |

## UI（参考 Rex，源自用户提供的实机录屏）
Rex 设计语言已拆解并落进 `Theme.swift` 及各视图：
- 环境光背景：当前内容海报高斯模糊后铺底染色；全屏毛玻璃卡片（ultraThinMaterial + 20 圆角）
- 悬浮胶囊底栏：发现 / 我的 / 资源库 / 设置 一颗毛玻璃胶囊 + 右侧独立圆形搜索钮
- 发现页：全幅 Hero 轮播（大标题、类型·年份、评分行、圆点指示器）+ 分区横滑海报行（正在热映/电影/电视剧/综艺/动漫）+ 分类浏览
- 资源库页：双列源卡片（图标、名称、主线路、类型、电量式状态点）
- 我的页：周日历条 + 今日观看时长卡 + 历史观看热力格 + 收藏/在看/待看计数卡
- 设置页：快捷瓷砖（播放/音画/操控/字幕）+ 毛玻璃分组列表

## 阶段
- [x] 阶段 0：工程骨架、配置解析、Python 桥协议、播放页骨架
- [ ] 阶段 1：接入 Python.xcframework，桥真跑通 homeContent
- [ ] 阶段 2：分类/列表/详情/搜索全链路 UI + CMS 原生 + JS/drpy/猫源
- [ ] 阶段 3：选集播放、历史记录、直播源
