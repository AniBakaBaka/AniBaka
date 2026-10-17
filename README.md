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
- Windows [DLSS 5 实验性视频增强](docs/dlss5-video-enhancement.md)，实验室开关可为所有内置播放启用 NVIDIA 神经渲染、2 倍超分与帧生成，仅作用于内置播放器

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

### 组织维护的依赖

`media_kit_video` 和 `screen_brightness` 通过 pub 的 Git 依赖引用组织 fork，
`pubspec.yaml` 固定提交，`pubspec.lock` 记录解析结果。运行 `fvm flutter pub get`
即可获取，无需复制 `third_party` 或修改 Pub 缓存。

- [media-kit](https://github.com/AniBakaBaka/media-kit/tree/main)：
  Windows 播放器增强补丁；主项目 CMake 启用 `MEDIA_KIT_VIDEO_ENABLE_DLSS`，
  并提供 `windows/runner/dlss_realtime` 中的 GPU 后端。
- [screen_brightness](https://github.com/AniBakaBaka/screen_brightness/tree/main)：
  移除 Windows 亮度插件注册，保留上游 Dart API 和其他平台实现。

更新补丁时，先合并到对应 fork 的 `main`，再更新 `pubspec.yaml` 的 `ref` 并运行
`fvm flutter pub get`，同时提交锁文件。两个仓库保留上游 fork 关系。

### 检查

内置源与规则库使用相同的 `anx-rulehub/2` 整数 `rev`，独立于 App 版本。
更新内置源时，从规则库同时同步规则文件和版本清单，不要单独修改版本号：

```bash
dart run tool/sync_bundled_rules.dart ../AniBakaRule
dart run tool/sync_bundled_rules.dart ../AniBakaRule --check
```

同步结果保存在 `assets/rules/`；`index.json` 记录对应版本及内容摘要，
测试会检查版本清单与打包内容是否匹配。规则库未登记的内置源使用 `rev: 0`。

```bash
fvm flutter analyze
fvm flutter test
```

测试按核心逻辑、服务和用户交互整理在 `test/core/`、`test/services/`、
`test/features/`。保留范围和维护约定见 [测试说明](test/README.md)。

第三方站点接口和页面结构可能随时变化。修改规则时，请至少验证搜索、详情、播放清单及实际媒体分片。

## 参与贡献

欢迎提交 Issue 和 Pull Request：

1. 将功能改动保持在明确范围内，避免无关格式化或生成文件变更。
2. 新增功能应尽量补充测试。
3. 提交前运行静态分析和相关测试。
4. 视频源失效问题请附上规则名称、复现关键词和失败阶段，不要提交个人 Cookie、Token 或其他敏感数据。

## 隐私与网络请求

可在「设置 → 网络设置」启用 DoH 与 ECH，保存后重启应用生效，默认关闭。
DoH 使用 RFC 8484 DNS 消息格式，默认端点为 `https://1.1.1.1/dns-query`，

通用实现维护于组织的
[ech_http](https://github.com/AniBakaBaka/ech_http)，保留
[上游项目](https://github.com/ech-research/ech_http)历史，AniBaka 通过固定 Git 提交引用。
原生构建说明见该仓库的 `ANIBAKA_CHANGES.md`，首次构建需联网下载按 SHA-256
校验的原生依赖。

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

## 自动跳过片头片尾

在播放器设置中开启“智能跳过”，按当前剧集的 OP/ED 区间跳到终点。无数据、
身份不明确或版本不匹配时保持正常播放；跳过后可在 5 秒内撤销，片尾后的彩蛋继续播放。
自动绑定使用播放资料中已有的 Bangumi ID 和明确集数；只有标题搜索结果或合集编号时，
请先在标注面板绑定具体剧集。

公共时间戳来自 AniSkip，通过 BangumiExtLinker 关联 MAL 条目。仅在条目、集数明确且
实际时长与参考时长相差不超过 2 秒时自动使用。相同总时长仍可能对应不同剪辑版本，
可在“标注与校正片头片尾”中更正或关闭当前片源的片头/片尾跳过。

手动标注保存在本机；登录后可以主动共享。其他两位用户确认后用于当前片源自动跳过，
两位用户报错后暂停使用。切换片源、线路或 HLS 去广告结果会重新匹配；过滤后的时间轴
只使用该版本上确认的标注。新接口需要配套后端，旧服务器仍可使用本机标注。

OP、ED 都可分别一键“应用到全集”，同一番剧、同片源线路和时间轴沿用相同起止时间；
已有单集校准优先，超出视频时长的区间不使用，第 1 集仍保留片头片尾。
区间详情中的“应用到全集”同时决定保存和上传范围，登录后可共享全集标注；
全集上传需配套后端更新并执行迁移，旧服务器仍可使用本机全集设置。

查询通过所选社区服务器完成，发送 Bangumi 条目和剧集 ID、视频时长、片源摘要及
时间轴摘要，不发送播放地址、请求头或本地文件路径。提交与反馈需登录，并关联提交账号。
服务器向 AniSkip 查询 MAL 条目、集数及视频时长，并定期更新 BangumiExtLinker 映射。

## 致谢

- [Flutter](https://flutter.dev/) — 跨平台 UI 框架
- [media_kit](https://github.com/media-kit/media-kit) — 媒体播放框架
- [GetX](https://github.com/jonataslaw/getx) — 状态与依赖管理
- [Hive](https://github.com/isar/hive) — 本地数据存储
- [Anime4K](https://github.com/bloc97/Anime4K) — 动漫画质增强着色器
- [弹弹Play](https://www.dandanplay.com/) — 弹幕 API 服务
- [AniSkip](https://github.com/aniskip/aniskip-api) — 社区贡献的片头、片尾时间戳服务
- [Rhilip / BangumiExtLinker](https://github.com/Rhilip/BangumiExtLinker) — Bangumi 与 MyAnimeList 条目映射数据（[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)）；服务端提取所需 ID，并允许独立的逐集校正
- 感谢提交、确认和纠正片头片尾区间的社区用户

## 许可证

除单独标注的第三方组件和资产外，本项目以 [GNU General Public License v3.0](LICENSE) 发布，对应 SPDX 标识为 `GPL-3.0-only`。

“AniBaka” 名称及应用图标（`assets/ic_launcher.png` 及由其生成的各平台图标文件）的著作权与相关权益归开发者所有，不适用上述 GPLv3 授权。未经开发者事先书面同意，不得将上述名称或图标用于再发布构建、衍生作品或任何其他用途。

依赖、第三方源码和资产继续适用其各自许可证及版权声明，仓库内直接包含的第三方材料见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
