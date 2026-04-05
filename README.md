<div align="center">

# Baka

**Next-Gen Anime Streaming Client | 次世代二次元番剧播放器**

![Flutter](https://img.shields.io/badge/Flutter-3.38%2B-blue?style=for-the-badge&logo=flutter)
[![Dart Version](https://img.shields.io/badge/Dart-%3E%3D3.0-blue?style=for-the-badge&logo=dart)](https://dart.dev)
[![FVM](https://img.shields.io/badge/FVM-Supported-cyan?style=for-the-badge&logo=flutter)](https://fvm.app)
[![Version](https://img.shields.io/badge/version-4.5.2-important?style=for-the-badge)](https://github.com/AniBakaBaka/AniBaka/releases)
</div>

<div align="center">
  <img src="https://img.shields.io/badge/Windows-0078D4?style=flat&logo=windows&logoColor=white" />
  <img src="https://img.shields.io/badge/Android-3DDC84?style=flat&logo=android&logoColor=white" />
  <img src="https://img.shields.io/badge/macOS-000000?style=flat&logo=apple&logoColor=white" />
  <img src="https://img.shields.io/badge/iOS-000000?style=flat&logo=apple&logoColor=white" />
  <img src="https://img.shields.io/badge/Android_TV-3DDC84?style=flat&logo=android&logoColor=white" />


[特性](#-✨特性) • [预览](#-预览) • [下载](#-下载与安装) • [反馈](#-反馈与支持) • [常见问题](#-常见问题)

</div>

---

## 📖 简介 | Introduction

**Baka** 是使用 Flutter 开发的支持多番剧源和弹幕的看番软件。完全兼容kazumi规则，也支持css规则，支持规则导入与规则分享，支持基于 Anime4K 的实时超分辨率，支持弹幕、投屏、硬件加速等超多功能。

> **注意**：本项目目前为闭源发行。本仓库主要用于**发布版本**、**用户反馈**以及**Bug 追踪**。


---

## ✨ 特性 | Features

### 🎨 极致 UI/UX
- **Glassmorphism 设计**: 全局采用现代化毛玻璃风格，适配深色/浅色模式，视觉通透，质感细腻。
- **桌面端优化**: 针对大屏深度适配。
- **平板优化**: 支持大屏幕UI变化。
- **主题切换**: 支持深色模式、浅色模式和跟随系统三种模式。
- **字体自定义**: 内置 Google Fonts 字体库，支持字体切换、字体缩放和字重调节
- **Android TV 适配**: 自动检测 TV 设备，强制横屏沉浸模式，遥控器友好操作。


### 🔌 开放生态
- **多源聚合**: 内置 Cycani, Gugu, Anime1, XiFanACG 等主流源，开箱即用。
- **自定义源**: 支持加载自定义 css/xpath 适配器，也就是kazumi编写好后的规则可以直接导入到 Baka 中，由于与kazumi实现方式不同，有些kazumi可以播放，但baka不能播放，需要进行微调。
- **聚合搜索**: 一搜索，全网有。不再需要在不同网站间反复横跳。
- **Kazumi 远程规则**: 支持从 GitHub 远程仓库拉取 Kazumi 规则列表，内置中国大陆镜像加速，一键导入即可使用。
- **智能反爬引擎**: 混合动力架构 —— Dio 极速模式 + WebView 隐身自动降级，自动绕过 Cloudflare、5秒盾等反爬机制。
- **验证码自动处理**: 内置雷池 WAF 验证码识别与 Cookie 持久化，部分源支持全自动验证码通过。
- **自定义源管理**: 提供完整的源管理界面，支持新建、编辑、启用/禁用、导出和导入源配置。支持 `baka://` 链接、`kazumi://` 链接和原始 JSON 格式导入
### 📺 播放器
- **mpv 内核**: 基于 `media_kit` (libmpv)，天然支持硬解，播放流畅。
- **Anime4K 实时增强**: 全端内置 Anime4K 算法，一键将 720p/1080p 提升至 4K 画质，老番画质拯救者。
- **智能弹幕**: 自动关联 BGM 弹幕库，支持弹幕渲染、发射、屏蔽与过滤。
- **系统媒体控制**: Android 通知栏 / iOS 锁屏 / macOS 控制中心原生媒体控制集成。
- **弹幕精细控制**: 支持调节弹幕字体大小、显示区域、滚动速度、透明度、描边宽度，支持按类型（顶部/底部/滚动）过滤，支持关键词屏蔽和重复弹幕过滤。
- **多线路切换**: 同一剧集支持多条播放线路，可自由切换。
- **倍速播放**: 支持调节播放速度，长按屏幕可临时倍速。
- **片头片尾跳过**: 可设置片头片尾的跳过时长和等待时间，自动跳过并支持撤销。
- **播放进度记忆**: 自动记录每集播放进度，再次打开时提示跳转到上次位置。
- **画面比例调整**: 支持多种画面填充模式切换。
- **手势控制**: 支持滑动手势调节亮度和音量。
### 📖 番剧资料
- **Bangumi 集成**: 自动关联 Bangumi（BGM）数据库，获取番剧评分、简介、标签、制作信息和收藏统计。
- **番剧详情页**: 查看番剧的完整信息，包括 Infobox（制作人员/声优）、用户标签云、收藏状态分布（想看/在看/看过/搁置/抛弃）。
- **新番更新表**: 按星期查看当季番剧的更新时间表。
- **排行榜**: 查看热门番剧排行，支持多种排行类型切换。

### 追番与历史
- **追番收藏**: 支持将番剧添加到个人收藏，按状态（想看/在看/看过等）分类管理。
- **观看历史**: 自动记录观看历史，支持从历史记录中快速续播。
- **数据同步**: 本地历史记录与远端双向同步，支持强制上传和合并策略，多端进度衔接。

### 🛠 极客功能
- **数据同步**: 本地历史记录与远端自动同步，多端进度无缝衔接。
- **下载管理**: 多线程并发下载引擎，断点续传。
- **媒体库**: 本地存储 + WebDAV 远程存储统一管理，支持浏览已下载的离线视频资源。
- **下载管理**: 支持视频缓存下载，断点续传，下载完成后自动保存弹幕文件，已下载视频支持离线播放（含弹幕）。
- **DLNA 投屏**: 自动搜索局域网中的 DLNA 设备，一键投射到电视。
- **缓存管理**: 支持查看和清理应用缓存。
- **社区讨论**: 内置讨论区，支持浏览和发表评论。

---

## 📸 预览 | Screenshots

###  桌面预览
<div align="center">
  <img src="https://free.picui.cn/free/2026/01/29/697b48a35ebc6.png" width="32%" alt="Desktop 1" />
  <img src="https://free.picui.cn/free/2026/01/29/697b48a60bb63.png" width="32%" alt="Desktop 2" />
  <img src="https://free.picui.cn/free/2026/01/29/697b48a49d434.png" width="32%" alt="Desktop 3" />
</div>
<div align="center" style="margin-top: 10px;">
  <img src="https://free.picui.cn/free/2026/01/29/697b48a4b2155.png" width="32%" alt="Desktop 4" />
  <img src="https://free.picui.cn/free/2026/01/29/697b48a5b3c28.png" width="32%" alt="Desktop 5" />
  <img src="https://free.picui.cn/free/2026/01/29/697b48a4b2bc2.png" width="32%" alt="Desktop 6" />
</div>
<div align="center" style="margin-top: 10px;">
  <img src="https://free.picui.cn/free/2026/01/29/697b48a953b74.png" width="32%" alt="Desktop 7" />
  <img src="https://free.picui.cn/free/2026/01/29/697b48aa35444.png" width="32%" alt="Desktop 8" />
  <img src="https://free.picui.cn/free/2026/01/29/697b48ab40135.png" width="32%" alt="Desktop 9" />
</div>

###  手机预览
<div align="center">
  <img src="https://free.picui.cn/free/2026/01/29/697b423584ece.jpg" width="30%" alt="首页" />
  <img src="https://free.picui.cn/free/2026/01/29/697b4235784a9.jpg" width="30%" alt="详情页" />
  <img src="https://free.picui.cn/free/2026/01/29/697b423542ae8.jpg" width="30%" alt="播放页" />
</div>
<br>
<div align="center">
  <img src="https://free.picui.cn/free/2026/01/29/697b42350ef2c.jpg" width="30%" alt="选集" />
  <img src="https://free.picui.cn/free/2026/01/29/697b4239beeac.jpg" width="30%" alt="我的" />
  <img src="https://free.picui.cn/free/2026/01/29/697b42352cfd7.jpg" width="30%" alt="设置" />
</div>

<div align="center">
  <img src="https://free.picui.cn/free/2026/01/29/697b423a08b85.jpg" width="45%" alt="播放器" />
  <img src="https://free.picui.cn/free/2026/01/29/697b423aca26e.jpg" width="45%" alt="弹幕播放" />
</div>
---

## 📥 下载与安装 | Download & Installation

### Windows
1. 前往 **[Releases](https://github.com/AniBakaBaka/AniBaka/releases)** 页面。
2. 下载最新的 `Baka_Setup.exe` (安装版) 或 `Baka_Windows_Portable.zip` (便携版)。
3. 安装或解压后直接运行 `Baka.exe`。

### Android
1. 前往 **[Releases](https://github.com/AniBakaBaka/AniBaka/releases)** 页面。
2. 下载最新的 `app-release.apk`。
3. 如果是首次安装，请允许浏览器或文件管理器安装未知来源应用。

### iOS / macOS
目前 iOS 版本暂未上架 App Store。
- **macOS**: 可载 `dmg` 镜像（如有发布）或等待后续签名版本。
- **iOS**: 暂只支持 TestFlight 内测或自签名安装（IPA文件将在 Release 中提供）。

---

## 💬 反馈与支持 | Feedback & Support

虽然我们目前不公开源代码，但我们非常重视社区的反馈。

### 🐛 Bug 报告
如果您在使用过程中遇到崩溃、闪退或功能异常，请在 [Issues](https://github.com/AniBakaBaka/AniBaka/issues) 中提交报告。
- 请务必注明您的**设备型号**、**系统版本**以及**复现步骤**。
- 如果是视频源问题，请注明是哪个**适配器**。

### 💡 功能建议
有很棒的想法？欢迎在 [Discussions](https://github.com/AniBakaBaka/AniBaka/discussions) 中提出您的建议。我们会在后续版本规划中认真考虑。

---

## ❓ 常见问题 | FAQ

**Q: 这个软件是免费的吗？**
A: 是的，Baka 目前完全免费供个人使用。

**Q: 为什么不开源？**
A: 还没想好是否开源，主要是代码库太乱了，还有一些历史原因，所以闭源比开源的风险小一些。后续star高些后可能会考虑开源。

**Q: 如何安装自定义源？**
A: 在设置页面的「自定义源管理」中，点击「导入」按钮，粘贴 JSON 配置文本即可。支持 `baka://` 链接、`kazumi://` 链接或原始 JSON 格式导入。也可以点击「新建源」手动填写 CSS/XPath 选择器来创建自定义源。


## 📜 致谢 | Credits

Baka 的诞生离不开以下优秀的开源项目：

- [Flutter](https://flutter.dev) - Google 的 UI 工具包
- [MediaKit](https://github.com/media-kit/media-kit) - 强大的视频播放架构
- [GetX](https://github.com/jonataslaw/getx) - 状态与路由管理
- [Hive](https://github.com/hivedb/hive) - 快速的本地数据库
- [Anime4K](https://github.com/bloc97/Anime4K) - 实时画质增强算法


## ⚠️ 免责声明 | Disclaimer

本项目仅作为一个流媒体播放工具，**不提供、不存储、不分发**任何视频内容。所有视频资源均来源于互联网第三方网站，本应用仅提供聚合搜索与播放功能，类似于浏览器。

开发者不对用户使用本软件产生的任何版权问题负责。如果您认为某个视频源侵犯了您的权益，**请联系该视频源网站进行处理**。

请于下载后 24 小时内删除，请勿用于任何商业用途。

---

<div align="center">
  <p>Made with ❤️ by the Baka Team</p>
</div>