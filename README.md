<div align="center">
  <img src="assets/ic_launcher.png" width="128" alt="Baka" />

# Baka

跨平台番剧聚合、媒体播放与弹幕客户端

[![Flutter](https://img.shields.io/badge/Flutter-3.44.9-02569B?logo=flutter&logoColor=white)](https://flutter.dev/)
[![Dart](https://img.shields.io/badge/Dart-%3E%3D3.8%20%3C%3D4.0-0175C2?logo=dart&logoColor=white)](https://dart.dev/)
[![Release](https://img.shields.io/github/v/release/AniBakaBaka/AniBaka?logo=github)](https://github.com/AniBakaBaka/AniBaka/releases)
[![CI](https://github.com/AniBakaBaka/AniBaka/actions/workflows/dart.yml/badge.svg)](https://github.com/AniBakaBaka/AniBaka/actions/workflows/dart.yml)
[![Downloads](https://img.shields.io/github/downloads/AniBakaBaka/AniBaka/total?logo=github)](https://github.com/AniBakaBaka/AniBaka/releases)
[![Stars](https://img.shields.io/github/stars/AniBakaBaka/AniBaka?style=flat&logo=github)](https://github.com/AniBakaBaka/AniBaka/stargazers)
[![License](https://img.shields.io/badge/License-GPLv3-blue.svg?logo=gnu&logoColor=white)](LICENSE)

<br/>

<img src="https://img.shields.io/badge/Windows-0078D4?logo=windows&logoColor=white" alt="Windows" />
<img src="https://img.shields.io/badge/Android-3DDC84?logo=android&logoColor=white" alt="Android" />
<img src="https://img.shields.io/badge/macOS-000000?logo=apple&logoColor=white" alt="macOS" />
<img src="https://img.shields.io/badge/iOS-000000?logo=apple&logoColor=white" alt="iOS" />
<img src="https://img.shields.io/badge/Android_TV-3DDC84?logo=androidtv&logoColor=white" alt="Android TV" />

</div>

## 简介

Baka 是使用 Flutter 开发的多端媒体客户端，通过规则驱动的视频源系统完成搜索、详情和播放解析，并提供弹幕、字幕、离线缓存、投屏及本地媒体库等功能。

本仓库包含完整源代码。Baka 本身不托管、不上传、不存储或分发视频内容，规则所访问的内容及服务由对应第三方提供。

## 功能

- 规则驱动的视频源、规则订阅库和自定义规则
- 基于 `media_kit` 的播放器，支持选集、换源、倍速、字幕和播放进度
- 弹幕加载、发送、屏蔽与本地弹幕文件
- MP4/HLS 离线缓存及下载任务管理
- Magnet、Torrent 下载与边下边播
- DLNA 投屏
- 本地文件夹和 WebDAV 媒体库
- 本地播放历史及登录后的历史同步
- Windows、Android、macOS、iOS 和 Android TV 界面
- Windows Anime4K 实时画质增强

内置规则随应用打包，社区规则由
[AniBakaRule](https://github.com/AniBakaBaka/AniBakaRule) 维护并通过规则中心获取。

## 界面预览

### 桌面端

<div align="center">
  <img src="https://free.picui.cn/free/2026/01/29/697b48a35ebc6.png" width="32%" alt="Baka 桌面端首页" />
  <img src="https://free.picui.cn/free/2026/01/29/697b48a60bb63.png" width="32%" alt="Baka 桌面端详情页" />
  <img src="https://free.picui.cn/free/2026/01/29/697b48a49d434.png" width="32%" alt="Baka 桌面端播放页" />
</div>

### 移动端

<div align="center">
  <img src="https://free.picui.cn/free/2026/01/29/697b423584ece.jpg" width="30%" alt="Baka 移动端首页" />
  <img src="https://free.picui.cn/free/2026/01/29/697b4235784a9.jpg" width="30%" alt="Baka 移动端详情页" />
  <img src="https://free.picui.cn/free/2026/01/29/697b423542ae8.jpg" width="30%" alt="Baka 移动端播放页" />
</div>

## 下载

预构建版本发布在 [GitHub Releases](https://github.com/AniBakaBaka/AniBaka/releases)。请根据系统和 CPU 架构选择对应安装包。

iOS 构建产物未签名，需要自行签名后安装。不同系统的发行包和签名状态以具体 Release 说明为准。

Windows 发行产物使用 [SignPath.io](https://signpath.io/) 完成代码签名，证书由 [SignPath Foundation](https://signpath.org/) 提供。

Free code signing on Windows is provided by [SignPath.io](https://signpath.io/), with a certificate issued by the [SignPath Foundation](https://signpath.org/).

## 从源码运行

### 环境要求

- Flutter `3.44.9`，项目通过 `.fvmrc` 固定版本，建议使用 [FVM](https://fvm.app/)
- Dart `>=3.8.0 <=4.0.0`
- 对应目标平台的 Flutter 桌面或移动端开发工具链
- Android 构建需要 JDK 17 和 Android SDK 36

### 获取并运行

```bash
git clone https://github.com/AniBakaBaka/AniBaka.git
cd AniBaka
fvm install
fvm flutter pub get
fvm flutter run
```

不使用 FVM 时，请确保当前 Flutter 版本与 `.fvmrc` 一致，然后将命令中的 `fvm` 前缀移除。

### 构建

```bash
# Android
fvm flutter build apk --release

# Windows
fvm flutter build windows --release

# macOS
fvm flutter build macos --release

# iOS（无签名）
fvm flutter build ios --release --no-codesign
```

仓库的 GitHub Actions 使用 [Fastforge](https://fastforge.dev/) 生成多平台发行包，配置见 `distribute_options.yaml`。

## 开发与测试

```bash
fvm flutter analyze
fvm flutter test
```

真实站点规则测试默认跳过。需要联网验证规则时运行：

```bash
fvm flutter test test/source/live_new_rules_test.dart --dart-define=LIVE=true
```

第三方站点接口和页面结构可能随时变化。修改规则时，请至少验证搜索、详情、播放清单及实际媒体分片。

## 参与贡献

欢迎提交 Issue 和 Pull Request：

1. 将功能改动保持在明确范围内，避免无关格式化或生成文件变更。
2. 新增功能应尽量补充测试。
3. 提交前运行静态分析和相关测试。
4. 视频源失效问题请附上规则名称、复现关键词和失败阶段，不要提交个人 Cookie、Token 或其他敏感数据。

## 隐私与网络请求

应用每次启动时会向 `https://dau.anibaka.com/track` 发送一个匿名安装标识，用于统计各平台的日活跃安装量。该标识由应用首次运行时使用安全随机数在本地生成，格式为 `install_<platform>_<random>`，保存在本地设置中并在后续启动时复用；上报内容不包含账号 Token、用户名或设备硬件标识。对应实现位于 `lib/services/dau_tracker.dart`。

其他主要网络端点如下：

- `www.anibaka.com`：默认社区 API；可在应用的服务器设置中替换。
- `version.anibaka.com`、`app.anibaka.com`：版本与下载信息。
- `bgm.anibaka.com`、`p1.anibaka.com`：Bangumi 元数据代理。
- `gh.dpik.top/https://raw.githubusercontent.com/AniBakaBaka/AniBakaRule`：默认使用 GitHub 加速节点，失败时依次回退到 jsDelivr 和 GitHub。
- 各规则文件声明的第三方站点：仅在搜索、查看详情或播放等对应操作时访问。

使用者可通过源码审查具体请求及数据字段。登录、评论、历史同步等功能会向所选社区服务器发送完成相应操作所需的数据。

## 免责声明

本项目是通用媒体播放与规则解析工具，不提供内容授权。使用者应自行确认所访问内容、站点和网络服务符合所在地法律法规及相应服务条款。

项目按 GPLv3 的“无担保”条款提供。第三方站点的可用性、内容准确性、安全性和版权状态不受本项目控制。

## 致谢

- [Flutter](https://flutter.dev/) — 跨平台 UI 框架
- [media_kit](https://github.com/media-kit/media-kit) — 媒体播放框架
- [GetX](https://github.com/jonataslaw/getx) — 状态与依赖管理
- [Hive](https://github.com/isar/hive) — 本地数据存储
- [Anime4K](https://github.com/bloc97/Anime4K) — 动漫画质增强着色器
- [弹弹Play](https://www.dandanplay.com/) — 弹幕 API 服务

## 许可证

除单独标注的第三方组件和资产外，本项目以 [GNU General Public License v3.0](LICENSE) 发布，对应 SPDX 标识为 `GPL-3.0-only`。

依赖、第三方源码和资产继续适用其各自许可证及版权声明，仓库内直接包含的第三方材料见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
