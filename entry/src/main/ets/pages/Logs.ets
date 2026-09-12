import { router, LengthMetrics } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { StatusStore } from '../data/StatusStore';
import { LumineCore } from '../service/LumineCore';
import { RuntimeStatus, VpnState } from '../model/VpnTypes';

interface UiLogEntry {
  id: number;
  level: string;
  message: string;
}

interface FilterOption {
  id: string;
  label: string;
}

const FILTER_OPTIONS: FilterOption[] = [
  { id: 'all', label: '全部' },
  { id: 'info', label: '信息' },
  { id: 'error', label: '错误' },
  { id: 'debug', label: '调试' },
  { id: 'other', label: '其他' }
];

const MAX_UI_LOGS: number = 500;

function classifyLine(line: string): string {
  if (line.indexOf('ERROR') >= 0) {
    return 'error';
  }
  if (line.indexOf('DEBUG') >= 0) {
    return 'debug';
  }
  if (line.indexOf('INFO') >= 0) {
    return 'info';
  }
  return 'other';
}

function levelLabel(level: string): string {
  if (level === 'info') {
    return '信息';
  }
  if (level === 'error') {
    return '错误';
  }
  if (level === 'debug') {
    return '调试';
  }
  return '其他';
}

function pad2(n: number): string {
  return n < 10 ? '0' + String(n) : String(n);
}

function pad3(n: number): string {
  if (n < 10) {
    return '00' + String(n);
  }
  if (n < 100) {
    return '0' + String(n);
  }
  return String(n);
}

@Entry
@Component
struct Logs {
  @State logs: UiLogEntry[] = [];
  @State filter: string = 'all';
  @State captureEnabled: boolean = true;
  @State autoscroll: boolean = true;
  @State vpnStage: string = 'idle';
  @State exportMsg: string = '';
  @State exporting: boolean = false;

  private core: LumineCore = LumineCore.getInstance();
  private statusStore: StatusStore | null = null;
  private pollTimer: number = -1;
  private nextId: number = 1;
  private useFileFallback: boolean = false;
  private logFilePath: string = '';
  private logOffset: number = 0;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.statusStore = StatusStore.getInstance(ctx);
    this.loadInitial();
    this.pollTimer = setInterval(() => {
      this.poll();
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
    }
  }

  async loadInitial(): Promise<void> {
    const text: string = this.core.getLogs(0);
    if (text.length > 0) {
      this.appendLines(text);
      return;
    }
    this.useFileFallback = true;
    this.logOffset = 0;
  }

