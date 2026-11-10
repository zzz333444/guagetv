# 呱壳：云端编译 + SideStore 自签安装说明

全程不需要 Mac。需要：一台电脑（Windows 或 Mac，用一次，装 SideStore 用）、一个 GitHub 账号、你的 Apple ID。

## 第 1 步：把工程推上 GitHub 出 IPA
1. 登录 GitHub，新建一个**私有**仓库，名字随意，比如 `guagetv`。
2. 把本工程传上去：
   - 有电脑 + git：`git push` 本目录即可（本地已 init 并提交好）。
   - 只用网页：仓库页 → `uploading an existing file`，把工程里的文件按目录逐个传（共 9 个文件，保持目录结构）。
3. 打开仓库的 **Actions** 页，点 `build-unsigned-ipa` → **Run workflow**。
4. 跑完（约 5–10 分钟）后在该次运行底部下载产物 `GuageTV-unsigned.ipa`，里面是 `GuageTV-unsigned.ipa`。

## 第 2 步：装 SideStore（只装一次，要用电脑）
1. 电脑上装 AltServer（sidestore.io 有官方指引），iPhone 用数据线连电脑。
2. 通过 AltServer 把 **SideStore** 装进 iPhone。
3. iPhone 上：设置 → 通用 → VPN 与设备管理 → 信任你的 Apple ID 开发者证书；
   再到 设置 → 隐私与安全性 → 打开「开发者模式」（需重启一次）。
4. 打开 SideStore，按提示登录你的 Apple ID 并完成配对文件（jitterbugpair）生成——SideStore 官方安装向导会一步步带。

## 第 3 步：装呱壳
1. 把 `GuageTV-unsigned.ipa` 传到 iPhone（隔空投送 / 微信文件 / iCloud 都行）。
2. SideStore 里点 `+` → 选这个 IPA → 它会用你的 Apple ID 签名并安装。
3. 桌面出现「呱壳」即完成。

## 续签（重要）
- 免费 Apple ID 证书有效期 7 天。SideStore 开着后台刷新 + 连接同一 Wi-Fi 时会自动续签，一般无感。
- 若图标点开提示证书失效：打开 SideStore 点一次 Refresh All 即可，不要卸载（卸载会丢数据）。

## 已知边界
- 这条路出的 IPA 是**个人自用**性质，不能上架、不能分发给别人装（别人的设备签不了你的证书）。
- 阶段 1（内嵌 Python 真跑通）完成前，壳能导入配置、列站点，但 py 站点还点不开——那是下一阶段的活，不是装坏了。
