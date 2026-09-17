import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { connection, socket } from '@kit.NetworkKit';
import { ConfigRepository } from '../data/ConfigRepository';
import { PrefsStore } from '../data/PrefsStore';
import { NetworkMonitor, mapNat64 } from '../service/NetworkMonitor';
import { LumineConfig, Policy } from '../model/LumineConfig';
import { sanitizeNAT64Profiles } from '../model/VpnTypes';

interface EvoResult {
  domain: string;
  method: string;
  delayMs: number;
  ok: boolean;
}

const TAB_LABELS: string[] = ['测试', '规则', '结果'];

function isIpLiteral(host: string): boolean {
  if (host.indexOf(':') >= 0) {
    return true;
  }
  const segs = host.split('.');
  if (segs.length !== 4) {
    return false;
  }
  for (let i = 0; i < 4; i++) {
    if (segs[i].length === 0 || segs[i].length > 3) {
      return false;
    }
    for (let j = 0; j < segs[i].length; j++) {
      const c = segs[i].charCodeAt(j);
      if (c < 48 || c > 57) {
        return false;
      }
    }
  }
  return true;
}

@Entry
@Component
struct Evolution {
  @State tab: number = 0;
  @State config: LumineConfig | null = null;
  @State domainsText: string = '';
  @State enableIpv6: boolean = false;
  @State running: boolean = false;
  @State progress: number = 0;
  @State total: number = 0;
  @State entries: EvoResult[] = [];
  @State tempRules: string[] = [];
  @State converting: string = '';
  @State notice: string = '';
  @State ipv6Ok: boolean = false;
  @State nat64Prefix: string = '';