  async readChunk(): Promise<string> {
    if (!this.useFileFallback) {
      return this.core.readNewLogs();
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

  appendLines(text: string): void {
    if (text.length === 0) {
      return;
    }
    const lines: string[] = text.split('\n');
    const fresh: UiLogEntry[] = [];
    for (const line of lines) {
      const t = line.trim();
      if (t.length === 0) {
        continue;
      }
      const entry: UiLogEntry = { id: this.nextId, level: classifyLine(t), message: t };
      this.nextId++;
      fresh.push(entry);
    }
    if (fresh.length === 0) {
      return;
    }
    let merged: UiLogEntry[] = this.logs.concat(fresh);
    if (merged.length > MAX_UI_LOGS) {
      merged = merged.slice(merged.length - MAX_UI_LOGS);
    }
    this.logs = merged;
    if (this.autoscroll) {
      this.scroller.scrollEdge(Edge.Bottom);
    }
  }

  async poll(): Promise<void> {
    if (this.statusStore) {
      const state: VpnState = await this.statusStore.readVpnState();
      this.vpnStage = state.stage;
    }
    if (!this.captureEnabled) {
      return;
    }
    const chunk = await this.readChunk();
    if (chunk.length > 0) {
      this.appendLines(chunk);
    }
  }

  filteredLogs(): UiLogEntry[] {
    if (this.filter === 'all') {
      return this.logs;
    }
    return this.logs.filter((e: UiLogEntry) => e.level === this.filter);
  }

  totalCount(): number {
    return this.logs.length;
  }

  countByLevel(level: string): number {
    let n = 0;
    for (const e of this.logs) {
      if (e.level === level) {
        n++;
      }
    }
    return n;
  }

  hasAnyLogs(): boolean {
    return this.logs.length > 0;
  }

  isCoreActive(): boolean {
    return this.vpnStage === RuntimeStatus.RUNNING || this.vpnStage === RuntimeStatus.STARTING;
  }

  statusMessage(): string {
    if (this.vpnStage === RuntimeStatus.RUNNING) {
      return '运行中';
    }
    if (this.vpnStage === RuntimeStatus.STARTING) {
      return '正在连接代理';
    }
    if (this.vpnStage === RuntimeStatus.STOPPING) {
      return '正在断开代理';
    }
    if (this.vpnStage === RuntimeStatus.ERROR) {
      return '发生错误';
    }
    return '代理未连接';
  }

  levelColor(level: string): ResourceColor {
    if (level === 'error') {
      return $r('app.color.error');
    }
    if (level === 'debug') {
      return $r('app.color.warning');
    }
    if (level === 'info') {
      return $r('app.color.accent');
    }
    return $r('app.color.font_secondary');
  }

  async exportLogs(): Promise<void> {
    if (this.exporting) {
      return;
    }
    if (this.logs.length === 0) {
      this.exportMsg = '无日志可导出';
      return;
    }
    this.exporting = true;
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const dir: string = ctx.filesDir + '/documents';
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
      const now = new Date();
      const stamp: string = String(now.getFullYear()) + pad2(now.getMonth() + 1) + pad2(now.getDate()) +
        '-' + pad2(now.getHours()) + pad2(now.getMinutes()) + pad2(now.getSeconds()) +
        '-' + pad3(now.getMilliseconds());
      const path: string = dir + '/lumine-log-' + stamp + '.txt';
      const lines: string[] = [];
      for (const e of this.logs) {
        lines.push(e.message);
      }
      const exportedAt: string = now.getFullYear() + '-' + pad2(now.getMonth() + 1) + '-' + pad2(now.getDate()) +
        ' ' + pad2(now.getHours()) + ':' + pad2(now.getMinutes()) + ':' + pad2(now.getSeconds());
      const body: string = 'Lumine Log Export\nExported-At: ' + exportedAt +
        '\nLog-Lines: ' + lines.length + '\n\n' + lines.join('\n');
      const fd = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(fd.fd, body);
      fileIo.closeSync(fd);
      this.exportMsg = '已导出到 ' + path;
    } catch (err) {
      this.exportMsg = '导出日志失败';
    } finally {
      this.exporting = false;
    }
  }

  clearLogs(): void {
    this.logs = [];
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Text('<')
            .fontSize(18)
            .fontColor($r('app.color.font_primary'))
            .width(40)
            .height(40)
            .textAlign(TextAlign.Start)
            .onClick(() => router.back())
          Text('系统日志')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.font_primary'))
            .maxLines(1)
            .layoutWeight(1)
          Text(this.captureEnabled ? '停止捕捉' : '开始捕捉')
            .fontSize(13)
            .fontColor(this.captureEnabled ? $r('app.color.error') : $r('app.color.font_secondary'))
            .padding({ left: 4, right: 4 })
            .onClick(() => {
              this.captureEnabled = !this.captureEnabled;
            })
          Text(this.autoscroll ? '暂停滚动' : '继续滚动')
            .fontSize(13)
            .fontColor($r('app.color.font_primary'))
            .padding({ left: 4, right: 4 })
            .onClick(() => {
              this.autoscroll = !this.autoscroll;
            })
          Text('导出')
            .fontSize(13)
            .fontColor($r('app.color.accent'))
            .padding({ left: 4, right: 4 })
            .onClick(() => this.exportLogs())
          Text('清空')
            .fontSize(13)
            .fontColor($r('app.color.error'))
            .padding({ left: 4, right: 4 })
            .onClick(() => this.clearLogs())
        }
        .width('100%')
        .padding({ left: 16, right: 16 })

        Column({ space: 10 }) {
          Text('运行日志')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.font_primary'))
            .width('100%')
          Text(this.statusMessage())
            .fontSize(13)
            .fontColor($r('app.color.font_secondary'))
            .width('100%')
          Row({ space: 8 }) {
            Text(this.captureEnabled ? '日志捕捉中' : '日志捕捉未开启')
              .fontSize(12)
              .fontColor(this.captureEnabled ? $r('app.color.error') : $r('app.color.font_secondary'))
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .backgroundColor($r('app.color.page_bg'))
              .borderRadius(8)
              .onClick(() => {
                this.captureEnabled = !this.captureEnabled;
              })
            Text(this.exporting ? '导出中...' : '导出当前日志')
              .fontSize(12)
              .fontColor($r('app.color.font_primary'))
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .backgroundColor($r('app.color.page_bg'))
              .borderRadius(8)
              .onClick(() => this.exportLogs())
          }
          .width('100%')

          Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
            Text('总计 ' + this.totalCount())
              .fontSize(12)
              .fontColor($r('app.color.font_on_accent'))
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .backgroundColor($r('app.color.accent'))
              .borderRadius(8)
            Text('信息 ' + this.countByLevel('info'))
              .fontSize(12)
              .fontColor($r('app.color.font_primary'))
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .backgroundColor($r('app.color.page_bg'))
              .borderRadius(8)
            Text('错误 ' + this.countByLevel('error'))
              .fontSize(12)
              .fontColor($r('app.color.error'))
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .backgroundColor($r('app.color.page_bg'))
              .borderRadius(8)
            Text('调试 ' + this.countByLevel('debug'))
              .fontSize(12)
              .fontColor($r('app.color.font_secondary'))
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .backgroundColor($r('app.color.page_bg'))
              .borderRadius(8)
          }
          .width('100%')
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.card_bg'))
        .borderRadius(16)
        .margin({ top: 8 })
        .alignItems(HorizontalAlign.Start)

        Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
          ForEach(FILTER_OPTIONS, (opt: FilterOption) => {
            Text(opt.label)
              .fontSize(12)
              .fontColor(this.filter === opt.id ? $r('app.color.font_on_accent') : $r('app.color.font_primary'))
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(this.filter === opt.id ? $r('app.color.accent') : $r('app.color.card_bg'))
              .borderRadius(16)
              .onClick(() => {
                this.filter = opt.id;
              })
          }, (opt: FilterOption) => opt.id)
        }
        .width('100%')
        .margin({ top: 12 })

