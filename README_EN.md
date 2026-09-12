# Lumine for HarmonyOS

[中文](README.md) | [English](README_EN.md) | [Русский](README_RU.md)

[![HarmonyOS](https://img.shields.io/badge/HarmonyOS-5.0%2B-0D0D0D?style=flat&logo=huawei)](https://developer.huawei.com/consumer/cn/arkts/) [![License](https://img.shields.io/badge/License-AGPL--3.0-blue?style=flat&logo=open-source-initiative)](LICENSE) [![GitHub last commit](https://img.shields.io/github/last-commit/SnishaperTeam/lumine-for-harmonyos?style=flat&logo=git&label=Last%20commit)](https://github.com/SnishaperTeam/lumine-for-harmonyos/commits/main)

**Lumine for HarmonyOS** is the HarmonyOS port of Lumine, a Clash-style local proxy / VPN client. The app takes over device traffic through a **VpnExtensionAbility (TUN)** tunnel and also offers a **local proxy listen** mode (SOCKS5 / HTTP loopback inbound); all forwarding and splitting happens inside the local core, with no WebView embedded.

The UI is natively built with **ArkTS + ArkUI**, following the HarmonyOS design language with light / dark support. The core is a **portable C++17 implementation (ccore)** delivered to the app process as a single `liblumine_napi.so` over NAPI. Lumine is the mobile-side companion of the [SniShaper](https://github.com/SnishaperTeam/SniShaper) proxy project.

> Looking for the desktop version? See **[SniShaper](https://github.com/SnishaperTeam/SniShaper)** — a Windows / Linux dual-platform proxy suite with a cross-platform headless CLI, sharing the same routing ideas.

> Looking for the Android version? See **[Lumine for Android](https://github.com/SniShaper/lumine-for-android)** — Kotlin + Jetpack Compose (Material Design 3) native UI with the Go (enimul) core bound via gomobile.

---

## Features

- **One-tap local proxy**: start / stop from the home screen; TUN mode establishes a tunnel through VpnExtensionAbility, while the developer **local proxy listen** (SOCKS5 + HTTP loopback inbound) covers environments without a VPN component, such as emulators.
- **Subscription management**: import configs from a subscription URL with validation on download (core config parser pre-check), plus refresh, apply, delete and bulk refresh.
- **Rule engine**: view, create, edit and delete **domain** and **IP / CIDR** rules; key renames automatically migrate enabled state. Multiple proxy modes: Direct / Transparent / TLS fragment / TTL probing / Block.
- **Intelligent splitting**: GFWList blacklist-driven automatic routing inherited from the desktop routing ideas; manual rules always have the highest priority.
- **DNS & NAT64 management**: multi-node DNS configuration (DoH / DoQ / DoT / TCP / UDP), built-in NAT64 providers, automatic IPv6 and prefix detection.
- **Evolution mode**: automatic domain connectivity testing (direct TCP / NAT64 synthesis) with temporary rules that can be promoted to permanent ones in one tap.
- **Real-time logs**: level filtering (all / info / error / debug / other), statistics overview, capture toggle and one-tap export.
- **Running notification**: an ongoing status notification is kept in the notification drawer while the proxy runs, and removed automatically on stop.
- **Per-app routing**: whitelist / bypass modes with a manually maintained package name list.

---

## Quick Start

### Install

Download the HAP from [Releases](https://github.com/SnishaperTeam/lumine-for-harmonyos/releases) (requires HarmonyOS 5.0 / API 12 or later), or install it with `hdc`:

```bash
hdc install entry-default-unsigned.hap
```

### Configure and Start

1. Open the app and go to **配置订阅 / Subscription**, add a subscription name and URL, wait for the import to finish, then tap to apply it.
2. Return to the home screen and flip the proxy switch; the first start requests system VPN authorization.
3. In environments without a VPN component (such as emulators), use **Developer → Local proxy listen** near the bottom of the home screen to get a SOCKS5 / HTTP proxy on the loopback address for manual configuration.

---

## Build & Development

- [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/) (with the HarmonyOS SDK and bundled Node.js / hvigor)
- Target: `compatibleSdkVersion 6.0.0(20)`, ABIs `arm64-v8a` + `x86_64`

Full command-line build (assembleHap):

```bash
cd Lumine_For_HarmonyOS
export DEVECO_SDK_HOME="<DevEco Studio>/sdk"
"<DevEco Studio>/tools/node/node.exe" "<DevEco Studio>/tools/hvigor/bin/hvigorw.js" \
  --mode module -p product=default -p buildMode=debug assembleHap --no-daemon
```

Output: `entry/build/default/outputs/default/entry-default-unsigned.hap`.

### Repository layout

```
entry/src/main/
  ets/pages/      ArkUI pages (13 screens, aligned word-for-word with the Android version)
  ets/service/    LumineCore (NAPI bridge), VpnController, NetworkMonitor
  ets/data/       ConfigRepository, PrefsStore, StatusStore
  ets/model/      LumineConfig, VpnTypes
  cpp/ccore/      C++17 core: JSON / matcher / routing / tunnel / SOCKS5 / HTTP / lifecycle
  cpp/            napi_init.cpp (NAPI module entry, 11 exports) and CMakeLists.txt
```

The core is rebuilt automatically by hvigor through `externalNativeOptions` (CMake over `ccore/*.cpp` + `napi_init.cpp`, linking only `ace_napi` and `hilog`) with no third-party dependencies.

---

## Platform Notes

- The current version is an MVP based on local listen and TUN: TUN mode depends on system VPN authorization; in environments without a VPN component use the local proxy listen mode.
- Upstream engines for DoQ / DoH / DoT encrypted DNS are planned work items; DNS resolution currently goes through the system resolver.
- Features that require CA certificates (MITM / ECH / QUIC fragment obfuscation / session migration) are unavailable on mobile and are shown as disabled placeholders in the UI.

---

## License

[GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0).
