import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { VpnController } from '../service/VpnController';
import { ConfigRepository } from '../data/ConfigRepository';
import { StatusStore } from '../data/StatusStore';
import { LumineCore } from '../service/LumineCore';
import { NotifyService } from '../service/NotifyService';
import { DEFAULT_CONFIG_NAME } from '../common/Constants';
import { RuntimeStatus, VpnState } from '../model/VpnTypes';
import { LumineConfig } from '../model/LumineConfig';
import { formatBytes } from '../common/Formatters';

interface NavItem {
  label: string;
  path: string;
}

const NAV_ITEMS: NavItem[] = [
  { label: '代理节点', path: 'pages/Proxies' },
  { label: '分流规则', path: 'pages/RuleList' },
  { label: '自动分流', path: 'pages/Routing' },
  { label: 'DNS 设置', path: 'pages/Dns' },
  { label: '进化模式', path: 'pages/Evolution' },
  { label: '实时日志', path: 'pages/Logs' },
  { label: '系统设置', path: 'pages/Settings' },
  { label: '关于', path: 'pages/About' }
];

function workModeLabel(mode: string): string {
  if (mode === 'tls-rf') {
    return 'TLS 分片';
  }
  if (mode === 'direct') {
    return '直连';
  }
  if (mode === 'transparent') {
    return '直连';
  }
  if (mode === 'raw') {
    return '原始直连';
  }
  if (mode === 'ttl-d') {
    return 'TTL 探测';
  }
  if (mode === 'block') {
    return '阻断';
  }
  if (mode.length > 0) {
    return mode;
  }
  return 'TLS 分片';
}

@Entry
@Component
struct Index {
  @State vpnStage: string = RuntimeStatus.IDLE;
  @State error: string = '';
  @State configName: string = DEFAULT_CONFIG_NAME;
  @State down: string = '0 B';
  @State up: string = '0 B';
  @State blocked: string = '0';
  @State tcpConns: string = '0';
  @State udpConns: string = '0';
  @State workMode: string = 'TLS 分片';
  @State pendingAction: string = '';
  @State devListening: boolean = false;
  @State devHint: string = '';
  @State socks5Addr: string = '127.0.0.1:1080';
  @State httpAddr: string = '127.0.0.1:1225';

