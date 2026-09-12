import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { ConfigRepository } from '../data/ConfigRepository';
import { StatusStore } from '../data/StatusStore';
import { LumineCore } from '../service/LumineCore';
import { LumineConfig } from '../model/LumineConfig';
import { RuntimeStatus, VpnState } from '../model/VpnTypes';

interface PolicyOption {
  id: string;
  label: string;
}

const POLICY_OPTIONS: PolicyOption[] = [
  { id: 'tls-rf', label: 'TLS 分片（智能默认）' },
  { id: 'direct', label: '直连' },
  { id: 'raw', label: '原始直连' },
  { id: 'ttl-d', label: 'TTL 探测（desync）' },
  { id: 'block', label: '阻断' }
];

@Entry
@Component
struct Routing {
  @State config: LumineConfig | null = null;
  @State mode: string = 'direct';
  @State connected: boolean = false;
  @State recentFlow: string[] = [];
  @State notice: string = '';

  private repo: ConfigRepository | null = null;
  private statusStore: StatusStore | null = null;
  private core: LumineCore = LumineCore.getInstance();
  private flowTimer: number = -1;
  private flowBuffer: string[] = [];
  private logFilePath: string = '';
  private logOffset: number = 0;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.repo = ConfigRepository.getInstance(ctx);
    this.statusStore = StatusStore.getInstance(ctx);
    this.repo.init().then(() => {
      this.loadConfig();
    });
    this.flowTimer = setInterval(() => {
      this.pollFlow();
    }, 1500);
  }

  aboutToDisappear(): void {
    if (this.flowTimer >= 0) {
      clearInterval(this.flowTimer);
    }
  }

  async loadConfig(): Promise<void> {
    if (!this.repo) {
      return;
    }
    this.config = await this.repo.loadConfig('config');
    if (this.config) {
      this.mode = this.config.default_policy.mode ?? 'direct';
    }
  }

  async applySettings(): Promise<void> {
    if (!this.repo || !this.config) {
      return;
    }
    this.config.default_policy.mode = this.mode;
    await this.repo.saveConfig('config', this.config);
    this.notice = '已保存';
  }

  async readCoreChunk(): Promise<string> {
    const direct: string = this.core.readNewLogs();
    if (direct.length > 0) {
      return direct;
    }
    if (this.logFilePath.length === 0) {
      const ctx = getContext(this) as common.UIAbilityContext;
      this.logFilePath = ctx.filesDir + '/logs/lumine.log';
    }
    try {
      if (!fileIo.accessSync(this.logFilePath)) {
        return '';
      }
      const size: number = fileIo.statSync(this.logFilePath).size;
      if (size <= this.logOffset) {
        this.logOffset = size;
        return '';
      }
      const length: number = size - this.logOffset;
      const fd = fileIo.openSync(this.logFilePath, fileIo.OpenMode.READ_ONLY);
      try {
        const buf = new ArrayBuffer(length);
        const read: number = fileIo.readSync(fd.fd, buf, { offset: this.logOffset, length: length });
        this.logOffset = size;
        const decoder = new util.TextDecoder('utf-8');
        return decoder.decodeToString(new Uint8Array(buf, 0, read));
      } finally {
        fileIo.closeSync(fd);
      }
    } catch (err) {
      return '';
    }
  }

  async pollFlow(): Promise<void> {
    if (this.statusStore) {
      const state: VpnState = await this.statusStore.readVpnState();
      this.connected = state.stage === RuntimeStatus.RUNNING;
    }
    if (!this.connected) {
      this.flowBuffer = [];
      this.recentFlow = [];
      return;
    }
    const chunk = await this.readCoreChunk();
    if (chunk.length > 0) {
      const lines: string[] = chunk.split('\n');
      for (const line of lines) {
        const t = line.trim();
        if (t.length === 0) {
          continue;
        }
        if (t.indexOf('[TCP]') >= 0 || t.indexOf('[UDP]') >= 0) {
          this.flowBuffer.push(t);
        }
      }
      if (this.flowBuffer.length > 4) {
        this.flowBuffer = this.flowBuffer.slice(this.flowBuffer.length - 4);
      }
    }
    this.recentFlow = this.flowBuffer.slice();
  }

  build() {
    Stack() {
      Scroll() {
        Column({ space: 8 }) {
          Row() {
            Text('<')
              .fontSize(18)
              .fontColor($r('app.color.font_primary'))
              .width(40)
              .height(40)
              .textAlign(TextAlign.Start)
              .onClick(() => router.back())
            Text('自动分流')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.font_primary'))
              .layoutWeight(1)
          }
          .width('100%')

          this.SectionHeader('流量流向')

          Column() {
            if (this.recentFlow.length === 0) {
              Text(this.connected ? '等待流量中...' : '代理未连接')
                .fontSize(12)
                .fontColor($r('app.color.font_secondary'))
                .width('100%')
            } else {
              ForEach(this.recentFlow, (line: string, i: number) => {
                Text(line.length > 110 ? line.substring(0, 110) : line)
                  .fontSize(12)
                  .fontColor($r('app.color.font_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .padding({ top: 2, bottom: 2 })
              }, (line: string, i: number) => i + ':' + line)
            }
          }
          .width('100%')
          .padding(14)
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(12)
          .alignItems(HorizontalAlign.Start)

          this.SectionHeader('自动分流策略')

          Text('手动定义的「分流规则」条目拥有最高优先级。若均未命中，则按下方默认策略与内置 GFWList 回落处理。')
            .fontSize(12)
            .fontColor($r('app.color.font_secondary'))
            .width('100%')

          Column() {
            ForEach(POLICY_OPTIONS, (opt: PolicyOption) => {
              Row({ space: 12 }) {
                Circle()
                  .width(18)
                  .height(18)
                  .fill(Color.Transparent)
                  .stroke(this.mode === opt.id ? $r('app.color.accent') : $r('app.color.font_secondary'))
                  .strokeWidth(this.mode === opt.id ? 5 : 1.5)
                Text(opt.label)
                  .fontSize(15)
                  .fontColor($r('app.color.font_primary'))
              }
              .width('100%')
              .height(42)
              .onClick(() => {
                this.mode = opt.id;
              })
            }, (opt: PolicyOption) => opt.id)
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(12)

          this.SectionHeader('GFWList 状态检测')

          this.InfoRowCard('内置规则源', '已预加载 GFWList 回落规则，规则源保持激活。')

          this.SectionHeader('功能说明')

          this.InfoRowCard('智能模式', '优先检测是否为 Cloudflare 站点，是则使用优选 IP 池，否则走 TLS 分片躲避 SNI 阻断。')
          this.InfoRowCard('优先级逻辑', '手动定义的【分流规则】页面条目拥有最高优先级。若均未命中且分流开启，则走此处的自动逻辑。')

          Button('应用并保存设置')
            .type(ButtonType.Normal)
            .borderRadius(12)
            .width('100%')
            .height(40)
            .backgroundColor($r('app.color.card_bg'))
            .fontColor($r('app.color.font_primary'))
            .onClick(() => this.applySettings())

          if (this.notice.length > 0) {
            Text(this.notice)
              .fontSize(12)
              .fontColor($r('app.color.accent'))
              .width('100%')
          }

          Blank().height(24)
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
      }
      .align(Alignment.Top)
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  SectionHeader(text: string) {
    Text(text)
      .fontSize(13)
      .fontColor($r('app.color.accent'))
      .width('100%')
      .padding({ top: 10, bottom: 2 })
  }

  @Builder
  InfoRowCard(title: string, desc: string) {
    Column({ space: 2 }) {
      Text(title)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.font_primary'))
        .width('100%')
      Text(desc)
        .fontSize(12)
        .fontColor($r('app.color.font_secondary'))
        .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(12)
    .alignItems(HorizontalAlign.Start)
  }
}
