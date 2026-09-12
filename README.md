# Lumine for HarmonyOS

[中文](README.md) | [English](README_EN.md) | [Русский](README_RU.md)

[![HarmonyOS](https://img.shields.io/badge/HarmonyOS-6.0%2B-0D0D0D?style=flat&logo=huawei)](https://developer.huawei.com/consumer/cn/arkts/) [![License](https://img.shields.io/badge/许可证-AGPL--3.0-blue?style=flat&logo=open-source-initiative)](LICENSE) [![GitHub last commit](https://img.shields.io/github/last-commit/SnishaperTeam/lumine-for-harmonyos?style=flat&logo=git&label=最后提交)](https://github.com/SnishaperTeam/lumine-for-harmonyos/commits/main)

**Lumine for HarmonyOS** 是 Lumine 在 HarmonyOS 平台的 Clash 风格本地代理 / VPN 客户端。应用通过 **VpnExtensionAbility（TUN）** 接管设备流量，并提供 **本地代理监听**（SOCKS5 / HTTP 回环入站）模式；所有转发与分流都在本地核心内完成，无任何 WebView 内嵌。

界面采用 **ArkTS + ArkUI** 原生构建，遵循 HarmonyOS 设计规范，支持深浅色；核心为 **便携 C++17 实现（ccore）**，经 NAPI 以单个 `liblumine_napi.so` 接入应用进程。Lumine 是 [SniShaper](https://github.com/SnishaperTeam/SniShaper) 代理项目的移动端配套版本。

> 需要桌面版？请参见 **SniShaper**（<https://github.com/SnishaperTeam/SniShaper>）——Windows / Linux 双平台代理软件与跨平台 headless CLI，共享相同的路由理念。

> 需要 Android 版？请参见 **Lumine for Android**（<https://github.com/SniShaper/lumine-for-android>）——Kotlin + Jetpack Compose（Material Design 3）原生界面，Go（enimul）核心经 gomobile 绑定。

---

## 特性

- **一键本地代理**：首页开关启停代理；TUN 模式经 VpnExtensionAbility 建立隧道，未授权 / 不支持 VPN 的环境（如模拟器）可使用开发者 **本地代理监听**（SOCKS5 + HTTP 回环入站）。
- **订阅管理**：URL 导入订阅，下载即校验（核心配置解析器预检），支持刷新、应用、删除与批量刷新。
- **规则引擎**：域名与 IP/CIDR 规则的查看、新建、编辑与删除，键重命名自动迁移启用状态；支持 直连 / 透传 / TLS 分片 / TTL 探测 / 阻断 等多种代理模式。
- **智能分流**：GFWList 黑名单驱动的自动分流，继承桌面版路由理念，规则条目拥有最高优先级。
- **DNS 与 NAT64 管理**：多节点 DNS 配置（DoH / DoQ / DoT / TCP / UDP）、内置 NAT64 服务商、IPv6 与前缀自动探测。
- **进化模式**：自动测试域名连通性（TCP 直连 / NAT64 合成），生成临时规则并一键转为正式规则。
- **实时日志**：级别过滤（全部 / 信息 / 错误 / 调试 / 其他）、统计概览、捕捉开关与一键导出。
- **运行通知**：代理运行期间在通知栏保持状态通知，停止时自动撤除。
- **分应用路由**：白名单 / 绕过名单模式，手动维护应用包名列表。

---

## 快速开始

### 安装

从 [Releases](https://github.com/SnishaperTeam/lumine-for-harmonyos/releases) 下载 HAP 安装包（需 HarmonyOS 6.0 / API 20 及以上），或使用 `hdc` 安装：

```bash
hdc install entry-default-unsigned.hap
```

### 配置与启动

1. 打开应用，进入 **配置订阅**，添加订阅名称与 URL，等待导入完成后点击应用。
2. 返回首页，打开代理开关；首次启动会请求系统 VPN 授权。
3. 在无 VPN 组件的环境（如模拟器）中，可使用首页下方的 **开发者 → 本地代理监听**，在回环地址上提供 SOCKS5 / HTTP 代理供手动指定。

---

## 构建与开发

- [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)（含 HarmonyOS SDK 与自带 Node.js / hvigor）
- 目标：`compatibleSdkVersion 6.0.0(20)`，ABI `arm64-v8a` + `x86_64`

命令行全量构建（assembleHap）：

```bash
cd Lumine_For_HarmonyOS
export DEVECO_SDK_HOME="<DevEco Studio>/sdk"
"<DevEco Studio>/tools/node/node.exe" "<DevEco Studio>/tools/hvigor/bin/hvigorw.js" \
  --mode module -p product=default -p buildMode=debug assembleHap --no-daemon
```

产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`。

### 目录结构

```
entry/src/main/
  ets/pages/      ArkUI 页面（13 个，与 Android 版逐字对齐）
  ets/service/    LumineCore（NAPI 桥）、VpnController、NetworkMonitor
  ets/data/       ConfigRepository、PrefsStore、StatusStore
  ets/model/      LumineConfig、VpnTypes
  cpp/ccore/      C++17 核心：JSON / 匹配器 / 路由 / 隧道 / SOCKS5 / HTTP / 生命周期
  cpp/            napi_init.cpp（NAPI 模块入口，11 个导出）与 CMakeLists.txt
```

核心经 `externalNativeOptions` 由 hvigor 调用 CMake 自动重编（`ccore/*.cpp` + `napi_init.cpp`，仅链接 `ace_napi` 与 `hilog`），无第三方依赖。

---

## 平台说明

- 当前版本基于本地监听与 TUN 的 MVP 实现：TUN 模式依赖系统 VPN 授权；无 VPN 组件的环境请使用本地代理监听。
- DoQ / DoH / DoT 加密 DNS 的上游引擎为计划中的工作项，当前 DNS 解析走系统解析器。
- 需要 CA 证书的功能（MITM / ECH / QUIC 分片混淆 / 会话迁移）在移动端不可用，界面中以禁用占位形式展示。

---

## 许可

[GNU Affero General Public License v3.0](LICENSE)（AGPL-3.0）。
