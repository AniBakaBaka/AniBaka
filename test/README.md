# 测试

在项目根目录运行：

```sh
fvm flutter test --no-pub
fvm flutter analyze --no-pub
```

应用网络设置接入测试：`fvm flutter test --no-pub test/core/network_privacy_test.dart`。
通用 DoH/ECH 与 Dio 测试维护于组织的 [ech_http](https://github.com/AniBakaBaka/ech_http)。
在该依赖仓库运行 `dart test`；设置 `ECH_TEST_DOH_LIVE=1` 可包含真实 Cloudflare
DoH/ECH 握手测试，需代理时指定 `ECH_TEST_PROXY`。首次执行需要原生 C++ 构建工具
以及下载依赖 SDK 的网络访问。

## 结构和保障范围

- `core/`：账号隔离、请求去重、存储恢复、匹配排序、规则解析与解码、HLS 安全过滤。
- `services/`：收藏同步、历史恢复、规则索引缓存、凭证并发、媒体探测、种子解析、日志下载访问限制。
- `features/`：播放控制与配置迁移、选集换源、一起看同步、弹幕、拖动进度与播放页状态保留。
- `support/`：按需装配源或播放依赖，共用真实 TS 分片前缀；规则仓库由使用它的测试创建。

目前没有 `integration_test/` 或 Golden 测试。`.github/scripts/tests/` 中的发布签名测试
保护签名验证与打包顺序，单独保留，不纳入 Flutter 测试耗时。

## 维护约定

长期保留能保护核心流程或高损失故障的测试：账号与凭证隔离、存储恢复、收藏和历史、
规则解析与回退、播放和下载生命周期、取消及过期结果隔离。测试只涉及某个功能，
并不等于没有价值；判断标准是它能否发现仍可能发生的真实错误。