        if (this.filteredLogs().length === 0) {
          Column({ space: 10 }) {
            if (this.isCoreActive()) {
              LoadingProgress()
                .width(28)
                .height(28)
                .color($r('app.color.accent'))
            }
            Text(this.hasAnyLogs() ? '当前筛选条件下没有日志' : '还没有收到核心日志')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.font_primary'))
              .textAlign(TextAlign.Center)
            Text(this.hasAnyLogs() ? '切换日志级别后再看一次。' : '点击右上角的捕捉按钮后，这里才会开始收集核心日志。')
              .fontSize(13)
              .fontColor($r('app.color.font_secondary'))
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .padding(24)
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(16)
          .margin({ top: 12 })
          .alignItems(HorizontalAlign.Center)
        } else {
          List({ scroller: this.scroller, space: 8 }) {
            ForEach(this.filteredLogs(), (entry: UiLogEntry) => {
              ListItem() {
                Row({ space: 10 }) {
                  Column()
                    .width(8)
                    .height(8)
                    .borderRadius(4)
                    .backgroundColor(this.levelColor(entry.level))
                  Column({ space: 4 }) {
                    Text(levelLabel(entry.level))
                      .fontSize(12)
                      .fontColor(this.levelColor(entry.level))
                      .width('100%')
                    Text(entry.message)
                      .fontSize(12)
                      .fontColor($r('app.color.font_primary'))
                      .width('100%')
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                }
                .width('100%')
                .padding(14)
                .backgroundColor($r('app.color.card_bg'))
                .borderRadius(12)
                .alignItems(VerticalAlign.Top)
              }
            }, (entry: UiLogEntry) => String(entry.id))
          }
          .width('100%')
          .layoutWeight(1)
          .margin({ top: 12 })
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.None)
        }

        if (this.exportMsg.length > 0) {
          Text(this.exportMsg)
            .fontSize(12)
            .fontColor($r('app.color.font_secondary'))
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ top: 8 })
        }
      }
      .align(Alignment.Top)
      .width('100%')
      .height('100%')
      .padding(16)
      .backgroundColor($r('app.color.page_bg'))
    }
    .width('100%')
    .height('100%')
  }
}
