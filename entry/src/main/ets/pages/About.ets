import { router } from '@kit.ArkUI';
import { bundleManager } from '@kit.AbilityKit';
import { LumineCore } from '../service/LumineCore';

interface FeatureItem {
  title: string;
  subtitle: string;
}

const FEATURES: FeatureItem[] = [
  { title: '一键本地代理（TUN）', subtitle: '首页开关即可启停 VPN 隧道' },
  { title: '订阅管理', subtitle: 'URL 导入、刷新并切换多套 Clash 风格配置' },
  { title: '规则引擎', subtitle: '查看、新建与编辑域名和 IP/CIDR 规则，支持多种代理模式' },
  { title: '智能分流', subtitle: '继承 lumine 的 GFWList 黑名单驱动分流，配合灵活 Fake-IP' },
  { title: '实时日志', subtitle: '级别过滤、自动滚动、捕捉开关与一键导出' },
  { title: '全局设置', subtitle: '上游 DNS 地址与核心日志级别' },
  { title: '运行通知', subtitle: '代理运行期间在通知栏保持状态通知' }
];

const CREDITS: FeatureItem[] = [
  { title: 'lumine', subtitle: 'C++ 原生核心（上游）' },
  { title: 'SniShaper', subtitle: '桌面版代理项目，路由理念同源' }
];

@Entry
@Component
struct About {
  @State appVersion: string = 'unknown';
  @State coreVersion: string = 'unknown';

  aboutToAppear(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.appVersion = info.versionName;
    } catch {
      this.appVersion = 'unknown';
    }
    const v = LumineCore.getInstance().getVersion();
    this.coreVersion = v.length > 0 ? v : 'unknown';
  }

  build() {
    Column() {
      Row() {
        Text('<')
          .fontSize(18)
          .fontColor($r('app.color.font_primary'))
          .width(40)
          .height(40)
          .textAlign(TextAlign.Start)
          .onClick(() => router.back())
        Text('关于')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.font_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      .height(48)
      .padding({ left: 16, right: 16 })

      Scroll() {
        Column({ space: 12 }) {
          Row() {
            Column() {
              Image($r('app.media.lumine_mark'))
                .width(44)
                .height(44)
                .fillColor($r('app.color.accent'))
            }
            .width(72)
            .height(72)
            .backgroundColor($r('app.color.card_bg'))
            .borderRadius(36)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)

            Column({ space: 2 }) {
              Text('Lumine')
                .fontSize(22)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.font_primary'))
                .width('100%')
              Text('本地代理 · 轻量 VPN 客户端')
                .fontSize(13)
                .fontColor($r('app.color.font_secondary'))
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .margin({ left: 16 })
          }
          .width('100%')
          .padding(20)
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(16)
          .alignItems(VerticalAlign.Center)

          this.SectionLabel('版本信息')
          this.Paragraph('当前版本 ' + this.appVersion + '，支持 HarmonyOS 6.0（API 20）及以上系统。')
          this.Paragraph('核心版本 ' + this.coreVersion + '（C++ 原生核心，经 NAPI 接入）。')

          this.SectionLabel('简介')
          this.Paragraph('Lumine 是基于 Lumine C++ 原生核心的 HarmonyOS 端 Clash 风格本地代理 / VPN 客户端。' +
            '它通过 VpnExtensionAbility（TUN）隧道接管设备流量，并按配置规则在本地完成转发与分流。')
          this.Paragraph('界面采用 ArkTS + ArkUI 原生构建，遵循 HarmonyOS 设计规范并支持深浅色；' +
            'C++ 原生核心交叉编译为 liblumine_napi.so，通过 NAPI 接入，无任何 WebView 内嵌。')
          this.Paragraph('本项目是 SniShaper 代理项目的移动端配套版本：SniShaper 提供 Windows / Linux ' +
            '桌面端与 headless CLI，Lumine 面向手机移动场景。')

          this.SectionLabel('功能')
          this.FeatureCard(FEATURES)

          this.SectionLabel('技术栈')
          this.Paragraph('界面：ArkTS + ArkUI，遵循 HarmonyOS 的形状、排版与配色规范，深浅色双支持。')
          this.Paragraph('核心：C++ 原生核心（lumine 代理与分流内核），交叉编译为 liblumine_napi.so，由 NAPI 层接入。' +
            '隧道基于 VpnExtensionAbility 实现，无 WebView 内嵌。')

          this.SectionLabel('获取渠道')
          this.Paragraph('GitHub Releases：按设备 ABI 提供 arm64-v8a / x86_64 分包，推荐 arm64-v8a。')

          this.SectionLabel('致谢')
          this.FeatureCard(CREDITS)

          this.SectionLabel('开源许可')
          this.Paragraph('本项目基于 GNU Affero General Public License v3.0（AGPL-3.0）协议开源发布。')
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 24 })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }

  @Builder
  SectionLabel(label: string) {
    Text(label)
      .fontSize(13)
      .fontColor($r('app.color.accent'))
      .width('100%')
      .padding({ top: 10, bottom: 2 })
  }

  @Builder
  Paragraph(content: string) {
    Column() {
      Text(content)
        .fontSize(13)
        .fontColor($r('app.color.font_secondary'))
        .lineHeight(20)
        .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(16)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  FeatureCard(items: FeatureItem[]) {
    Column() {
      ForEach(items, (item: FeatureItem, index: number) => {
        if (index > 0) {
          Divider()
            .color($r('app.color.divider'))
            .strokeWidth(1)
            .margin({ left: 16 })
        }
        Column({ space: 2 }) {
          Text(item.title)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.font_primary'))
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(item.subtitle)
            .fontSize(12)
            .fontColor($r('app.color.font_secondary'))
            .width('100%')
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .alignItems(HorizontalAlign.Start)
      }, (item: FeatureItem) => item.title)
    }
    .width('100%')
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(16)
    .clip(true)
  }
}
