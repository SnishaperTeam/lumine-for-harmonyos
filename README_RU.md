# Lumine for HarmonyOS

[中文](README.md) | [English](README_EN.md) | [Русский](README_RU.md)

[![HarmonyOS](https://img.shields.io/badge/HarmonyOS-5.0%2B-0D0D0D?style=flat&logo=huawei)](https://developer.huawei.com/consumer/cn/arkts/) [![License](https://img.shields.io/badge/Лицензия-AGPL--3.0-blue?style=flat&logo=open-source-initiative)](LICENSE) [![GitHub last commit](https://img.shields.io/github/last-commit/SnishaperTeam/lumine-for-harmonyos?style=flat&logo=git&label=Последний%20коммит)](https://github.com/SnishaperTeam/lumine-for-harmonyos/commits/main)

**Lumine for HarmonyOS** — это HarmonyOS-версия Lumine, локального прокси / VPN-клиента в стиле Clash. Приложение перехватывает трафик устройства через туннель **VpnExtensionAbility (TUN)**, а также предлагает режим **локального прокси-прослушивания** (входящие соединения SOCKS5 / HTTP на loopback); всё перенаправление и разделение трафика выполняется локальным ядром, без встроенного WebView.

Интерфейс нативно построен на **ArkTS + ArkUI** в соответствии с дизайн-языком HarmonyOS, с поддержкой светлой и тёмной тем. Ядро — **переносимая реализация на C++17 (ccore)**, подключаемая к процессу приложения как единый `liblumine_napi.so` через NAPI. Lumine — мобильный компаньон прокси-проекта [SniShaper](https://github.com/SnishaperTeam/SniShaper).

> Нужна настольная версия? Смотрите **[SniShaper](https://github.com/SnishaperTeam/SniShaper)** — прокси-клиент для Windows / Linux с кроссплатформенным headless CLI, использующий те же идеи маршрутизации.

> Нужна версия для Android? Смотрите **[Lumine for Android](https://github.com/SniShaper/lumine-for-android)** — нативный интерфейс на Kotlin + Jetpack Compose (Material Design 3) с ядром Go (enimul), привязанным через gomobile.

---

## Возможности

- **Локальный прокси в одно касание**: запуск / остановка переключателем на главном экране; режим TUN создаёт туннель через VpnExtensionAbility, а режим разработчика **локального прокси-прослушивания** (входящие SOCKS5 + HTTP на loopback) покрывает среды без VPN-компонента, например эмуляторы.
- **Управление подписками**: импорт конфигураций по URL с проверкой при загрузке (предварительная проверка парсером конфигурации ядра), обновление, применение, удаление и массовое обновление.
- **Движок правил**: просмотр, создание, редактирование и удаление правил для **доменов** и **IP / CIDR**; переименование ключа автоматически переносит состояние включения. Несколько режимов проксирования: Direct / Transparent / TLS-фрагментация / TTL-зондирование / Блокировка.
- **Интеллектуальное разделение**: автоматическая маршрутизация на основе чёрного списка GFWList, унаследованная от настольных идей маршрутизации; ручные правила всегда имеют наивысший приоритет.
- **Управление DNS и NAT64**: многоузловая конфигурация DNS (DoH / DoQ / DoT / TCP / UDP), встроенные провайдеры NAT64, автоматическое обнаружение IPv6 и префиксов.
- **Режим эволюции**: автоматическое тестирование доступности доменов (прямой TCP / синтез NAT64) с временными правилами, которые можно перевести в постоянные одним нажатием.
- **Журналы в реальном времени**: фильтрация по уровню (все / информация / ошибки / отладка / прочее), сводная статистика, переключатель захвата и экспорт одним нажатием.
- **Уведомление о работе**: пока прокси работает, в шторке уведомлений удерживается статусное уведомление, которое автоматически удаляется при остановке.
- **Маршрутизация по приложениям**: режимы белого списка / обхода с ручным списком имён пакетов.

---

## Быстрый старт

### Установка

Скачайте HAP из [Releases](https://github.com/SnishaperTeam/lumine-for-harmonyos/releases) (требуется HarmonyOS 5.0 / API 12 или новее) или установите через `hdc`:

```bash
hdc install entry-default-unsigned.hap
```

### Настройка и запуск

1. Откройте приложение, перейдите в раздел **配置订阅 / Подписки**, добавьте имя подписки и URL, дождитесь завершения импорта и нажмите для применения.
2. Вернитесь на главный экран и включите переключатель прокси; при первом запуске система запросит авторизацию VPN.
3. В средах без VPN-компонента (например, на эмуляторах) используйте **Разработчик → Локальное прокси-прослушивание** внизу главного экрана — вы получите прокси SOCKS5 / HTTP на loopback-адресе для ручной настройки.

---

## Сборка и разработка

- [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/) (с HarmonyOS SDK и встроенными Node.js / hvigor)
- Цель: `compatibleSdkVersion 6.0.0(20)`, ABI `arm64-v8a` + `x86_64`

Полная сборка из командной строки (assembleHap):

```bash
cd Lumine_For_HarmonyOS
export DEVECO_SDK_HOME="<DevEco Studio>/sdk"
"<DevEco Studio>/tools/node/node.exe" "<DevEco Studio>/tools/hvigor/bin/hvigorw.js" \
  --mode module -p product=default -p buildMode=debug assembleHap --no-daemon
```

Результат: `entry/build/default/outputs/default/entry-default-unsigned.hap`.

### Структура репозитория

```
entry/src/main/
  ets/pages/      страницы ArkUI (13 экранов, дословно выровнены с Android-версией)
  ets/service/    LumineCore (мост NAPI), VpnController, NetworkMonitor
  ets/data/       ConfigRepository, PrefsStore, StatusStore
  ets/model/      LumineConfig, VpnTypes
  cpp/ccore/      ядро C++17: JSON / сопоставитель / маршрутизация / туннель / SOCKS5 / HTTP / жизненный цикл
  cpp/            napi_init.cpp (точка входа NAPI-модуля, 11 экспортов) и CMakeLists.txt
```

Ядро пересобирается автоматически через hvigor (`externalNativeOptions`: CMake по `ccore/*.cpp` + `napi_init.cpp`, линковка только с `ace_napi` и `hilog`) без сторонних зависимостей.

---

## Примечания к платформе

- Текущая версия — MVP на основе локального прослушивания и TUN: режим TUN требует авторизации системного VPN; в средах без VPN-компонента используйте режим локального прокси-прослушивания.
- Механизмы восходящих соединений для шифрованного DNS DoQ / DoH / DoT — в планах; сейчас разрешение DNS выполняется через системный резолвер.
- Функции, требующие сертификатов CA (MITM / ECH / обфускация фрагментацией QUIC / миграция сессии), на мобильных устройствах недоступны и отображаются в интерфейсе как отключённые заглушки.

---

## Лицензия

[GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0).