  private repo: ConfigRepository | null = null;
  private monitor: NetworkMonitor = NetworkMonitor.getInstance();

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.repo = ConfigRepository.getInstance(ctx);
    this.repo.init().then(() => {
      this.loadConfig();
    });
    this.refreshNetworkState();
  }

  async loadConfig(): Promise<void> {
    if (!this.repo) {
      return;
    }
    this.config = await this.repo.loadConfig('config');
  }

  async refreshNetworkState(): Promise<void> {
    this.ipv6Ok = await this.monitor.checkIpv6Available();
    let prefix = await this.monitor.detectNat64Prefix();
    if (prefix.length === 0) {
      try {
        const ctx = getContext(this) as common.UIAbilityContext;
        const prefs = await PrefsStore.getInstance(ctx);
        const raw = await prefs.getString('nat64Profiles', '');
        const profiles = sanitizeNAT64Profiles(raw);
        if (profiles.length > 0) {
          prefix = profiles[0].prefix;
        }
      } catch (err) {
      }
    }
    this.nat64Prefix = prefix;
  }

  ipv6Usable(): boolean {
    return this.ipv6Ok || this.nat64Prefix.length > 0;
  }

  parseDomains(): string[] {
    const parts: string[] = this.domainsText.split(/[\s,;\n]+/);
    const out: string[] = [];
    for (const p of parts) {
      const t = p.trim().toLowerCase();
      if (t.length > 0) {
        out.push(t);
      }
    }
    return out;
  }

  async startTest(): Promise<void> {
    if (this.running) {
      return;
    }
    const list = this.parseDomains();
    if (list.length === 0) {
      return;
    }
    this.running = true;
    this.total = list.length;
    this.progress = 0;
    this.entries = [];
    this.tempRules = [];
    this.notice = '开始测试 ' + list.length + ' 个域名';
    const results: EvoResult[] = [];
    for (let i = 0; i < list.length; i++) {
      if (!this.running) {
        break;
      }
      this.progress = i;
      const domain = list[i];
      const direct = await this.probeTcp(domain, 443);
      if (direct >= 0) {
        const entry: EvoResult = { domain: domain, method: '直连', delayMs: direct, ok: true };
        results.push(entry);
      } else {
        let mapped = -1;
        if (this.enableIpv6 && this.nat64Prefix.length > 0) {
          mapped = await this.probeNat64(domain, this.nat64Prefix);
        }
        if (mapped >= 0) {
          const entry: EvoResult = { domain: domain, method: 'TLS分片 (NAT64)', delayMs: mapped, ok: true };
          results.push(entry);
        } else {
          const entry: EvoResult = { domain: domain, method: '不可达', delayMs: -1, ok: false };
          results.push(entry);
        }
      }
    }
    this.progress = list.length;
    this.entries = results;
    const okDomains: string[] = [];
    for (const r of results) {
      if (r.ok) {
        okDomains.push(r.domain);
      }
    }
    this.tempRules = okDomains;
    this.running = false;
    this.notice = '测试完成，共 ' + results.length + ' 个域名';
  }

  async resolveAddresses(host: string): Promise<string[]> {
    if (isIpLiteral(host)) {
      return [host];
    }
    try {
      const netHandle = await connection.getDefaultNet();
      const addrs = await netHandle.getAddressesByName(host);
      const v4: string[] = [];
      const v6: string[] = [];
      for (const a of addrs) {
        if (a.address.indexOf(':') >= 0) {
          v6.push(a.address);
        } else {
          v4.push(a.address);
        }
      }
      return v4.concat(v6);
    } catch (err) {
      return [];
    }
  }

  async tcpConnectMs(address: string, port: number, timeout: number): Promise<number> {
    const family: number = address.indexOf(':') >= 0 ? 2 : 1;
    const s = socket.constructTCPSocketInstance();
    const start = Date.now();
    try {
      await s.bind({ address: family === 2 ? '::' : '0.0.0.0', port: 0, family: family });
      await s.connect({ address: { address: address, port: port, family: family }, timeout: timeout });
      return Date.now() - start;
    } catch (err) {
      return -1;
    } finally {
      try {
        s.close();
      } catch (e) {
      }
    }
  }

  async probeTcp(host: string, port: number): Promise<number> {
    const addrs = await this.resolveAddresses(host);
    for (const a of addrs) {
      const ms = await this.tcpConnectMs(a, port, 3000);
      if (ms >= 0) {
        return ms;
      }
    }
    return -1;
  }

  async probeNat64(domain: string, prefix: string): Promise<number> {
    try {
      const netHandle = await connection.getDefaultNet();
      const addrs = await netHandle.getAddressesByName(domain);
      let v4 = '';
      for (const a of addrs) {
        if (a.address.indexOf(':') < 0) {
          v4 = a.address;
          break;
        }
      }
      if (v4.length === 0) {
        return -1;
      }
      const mapped = mapNat64(v4, prefix);
      if (mapped === null) {
        return this.tcpConnectMs(v4, 443, 4000);
      }
      const s = socket.constructTCPSocketInstance();
      const start = Date.now();
      try {
        await s.bind({ address: '::', port: 0, family: 2 });
        await s.connect({ address: { address: mapped, port: 443, family: 2 }, timeout: 4000 });
        return Date.now() - start;
      } catch (err) {
        return this.tcpConnectMs(v4, 443, 4000);
      } finally {
        try {
          s.close();
        } catch (e) {
        }
      }
    } catch (err) {
      return -1;
    }
  }

  hasPolicy(domain: string): boolean {
    if (!this.config || !this.config.domain_policies) {
      return false;
    }
    return this.config.domain_policies[domain] !== undefined;
  }

  pendingDomains(): string[] {
    const out: string[] = [];
    for (const d of this.tempRules) {
      if (!this.hasPolicy(d)) {
        out.push(d);
      }
    }
    return out.sort();
  }

  convertedCount(): number {
    let n = 0;
    for (const e of this.entries) {
      if (e.ok && this.hasPolicy(e.domain)) {
        n++;
      }
    }
    return n;
  }

  totalOkCount(): number {
    let n = 0;
    for (const e of this.entries) {
      if (e.ok) {
        n++;
      }
    }
    return n;
  }

  okCount(): number {
    let n = 0;
    for (const e of this.entries) {
      if (e.ok) {
        n++;
      }
    }
    return n;
  }

  failCount(): number {
    return this.entries.length - this.okCount();
  }

  async confirmConvert(): Promise<void> {
    const domain = this.converting;
    this.converting = '';
    if (domain.length === 0 || !this.repo || !this.config) {
      return;
    }
    if (!this.config.domain_policies) {
      this.config.domain_policies = {};
    }
    const policy: Policy = { mode: 'direct' };
    this.config.domain_policies[domain] = policy;
    await this.repo.saveConfig('config', this.config);
    this.tempRules = this.tempRules.filter((d: string) => d !== domain);
    this.notice = '规则 "' + domain + '" 已转为正式规则';
  }

  domainCount(): number {
    return this.parseDomains().length;
  }

  progressPct(): number {
    if (this.total <= 0) {
      return 0;
    }
    return Math.min(100, Math.round(this.progress * 100 / this.total));
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
          Column({ space: 2 }) {
            Text('进化模式')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.font_primary'))
              .width('100%')
            Text('自动测试域名连通性并生成最优规则')
              .fontSize(12)
              .fontColor($r('app.color.font_secondary'))
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding({ left: 16, right: 16 })

        Row({ space: 8 }) {
          ForEach(TAB_LABELS, (label: string, i: number) => {
            Button(label)
              .type(ButtonType.Capsule)
              .layoutWeight(1)
              .height(36)
              .backgroundColor(this.tab === i ? $r('app.color.accent') : $r('app.color.card_bg'))
              .fontColor(this.tab === i ? $r('app.color.font_on_accent') : $r('app.color.font_primary'))
              .onClick(() => {
                this.tab = i;
              })
          }, (label: string) => label)
        }
        .width('100%')
        .margin({ top: 8 })
        .padding({ left: 16, right: 16 })

        Scroll() {
          Column({ space: 12 }) {
            if (this.tab === 0) {
              this.TestTab()
            }
            if (this.tab === 1) {
              this.RulesTab()
            }
            if (this.tab === 2) {
              this.ResultsTab()
            }
          }
          .width('100%')
          .padding(16)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Off)

        if (this.notice.length > 0) {
          Text(this.notice)
            .fontSize(12)
            .fontColor($r('app.color.accent'))
            .width('100%')
            .padding({ left: 16, right: 16, top: 6, bottom: 6 })
        }
      }
      .align(Alignment.Top)
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))

      if (this.converting.length > 0) {
        this.ConvertDialog()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  TestTab() {
    this.SectionHeader('域名列表')
    Text(this.domainCount() + ' 个')
      .fontSize(12)
      .fontColor($r('app.color.font_secondary'))
      .width('100%')
    Column({ space: 6 }) {
      TextArea({ text: this.domainsText, placeholder: 'example.com\ntest.com\ndemo.org' })
        .width('100%')
        .height(96)
        .fontSize(14)
        .backgroundColor(Color.Transparent)
        .onChange((v: string) => {
          this.domainsText = v;
        })
      Text('每行一个域名，支持批量粘贴')
        .fontSize(11)
        .fontColor($r('app.color.font_secondary'))
        .width('100%')
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(12)

    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text('启用 IPv6')
          .fontSize(15)
          .fontColor($r('app.color.font_primary'))
          .width('100%')
        Text(this.ipv6Usable() ? '不可达域名将通过 NAT64 前缀再次探测' : '当前网络为纯 IPv4（未检测到 NAT64 前缀），不可用')
          .fontSize(12)
          .fontColor($r('app.color.font_secondary'))
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: this.enableIpv6 })
        .enabled(this.ipv6Usable())
        .onChange((on: boolean) => {
          if (this.ipv6Usable()) {
            this.enableIpv6 = on;
          }
        })
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(12)
    .alignItems(VerticalAlign.Center)

    if (this.running) {
      this.SectionHeader('测试进度')
      Column({ space: 6 }) {
        Progress({ value: this.progressPct(), total: 100, type: ProgressType.Linear })
          .width('100%')
        Text(this.total > this.progress ? '正在测试第 ' + (this.progress + 1) + ' 个域名...' : '测试完成')
          .fontSize(12)
          .fontColor($r('app.color.font_secondary'))
          .width('100%')
      }
      .width('100%')
    }

    this.SectionHeader('测试流程')
    Text('直连探测 → NAT64 探测 → 生成临时规则；成功后自动生成临时规则，在「规则」页面可转为正式规则')
      .fontSize(12)
      .fontColor($r('app.color.font_secondary'))
      .width('100%')

    Button('开始测试')
      .type(ButtonType.Normal)
      .borderRadius(12)
      .width('100%')
      .height(40)
      .backgroundColor($r('app.color.accent'))
      .fontColor($r('app.color.font_on_accent'))
      .enabled(!this.running && this.domainsText.trim().length > 0)
      .onClick(() => this.startTest())
  }

  @Builder
  RulesTab() {
    if (this.pendingDomains().length === 0) {
      Column({ space: 4 }) {
        Text('暂无生成的规则')
          .fontSize(14)
          .fontColor($r('app.color.font_secondary'))
          .width('100%')
        Text('完成测试后，成功的域名将生成临时规则')
          .fontSize(12)
          .fontColor($r('app.color.font_secondary'))
          .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    this.SectionHeader('临时规则')
    Text('已应用: ' + this.convertedCount() + ' / ' + this.totalOkCount())
      .fontSize(12)
      .fontColor($r('app.color.font_secondary'))
      .width('100%')
    ForEach(this.pendingDomains(), (domain: string) => {
      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Text(domain)
            .fontSize(15)
            .fontColor($r('app.color.font_primary'))
          Text('直连')
            .fontSize(12)
            .fontColor($r('app.color.font_secondary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button('转为正式')
          .type(ButtonType.Normal)
          .borderRadius(12)
          .height(32)
          .fontSize(13)
          .backgroundColor($r('app.color.card_bg'))
          .fontColor($r('app.color.font_primary'))
          .onClick(() => {
            this.converting = domain;
          })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .backgroundColor($r('app.color.card_bg'))
      .borderRadius(12)
      .alignItems(VerticalAlign.Center)
    }, (domain: string) => domain)
  }

  @Builder
  ResultsTab() {
    if (this.entries.length === 0) {
      Column({ space: 4 }) {
        Text('暂无测试结果')
          .fontSize(14)
          .fontColor($r('app.color.font_secondary'))
          .width('100%')
        Text('在「测试」页面输入域名并开始测试')
          .fontSize(12)
          .fontColor($r('app.color.font_secondary'))
          .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    } else {
      this.SectionHeader('测试结果')
      Text(this.okCount() + ' 成功 · ' + this.failCount() + ' 失败')
        .fontSize(12)
        .fontColor($r('app.color.font_secondary'))
        .width('100%')
      ForEach(this.entries, (e: EvoResult, i: number) => {
        Row({ space: 12 }) {
          Column({ space: 2 }) {
            Text(e.domain)
              .fontSize(15)
              .fontColor($r('app.color.font_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(e.method)
              .fontSize(12)
              .fontColor($r('app.color.font_secondary'))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Text(!e.ok ? '不可达' : (e.delayMs >= 0 ? e.delayMs + 'ms' : ''))
            .fontSize(12)
            .fontColor(e.ok ? $r('app.color.font_secondary') : $r('app.color.error'))
        }
        .width('100%')
        .padding({ top: 8, bottom: 8 })
        .alignItems(VerticalAlign.Center)
      }, (e: EvoResult, i: number) => i + ':' + e.domain + ':' + e.method)
    }
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
  ConvertDialog() {
    Column({ space: 12 }) {
      Text('确认转为正式规则')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.font_primary'))
        .width('100%')
      Text('确定要将以下规则转为正式规则并写入配置吗？')
        .fontSize(13)
        .fontColor($r('app.color.font_secondary'))
        .width('100%')
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .backgroundColor($r('app.color.card_bg'))
          .fontColor($r('app.color.font_primary'))
          .onClick(() => {
            this.converting = '';
          })
        Button('确认转换')
          .layoutWeight(1)
          .backgroundColor($r('app.color.accent'))
          .fontColor($r('app.color.font_on_accent'))
          .onClick(() => this.confirmConvert())
      }
      .width('100%')
    }
    .width('92%')
    .padding(16)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(16)
  }
}
