import { StatusStore } from '../data/StatusStore';
import { RuntimeStatus } from '../model/VpnTypes';
import { formatBytes, formatUptime } from '../common/Formatters';
import { hilog } from '@kit.PerformanceAnalysisKit';

@Component
export struct StatusCard {
  @Prop stage: string = RuntimeStatus.IDLE;
  @Prop error: string = '';
  @Prop down: string = '0';
  @Prop up: string = '0';
  @Prop blocked: string = '0';
  @Prop tcpConns: string = '0';
  @Prop udpConns: string = '0';
  @Prop uptimeMs: string = '0';
  onStart?: () => void;
  onStop?: () => void;

  build() {
    Column() {
      Row() {
        this.StageIndicator()
        this.ActionButton()
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(VerticalAlign.Center)

      if (this.error.length > 0) {
        Text(this.error)
          .fontSize(13)
          .fontColor($r('app.color.error'))
          .margin({ top: 8 })
          .width('100%')
      }

      if (this.stage === RuntimeStatus.RUNNING) {
        this.StatsRow()
      }
    }
    .width('100%')
    .padding(20)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(16)
  }

  @Builder
  StageIndicator() {
    Row({ space: 8 }) {
      Column()
        .width(10)
        .height(10)
        .borderRadius(5)
        .backgroundColor(this.getStageColor())
      Text(this.getStageText())
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.font_primary'))
    }
  }

  @Builder
  ActionButton() {
    if (this.stage === RuntimeStatus.IDLE || this.stage === RuntimeStatus.ERROR) {
      Button('启动')
        .type(ButtonType.Capsule)
        .backgroundColor($r('app.color.accent'))
        .fontColor($r('app.color.font_on_accent'))
        .height(36)
        .onClick(() => {
          hilog.info(0x0000, 'LumineUI', 'StatusCard start button clicked');
          if (this.onStart) this.onStart();
        })
    } else if (this.stage === RuntimeStatus.RUNNING) {
      Button('停止')
        .type(ButtonType.Capsule)
        .backgroundColor($r('app.color.error'))
        .fontColor($r('app.color.font_on_accent'))
        .height(36)
        .onClick(() => {
          if (this.onStop) this.onStop();
        })
    } else {
      LoadingProgress()
        .width(24)
        .height(24)
    }
  }

  @Builder
  StatsRow() {
    Row({ space: 16 }) {
      this.StatItem('↓', this.down)
      this.StatItem('↑', this.up)
      this.StatItem('阻断', this.blocked)
      this.StatItem('TCP', this.tcpConns)
      this.StatItem('时长', formatUptime(Number(this.uptimeMs)))
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceBetween)
    .margin({ top: 16 })
    .padding({ top: 12 })
    .border({ width: { top: 1 }, color: $r('app.color.divider') })
  }

  @Builder
  StatItem(label: string, value: string) {
    Column() {
      Text(value)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.font_primary'))
      Text(label)
        .fontSize(10)
        .fontColor($r('app.color.font_secondary'))
        .margin({ top: 2 })
    }
    .alignItems(HorizontalAlign.Center)
  }

  getStageColor(): ResourceColor {
    if (this.stage === RuntimeStatus.RUNNING) return $r('app.color.success');
    if (this.stage === RuntimeStatus.ERROR) return $r('app.color.error');
    if (this.stage === RuntimeStatus.STARTING || this.stage === RuntimeStatus.STOPPING) return $r('app.color.warning');
    return $r('app.color.font_secondary');
  }

  getStageText(): string {
    if (this.stage === RuntimeStatus.RUNNING) return '运行中';
    if (this.stage === RuntimeStatus.STARTING) return '正在启动...';
    if (this.stage === RuntimeStatus.STOPPING) return '正在停止...';
    if (this.stage === RuntimeStatus.ERROR) return '已停止';
    return '未运行';
  }
}