  private statusStore: StatusStore | null = null;
  private repo: ConfigRepository | null = null;
  private controller: VpnController = VpnController.getInstance();
  private core: LumineCore = LumineCore.getInstance();
  private pollTimer: number = -1;
  private localError: string = '';
  private toggleCount: number = 0;
  private toggleWindowStart: number = 0;
  private cooldownUntil: number = 0;
  private statsTick: number = 0;
  private shouldRunMarked: boolean = false;
  private tickBusy: boolean = false;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.statusStore = StatusStore.getInstance(ctx);
    this.repo = ConfigRepository.getInstance(ctx);
    this.initRepo();
    this.startPolling();
  }

  private async initRepo(): Promise<void> {
    const repo = this.repo;
    if (!repo) {
      return;
    }
    try {
      await repo.init();
      const selected = await repo.getSelectedConfigName();
      if (selected.length > 0) {
        this.configName = selected;
      }
      this.loadWorkMode();
      this.checkColdRecovery();
    } catch (err) {
      hilog.error(0x0000, 'LumineUI', 'repo init failed: %{public}s', String(err));
    }
  }

  private async checkColdRecovery(): Promise<void> {
    const repo = this.repo;
    if (!repo || this.isConnected() || this.core.isRunning()) {
      return;
    }
    try {
      const shouldRun = await repo.getVpnShouldRun();
      if (shouldRun && this.vpnStage === RuntimeStatus.IDLE) {
        this.localError = '上次代理异常退出，请重新开启代理';
        this.error = this.localError;
      }
    } catch (err) {
      hilog.error(0x0000, 'LumineUI', 'cold recovery check failed: %{public}s', String(err));
    }
  }

  aboutToDisappear(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
    }
  }

  private loadWorkMode(): void {
    const repo = this.repo;
    if (!repo) {
      return;
    }
    repo.loadConfig(this.configName).then((cfg: LumineConfig | null) => {
      if (cfg) {
        this.workMode = workModeLabel(cfg.default_policy.mode ?? '');
        if (cfg.socks5_address.length > 0) {
          this.socks5Addr = cfg.socks5_address;
        }
        if (cfg.http_address.length > 0) {
          this.httpAddr = cfg.http_address;
        }
      }
    }).catch((err: BusinessError) => {
      hilog.error(0x0000, 'LumineUI', 'loadConfig failed: %{public}s', String(err));
    });
  }

  startPolling(): void {
    this.pollTimer = setInterval(() => {
      this.tick();
    }, 1000);
  }

  private async tick(): Promise<void> {
    if (this.tickBusy || !this.statusStore) {
      return;
    }
    this.tickBusy = true;
    try {
      const state: VpnState = await this.statusStore.readVpnState();
      this.vpnStage = state.stage;
      if (state.stage === RuntimeStatus.RUNNING) {
        this.localError = '';
        if (!this.shouldRunMarked && this.repo) {
          this.shouldRunMarked = true;
          this.repo.setVpnShouldRun(true).catch(() => {});
          this.repo.setLastRunningConfig(this.configName).catch(() => {});
        }
      }
      this.error = state.error || this.localError;
      this.settlePending(state.stage);
      this.syncDevListening();
      this.syncNotification();
      this.statsTick++;
      if (state.stats && this.statsTick % 2 === 0) {
        this.down = formatBytes(state.stats.down);
        this.up = formatBytes(state.stats.up);
        this.blocked = String(state.stats.blocked);
        this.tcpConns = String(state.stats.tcp_conns);
        this.udpConns = String(state.stats.udp_conns);
      }
    } catch (err) {
      hilog.error(0x0000, 'LumineUI', 'poll tick failed: %{public}s', String(err));
    } finally {
      this.tickBusy = false;
    }
  }

  private settlePending(stage: string): void {
    if (this.pendingAction === 'start' && (stage === RuntimeStatus.RUNNING || stage === RuntimeStatus.ERROR)) {
      this.pendingAction = '';
    }
    if (this.pendingAction === 'stop' && (stage === RuntimeStatus.IDLE || stage === RuntimeStatus.ERROR)) {
      this.pendingAction = '';
    }
  }

  private syncDevListening(): void {
    if (this.devListening && !this.core.isRunning()) {
      this.devListening = false;
      const detail: string = this.core.readCoreLog();
      this.devHint = detail.length > 0 ? ('核心已退出：' + detail) : '本地代理监听已停止';
    }
  }

  private syncNotification(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    if (this.isConnected()) {
      NotifyService.update(ctx, true, 'Lumine VPN 运行中',
        '配置 ' + this.configName + ' · 工作模式 ' + this.workMode);
      return;
    }
    if (this.devListening) {
      NotifyService.update(ctx, true, 'Lumine 本地代理监听中',
        'SOCKS5 ' + this.socks5Addr + ' · HTTP ' + this.httpAddr);
      return;
    }
    NotifyService.update(ctx, false, '', '');
  }

  private toggleDevListen(): void {
    if (this.devListening) {
      this.core.stop();
      this.devListening = false;
      this.devHint = '';
      hilog.info(0x0000, 'LumineUI', 'dev listen stopped');
      return;
    }
    if (this.isBusy() || this.isConnected()) {
      this.devHint = 'TUN 代理运行中，请先停止后再开启本地监听';
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    try {
      const err: string = this.core.start(ctx.filesDir, this.configName, -1);
      if (err.length > 0) {
        this.devListening = false;
        this.devHint = err;
        hilog.error(0x0000, 'LumineUI', 'dev listen failed: %{public}s', err);
      } else {
        this.devListening = true;
        this.devHint = '';
        hilog.info(0x0000, 'LumineUI', 'dev listen started: %{public}s / %{public}s',
          this.socks5Addr, this.httpAddr);
      }
    } catch (err) {
      this.devListening = false;
      this.devHint = String(err);
      hilog.error(0x0000, 'LumineUI', 'dev listen threw: %{public}s', String(err));
    }
  }

  private isBusy(): boolean {
    return this.pendingAction.length > 0 ||
      this.vpnStage === RuntimeStatus.STARTING ||
      this.vpnStage === RuntimeStatus.STOPPING;
  }

  private isConnected(): boolean {
    return this.vpnStage === RuntimeStatus.RUNNING;
  }

  private statusTitle(): string {
    if (this.isBusy() && (this.pendingAction === 'stop' || this.vpnStage === RuntimeStatus.STOPPING)) {
      return '正在断开代理';
    }
    if (this.isBusy() && this.isConnected()) {
      return '正在断开代理';
    }
    if (this.isBusy()) {
      return '正在连接代理';
    }
    if (this.isConnected()) {
      return '代理已连接';
    }
    return '代理未连接';
  }

  private statusSummary(): string {
    if (this.error.length > 0) {
      return this.error;
    }
    if (this.pendingAction === 'start') {
      return '正在请求系统 VPN 权限';
    }
    if (this.isConnected()) {
      return '流量经本地隧道转发，保持后台即可继续代理。';
    }
    return '开启后流量将经 Lumine 隧道转发。';
  }

  private statsLine(): string {
    return '↓ ' + this.down + '  ↑ ' + this.up + '  阻断 ' + this.blocked +
      '  TCP ' + this.tcpConns + ' / UDP ' + this.udpConns;
  }

  build() {
    List() {
      ListItem() {
        Column({ space: 2 }) {
          Text('Lumine')
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.font_primary'))
            .width('100%')
          Text('本地代理 · 轻量 VPN 客户端')
            .fontSize(14)
            .fontColor($r('app.color.font_secondary'))
            .width('100%')
        }
        .width('100%')
        .padding({ top: 24, bottom: 6 })
      }

      ListItem() {
        this.StatusCard()
      }

      if (this.isConnected()) {
        ListItem() {
          Text(this.statsLine())
            .fontSize(12)
            .fontColor($r('app.color.font_secondary'))
            .width('100%')
            .margin({ top: 10 })
        }
      }

      ListItem() {
        this.SectionLabel('仪表盘')
      }

      ListItem() {
        Column({ space: 8 }) {
          this.DashboardRow('运行状态', this.isConnected() ? '运行中' : '已停止', this.isConnected())
          this.DashboardRow('工作模式', this.workMode, false)
          this.DashboardRow('TUN', this.isConnected() ? '已就绪' : '未建立', false)
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.card_bg'))
        .borderRadius(16)
      }

      ListItem() {
        this.SectionLabel('配置')
      }

      ListItem() {
        Column() {
          this.MenuCard('配置订阅（移动端）', '当前使用：' + this.configName, 'pages/Subscription')
        }
        .width('100%')
        .margin({ bottom: 4 })
      }

      ListItem() {
        this.SectionLabel('主导航')
      }

      ListItem() {
        Column() {
          ForEach(NAV_ITEMS, (item: NavItem, index: number) => {
            if (index > 0) {
              Divider()
                .color($r('app.color.divider'))
                .strokeWidth(1)
                .margin({ left: 16 })
            }
            Row() {
              Text(item.label)
                .fontSize(16)
                .fontColor($r('app.color.font_primary'))
                .layoutWeight(1)
              Text('>')
                .fontSize(16)
                .fontColor($r('app.color.font_secondary'))
            }
            .width('100%')
            .height(52)
            .padding({ left: 16, right: 16 })
            .onClick(() => {
              hilog.info(0x0000, 'LumineUI', 'Menu clicked: %{public}s -> %{public}s', item.label, item.path);
              router.pushUrl({ url: item.path });
            })
          }, (item: NavItem) => item.path)
        }
        .width('100%')
        .backgroundColor($r('app.color.card_bg'))
        .borderRadius(16)
        .clip(true)
        .margin({ bottom: 12 })
      }

      ListItem() {
        this.SectionLabel('开发者')
      }

      ListItem() {
        Column({ space: 10 }) {
          Row() {
            Column({ space: 2 }) {
              Text('本地代理监听')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.font_primary'))
                .width('100%')
              Text(this.socks5Addr + ' · ' + this.httpAddr)
                .fontSize(12)
                .fontColor($r('app.color.font_secondary'))
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Text(this.devListening ? '监听中' : '未监听')
              .fontSize(13)
              .fontColor(this.devListening ? $r('app.color.success') : $r('app.color.font_secondary'))
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Text('不走 TUN 隧道，只在回环地址上提供 SOCKS5 / HTTP 代理，供终端或浏览器手动指定代理时使用。端口可在「系统设置」中修改。')
            .fontSize(12)
            .fontColor($r('app.color.font_secondary'))
            .lineHeight(18)
            .width('100%')

          Button(this.devListening ? '停止代理监听（开发者）' : '开启代理监听（开发者）')
            .type(ButtonType.Capsule)
            .width('100%')
            .height(40)
            .backgroundColor(this.devListening ? $r('app.color.error') : $r('app.color.card_bg'))
            .fontColor(this.devListening ? $r('app.color.font_on_accent') : $r('app.color.font_primary'))
            .borderWidth(1)
            .borderColor($r('app.color.divider'))
            .onClick(() => {
              this.toggleDevListen();
            })

          if (this.devHint.length > 0) {
            Text(this.devHint)
              .fontSize(12)
              .fontColor($r('app.color.error'))
              .width('100%')
          }
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.card_bg'))
        .borderRadius(16)
        .margin({ bottom: 24 })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('app.color.page_bg'))
    .divider({ strokeWidth: 0 })
    .edgeEffect(EdgeEffect.None)
    .scrollBar(BarState.Off)
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
  StatusCard() {
    Column({ space: 14 }) {
      Row() {
        Column({ space: 4 }) {
          Text(this.statusTitle())
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.font_primary'))
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.statusSummary())
            .fontSize(13)
            .fontColor(this.error.length > 0 ? $r('app.color.error') : $r('app.color.font_secondary'))
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ right: 12 })

        if (this.isBusy()) {
          LoadingProgress()
            .width(28)
            .height(28)
            .color($r('app.color.accent'))
        } else {
          Toggle({ type: ToggleType.Switch, isOn: this.isConnected() })
            .selectedColor($r('app.color.accent'))
            .onChange(() => {
              this.toggleVpn();
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(20)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(16)
    .onClick(() => {
      this.toggleVpn();
    })
  }

  @Builder
  DashboardRow(label: string, value: string, showDot: boolean) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontColor($r('app.color.font_secondary'))
        .width(88)
      if (showDot) {
        Column()
          .width(8)
          .height(8)
          .borderRadius(4)
          .backgroundColor($r('app.color.accent'))
          .margin({ right: 8 })
      }
      Text(value)
        .fontSize(14)
        .fontColor($r('app.color.font_primary'))
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  MenuCard(title: string, subtitle: string, path: string) {
    Row() {
      Column({ space: 4 }) {
        Text(title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.font_primary'))
          .width('100%')
        Text(subtitle)
          .fontSize(13)
          .fontColor($r('app.color.font_secondary'))
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text('>')
        .fontSize(16)
        .fontColor($r('app.color.font_secondary'))
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(16)
    .onClick(() => {
      hilog.info(0x0000, 'LumineUI', 'Menu clicked: %{public}s -> %{public}s', title, path);
      router.pushUrl({ url: path });
    })
  }

  private toggleVpn(): void {
    if (this.isBusy()) {
      return;
    }
    const now = Date.now();
    if (now < this.cooldownUntil) {
      this.localError = '点击频率过高，请 ' + Math.ceil((this.cooldownUntil - now) / 1000) + ' 秒后再试';
      this.error = this.localError;
      return;
    }
    if (now - this.toggleWindowStart > 2000) {
      this.toggleWindowStart = now;
      this.toggleCount = 0;
    }
    this.toggleCount++;
    if (this.toggleCount > 5) {
      this.cooldownUntil = now + 3000;
      this.toggleCount = 0;
      this.localError = '点击频率过高，请 3 秒后再试';
      this.error = this.localError;
      return;
    }
    if (this.devListening) {
      this.core.stop();
      this.devListening = false;
      this.devHint = '';
      hilog.info(0x0000, 'LumineUI', 'dev listen stopped before starting TUN');
    }
    if (this.isConnected()) {
      this.pendingAction = 'stop';
      this.stopVpn();
    } else {
      this.pendingAction = 'start';
      this.startVpn();
    }
  }

  async startVpn(): Promise<void> {
    hilog.info(0x0000, 'LumineUI', 'startVpn called');
    this.localError = '';
    this.error = '';
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      await this.controller.startVpn(ctx, this.configName);
      hilog.info(0x0000, 'LumineUI', 'startVpn resolve returned, waiting for extension');
    } catch (err) {
      const e = err as BusinessError;
      this.localError = e.code ? `[${e.code}] ${e.message}` : String(err);
      this.error = this.localError;
      this.pendingAction = '';
      hilog.error(0x0000, 'LumineUI', 'startVpn failed: %{public}s', this.localError);
    }
  }

  async stopVpn(): Promise<void> {
    this.localError = '';
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      if (this.statusStore) {
        await this.statusStore.writeVpnState({
          stage: RuntimeStatus.STOPPING,
          updatedAt: Date.now()
        });
        this.vpnStage = RuntimeStatus.STOPPING;
      }
      if (this.repo) {
        this.repo.setVpnShouldRun(false).catch(() => {});
        this.shouldRunMarked = false;
      }
      await this.controller.stopVpn(ctx);
    } catch (err) {
      const e = err as BusinessError;
      this.localError = e.code ? `[${e.code}] ${e.message}` : String(err);
      this.error = this.localError;
      this.pendingAction = '';
      hilog.error(0x0000, 'LumineUI', 'stopVpn failed: %{public}s', this.localError);
    }
  }
}
