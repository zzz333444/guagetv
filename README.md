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

## 阶段
- [x] 阶段 0：工程骨架、配置解析、Python 桥协议、播放页骨架
- [ ] 阶段 1：接入 Python.xcframework，桥真跑通 homeContent
- [ ] 阶段 2：分类/列表/详情/搜索全链路 UI
- [ ] 阶段 3：选集播放、历史记录、直播源
