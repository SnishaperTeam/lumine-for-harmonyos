import { formatBytes, formatUptime } from '../common/Formatters';

@Component
export struct StatsPanel {
  @Prop down: string = '0';
  @Prop up: string = '0';
  @Prop blocked: string = '0';
  @Prop tcpConns: string = '0';
  @Prop udpConns: string = '0';
  @Prop uptimeMs: string = '0';

  build() {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        this.StatItem('下载', this.down)
        this.StatItem('上传', this.up)
        this.StatItem('阻断', this.blocked)
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)

      Row({ space: 12 }) {
        this.StatItem('TCP', this.tcpConns)
        this.StatItem('UDP', this.udpConns)
        this.StatItem('时长', formatUptime(Number(this.uptimeMs)))
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(12)
  }

  @Builder
  StatItem(label: string, value: string) {
    Column() {
      Text(value)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.font_primary'))
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.font_secondary'))
        .margin({ top: 2 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }
}
