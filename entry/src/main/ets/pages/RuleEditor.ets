import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { NetworkMonitor } from '../service/NetworkMonitor';
import { ConfigRepository } from '../data/ConfigRepository';
import { PrefsStore } from '../data/PrefsStore';
import { LumineConfig, Policy } from '../model/LumineConfig';

interface ModeOption {
  id: string;
  label: string;
  desc: string;
  usable: boolean;
}

interface DnsOption {
  id: string;
  label: string;
}

interface Nat64Preset {
  name: string;
  prefix: string;
}

const DEFAULT_NAT64_PREFIX: string = '2001:67c:2960:6464::';

const MODE_OPTIONS: ModeOption[] = [
  { id: 'tls-rf', label: 'TLS 分片', desc: 'TLS 分片/记录重排，抗 SNI 阻断', usable: true },
  { id: 'transparent', label: '透传', desc: '不解密 TLS，仅透传', usable: true },
  { id: 'raw', label: '原始直连', desc: '不经任何处理的原始直连', usable: true },
  { id: 'ttl-d', label: 'TTL 探测', desc: 'TTL desync 抗封锁探测', usable: true },
  { id: 'block', label: '阻断', desc: '匹配后直接阻断连接', usable: true },
  { id: 'mitm', label: 'MITM', desc: '需 CA 证书，移动端不支持', usable: false },
  { id: 'quic', label: 'QUIC 分片混淆', desc: '桌面代理专有，移动端不支持', usable: false },
  { id: 'migration', label: '会话恢复', desc: '依赖 TLS 会话票据重写（桌面代理专有），移动端不支持。', usable: false }
];

const DNS_OPTIONS: DnsOption[] = [
  { id: '', label: '默认' },
  { id: 'prefer_ipv4', label: 'IPv4 优先' },
  { id: 'prefer_ipv6', label: 'IPv6 优先' },
  { id: 'ipv4_only', label: '仅 IPv4' },
  { id: 'ipv6_only', label: '仅 IPv6' }
];

const NAT64_PRESETS: Nat64Preset[] = [
  { name: 'level66', prefix: '2001:67c:2960:6464::' },
  { name: 'nat64.net', prefix: '2a01:4f9:c010:3f02:64::' },
  { name: 'ZTVI', prefix: '2602:fc59:11:64::' }
];

function countChar(t: string, ch: string): number {
  let n = 0;
  for (let i = 0; i < t.length; i++) {
    if (t.charAt(i) === ch) {
      n++;
    }
  }
  return n;
}

function sanitizeHost(raw: string): string {
  const t = raw.trim();
  if (t.length === 0) {
    return '';
  }
  if (countChar(t, ':') === 1) {
    return t.substring(0, t.indexOf(':')).trim();
  }
  return t;
}

function parseIntOrNull(text: string): number | null {
  const t = text.trim();
  if (t.length === 0) {
    return null;
  }
  for (let i = 0; i < t.length; i++) {
    const c = t.charCodeAt(i);
    if (c < 48 || c > 57) {
      return null;
    }
  }
  return Number(t);
}

function filterDigits(raw: string): string {
  let out = '';
  for (let i = 0; i < raw.length; i++) {
    const c = raw.charCodeAt(i);
    if (c >= 48 && c <= 57) {
      out += raw.charAt(i);
    }
  }
  return out;
}

@Entry
@Component
struct RuleEditor {
  @State ruleKey: string = '';
  @State editableKey: string = '';
  @State tab: number = 0;
  @State isNewRule: boolean = false;
  @State config: LumineConfig | null = null;
  @State mode: string = 'tls-rf';
  @State host: string = '';
  @State mapTo: string = '';
  @State dnsMode: string = '';
  @State tls13Only: boolean = false;
  @State nat64Enabled: boolean = false;
  @State nat64Prefix: string = DEFAULT_NAT64_PREFIX;
  @State numRecordsText: string = '';
  @State numSegsText: string = '';
  @State oob: boolean = false;
  @State waitForAck: boolean = false;
  @State ipv6Available: boolean = true;
  @State statusMsg: string = '';
  @State errorMsg: string = '';

  private repo: ConfigRepository | null = null;
  private prefs: PrefsStore | null = null;
  private initialPolicy: Policy = {};

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, string>;
    this.ruleKey = decodeURIComponent(params['key'] || '');
    this.tab = Number(params['tab'] || 0);
    this.editableKey = this.ruleKey;
    const ctx = getContext(this) as common.UIAbilityContext;
    this.repo = ConfigRepository.getInstance(ctx);
    PrefsStore.getInstance(ctx).then((p: PrefsStore) => {
      this.prefs = p;
      this.loadIpv6Cache();
      this.probeIpv6();
    });
    this.repo.init().then(() => {
      this.loadPolicy();
    });
  }

  private async loadIpv6Cache(): Promise<void> {
    if (!this.prefs) {
      return;
    }
    const cached = await this.prefs.getString('ipv6Available', '');
    this.ipv6Available = cached !== '0';
  }

  private async probeIpv6(): Promise<void> {
    const ok = await NetworkMonitor.getInstance().checkIpv6Available();
    if (this.prefs) {
      await this.prefs.setString('ipv6Available', ok ? '1' : '0');
    }
    this.ipv6Available = ok;
  }

  private modeDisplay(): string {
    return this.mode === 'direct' ? 'transparent' : this.mode;
  }

  private dnsDisabled(id: string): boolean {
    return (id === 'prefer_ipv6' || id === 'ipv6_only') && !this.ipv6Available;
  }

  private isChecked(kind: string): boolean {
    if (kind === 'tls13') {
      return this.tls13Only;
    }
    if (kind === 'nat64') {
      return this.nat64Enabled;
    }
    if (kind === 'oob') {
      return this.oob;
    }
    return this.waitForAck;
  }

  private toggleCheck(kind: string): void {
    if (kind === 'tls13') {
      this.tls13Only = !this.tls13Only;
      return;
    }
    if (kind === 'nat64') {
      this.toggleNat64();
      return;
    }
    if (kind === 'oob') {
      this.oob = !this.oob;
      return;
    }
    this.waitForAck = !this.waitForAck;
  }

  private toggleNat64(): void {
    this.nat64Enabled = !this.nat64Enabled;
    if (!this.nat64Enabled) {
      this.nat64Prefix = '';
    } else if (this.nat64Prefix.trim().length === 0) {
      this.nat64Prefix = DEFAULT_NAT64_PREFIX;
    }
  }

  async loadPolicy(): Promise<void> {
    if (!this.repo) {
      return;
    }
    this.config = await this.repo.loadConfig('config');
    const cfg = this.config;
    if (!cfg) {
      return;
    }
    const map = this.tab === 0 ? cfg.domain_policies : cfg.ip_policies;
    const p: Policy | undefined = map[this.ruleKey];
    this.isNewRule = p === undefined || p === null;
    const src: Policy = p !== undefined && p !== null ? p : {};
    this.initialPolicy = src;
    this.mode = src.mode !== undefined && src.mode !== null && src.mode.length > 0 ? src.mode : 'tls-rf';
    this.host = src.host !== undefined && src.host !== null ? src.host : '';
    this.mapTo = src.map_to !== undefined && src.map_to !== null ? src.map_to : '';
    this.dnsMode = src.dns_mode !== undefined && src.dns_mode !== null ? src.dns_mode : '';
    this.tls13Only = src.tls13_only === true;
    const np = src.nat64_prefix;
    this.nat64Prefix = np !== undefined && np !== null ? np : DEFAULT_NAT64_PREFIX;
    this.nat64Enabled = this.nat64Prefix.trim().length > 0;
    const nr = src.num_records;
    this.numRecordsText = nr !== undefined && nr !== null ? String(nr) : '';
    const ns = src.num_segs;
    this.numSegsText = ns !== undefined && ns !== null ? String(ns) : '';
    this.oob = src.oob === true;
    this.waitForAck = src.wait_for_ack === true;
    this.editableKey = this.ruleKey;
  }

  private buildUpdatedPolicy(): Policy {
    const p: Policy = {};
    const src: Policy = this.initialPolicy;
    if (src.reply_first !== undefined && src.reply_first !== null) {
      p.reply_first = src.reply_first;
    }
    if (src.sniff_override !== undefined && src.sniff_override !== null) {
      p.sniff_override = src.sniff_override;
    }
    if (src.dns_cache_ttl !== undefined && src.dns_cache_ttl !== null) {
      p.dns_cache_ttl = src.dns_cache_ttl;
    }
    if (src.connect_timeout !== undefined && src.connect_timeout !== null) {
      p.connect_timeout = src.connect_timeout;
    }
    if (src.http_status !== undefined && src.http_status !== null) {
      p.http_status = src.http_status;
    }
    if (src.minor_ver !== undefined && src.minor_ver !== null) {
      p.minor_ver = src.minor_ver;
    }
    if (src.send_interval !== undefined && src.send_interval !== null) {
      p.send_interval = src.send_interval;
    }
    if (src.oob_ex !== undefined && src.oob_ex !== null) {
      p.oob_ex = src.oob_ex;
    }
    if (src.fake_ttl !== undefined && src.fake_ttl !== null) {
      p.fake_ttl = src.fake_ttl;
    }
    if (src.fake_sleep !== undefined && src.fake_sleep !== null) {
      p.fake_sleep = src.fake_sleep;
    }
    if (src.attempts !== undefined && src.attempts !== null) {
      p.attempts = src.attempts;
    }
    if (src.max_ttl !== undefined && src.max_ttl !== null) {
      p.max_ttl = src.max_ttl;
    }
    if (src.single_timeout !== undefined && src.single_timeout !== null) {
      p.single_timeout = src.single_timeout;
    }
    if (src.ttl_cache_ttl !== undefined && src.ttl_cache_ttl !== null) {
      p.ttl_cache_ttl = src.ttl_cache_ttl;
    }
    p.mode = this.mode;
    const h = sanitizeHost(this.host);
    if (h.length > 0) {
      p.host = h;
    }
    if (this.mapTo.length > 0) {
      p.map_to = this.mapTo;
    }
    if (this.dnsMode.length > 0) {
      p.dns_mode = this.dnsMode;
    }
    p.tls13_only = this.tls13Only;
    if (this.nat64Enabled && this.nat64Prefix.trim().length > 0) {
      p.nat64_prefix = this.nat64Prefix.trim();
    }
    const nr = parseIntOrNull(this.numRecordsText);
    if (nr !== null && nr > 0) {
      p.num_records = nr;
    }
    const ns = parseIntOrNull(this.numSegsText);
    if (ns !== null && ns > 0) {
      p.num_segs = ns;
    }
    p.oob = this.oob;
    p.wait_for_ack = this.waitForAck;
    return p;
  }

  async savePolicy(): Promise<void> {
    if (!this.repo || !this.config) {
      return;
    }
    const newKey = this.editableKey.trim();
    if (newKey.length === 0) {
      this.errorMsg = '规则主键不能为空';
      this.statusMsg = '';
      return;
    }
    const policy = this.buildUpdatedPolicy();
    if (newKey !== this.ruleKey) {
      const map = this.tab === 0 ? this.config.domain_policies : this.config.ip_policies;
      const next: Record<string, Policy> = {};
      const keys: string[] = Object.keys(map);
      for (const k of keys) {
        if (k !== this.ruleKey) {
          next[k] = map[k];
        }
      }
      next[newKey] = policy;
      if (this.tab === 0) {
        this.config.domain_policies = next;
      } else {
        this.config.ip_policies = next;
      }
      const oldDisabled = await this.repo.disabledRuleKeys('config');
      const wasDisabled = oldDisabled.indexOf(this.ruleKey) >= 0;
      await this.repo.setRuleEnabled('config', this.config, this.ruleKey, true);
      if (wasDisabled) {
        await this.repo.setRuleEnabled('config', this.config, newKey, false);
      } else {
        await this.repo.setRuleEnabled('config', this.config, newKey, true);
      }
    } else {
      if (this.tab === 0) {
        this.config.domain_policies[this.ruleKey] = policy;
      } else {
        this.config.ip_policies[this.ruleKey] = policy;
      }
    }
    await this.repo.saveConfig('config', this.config);
    this.ruleKey = newKey;
    this.initialPolicy = policy;
    this.isNewRule = false;
    this.errorMsg = '';
    this.statusMsg = '已保存';
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
            Text(this.isNewRule ? '新建规则' : '编辑规则')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.font_primary'))
              .layoutWeight(1)
            Text('保存')
              .fontSize(15)
              .fontColor($r('app.color.accent'))
              .height(40)
              .padding({ left: 12, right: 12 })
              .onClick(() => this.savePolicy())
          }
          .width('100%')

          Column({ space: 8 }) {
            this.InputLabel('规则路径')
            TextInput({ text: this.editableKey, placeholder: this.tab === 0 ? '例如 *.bing.com' : '例如 1.2.3.0/24' })
              .width('100%')
              .onChange((v: string) => {
                this.editableKey = v;
              })
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(12)

          this.SectionHeader('代理模式')

          Column() {
            ForEach(MODE_OPTIONS, (opt: ModeOption) => {
              this.RadioRowMode(opt.id, opt.label, opt.desc, opt.usable)
            }, (opt: ModeOption) => opt.id)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 4 })
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(12)

          this.SectionHeader('上游服务器 (Upstream)')

          Column({ space: 8 }) {
            this.InputLabel('上游服务器 (Upstream)')
            TextInput({ text: this.host, placeholder: '留空直连，或填写 IP / 域名（如 1.2.3.4）' })
              .width('100%')
              .onChange((v: string) => {
                this.host = v;
              })
            Text('仅接受单个 IP 或域名；填写 ip:port 时仅取 IP 部分。')
              .fontSize(11)
              .fontColor($r('app.color.font_secondary'))
              .width('100%')
            this.InputLabel('映射到 (Map To)')
            TextInput({ text: this.mapTo, placeholder: '例如 127.0.0.1:8080' })
              .width('100%')
              .onChange((v: string) => {
                this.mapTo = v;
              })
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(12)

          this.SectionHeader('DNS 解析策略')

          Column() {
            ForEach(DNS_OPTIONS, (opt: DnsOption) => {
              this.DnsRow(opt.id, opt.label)
            }, (opt: DnsOption) => opt.id)
            Divider()
              .color($r('app.color.divider'))
              .strokeWidth(1)
            this.CheckRow('tls13', '仅限 TLS 1.3')
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 4 })
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(12)

          this.SectionHeader('NAT64')

          Column({ space: 8 }) {
            this.CheckRow('nat64', 'NAT64 (IPv4 → IPv6 映射)')
            Text('把规则目标 IPv4 映射到 NAT64 前缀，叠加 tls-rf/ttl-d 等模式使用。需要出口具备真实 IPv6 连通性。')
              .fontSize(12)
              .fontColor($r('app.color.font_secondary'))
              .width('100%')
            TextInput({ text: this.nat64Prefix, placeholder: '2001:67c:2960:6464::' })
              .width('100%')
              .enabled(this.nat64Enabled)
              .onChange((v: string) => {
                this.nat64Prefix = v;
              })
            Text('支持裸前缀或 CIDR（如 2001:67c:2960:6464::/96）。常用前缀：')
              .fontSize(11)
              .fontColor($r('app.color.font_secondary'))
              .width('100%')
            ForEach(NAT64_PRESETS, (p: Nat64Preset) => {
              Text('· ' + p.name + ' ' + p.prefix)
                .fontSize(13)
                .fontColor($r('app.color.accent'))
                .width('100%')
                .padding({ top: 3, bottom: 3 })
                .onClick(() => {
                  this.nat64Prefix = p.prefix;
                })
            }, (p: Nat64Preset) => p.name)
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(12)

          this.SectionHeader('高级参数（可选）')

          Column({ space: 8 }) {
            Row({ space: 12 }) {
              Column({ space: 4 }) {
                this.InputLabel('记录数 (num_records)')
                TextInput({ text: this.numRecordsText })
                  .width('100%')
                  .type(InputType.Number)
                  .onChange((v: string) => {
                    this.numRecordsText = filterDigits(v);
                  })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Column({ space: 4 }) {
                this.InputLabel('分段数 (num_segs)')
                TextInput({ text: this.numSegsText })
                  .width('100%')
                  .type(InputType.Number)
                  .onChange((v: string) => {
                    this.numSegsText = filterDigits(v);
                  })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')

            this.CheckRow('oob', 'OOB 分片（首包带外发送）')
            this.CheckRow('ack', '等待对端 ACK 后再发后续分片')
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(12)

          if (this.statusMsg.length > 0) {
            Text(this.statusMsg)
              .fontSize(12)
              .fontColor($r('app.color.accent'))
              .width('100%')
          }
          if (this.errorMsg.length > 0) {
            Text(this.errorMsg)
              .fontSize(12)
              .fontColor($r('app.color.error'))
              .width('100%')
          }

          Blank().height(24)
        }
        .width('100%')
        .padding(16)
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
  InputLabel(text: string) {
    Text(text)
      .fontSize(12)
      .fontColor($r('app.color.font_secondary'))
      .width('100%')
  }

  @Builder
  RadioRowMode(id: string, label: string, desc: string, usable: boolean) {
    Row({ space: 12 }) {
      Column()
        .width(18)
        .height(18)
        .borderRadius(9)
        .backgroundColor(Color.Transparent)
        .borderWidth(this.modeDisplay() === id && usable ? 5 : 1.5)
        .borderColor(this.modeDisplay() === id && usable
          ? $r('app.color.accent') : $r('app.color.font_secondary'))
      Column({ space: 2 }) {
        Text(label)
          .fontSize(15)
          .fontColor(usable ? $r('app.color.font_primary') : $r('app.color.font_secondary'))
        Text(desc)
          .fontSize(12)
          .fontColor($r('app.color.font_secondary'))
          .opacity(usable ? 1 : 0.7)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .onClick(() => {
      if (usable) {
        this.mode = id === 'transparent' ? 'direct' : id;
      } else {
        promptAction.showToast({ message: desc, duration: 2000 });
      }
    })
  }

  @Builder
  DnsRow(id: string, label: string) {
    Row({ space: 12 }) {
      Column()
        .width(18)
        .height(18)
        .borderRadius(9)
        .backgroundColor(Color.Transparent)
        .borderWidth(this.dnsMode === id && !this.dnsDisabled(id) ? 5 : 1.5)
        .borderColor(this.dnsMode === id && !this.dnsDisabled(id)
          ? $r('app.color.accent') : $r('app.color.font_secondary'))
      Column({ space: 2 }) {
        Text(label)
          .fontSize(15)
          .fontColor(this.dnsDisabled(id) ? $r('app.color.font_secondary') : $r('app.color.font_primary'))
        if (this.dnsDisabled(id)) {
          Text('纯 IPv4 网络：IPv6 相关功能已禁用')
            .fontSize(12)
            .fontColor($r('app.color.font_secondary'))
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .opacity(this.dnsDisabled(id) ? 0.7 : 1)
    .onClick(() => {
      if (!this.dnsDisabled(id)) {
        this.dnsMode = id;
      }
    })
  }

  @Builder
  CheckRow(kind: string, label: string) {
    Row({ space: 12 }) {
      Stack() {
        if (this.isChecked(kind)) {
          Text('✓')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.font_on_accent'))
        }
      }
      .width(20)
      .height(20)
      .borderRadius(4)
      .backgroundColor(this.isChecked(kind) ? $r('app.color.accent') : Color.Transparent)
      .borderWidth(1.5)
      .borderColor(this.isChecked(kind) ? $r('app.color.accent') : $r('app.color.font_secondary'))
      .alignContent(Alignment.Center)

      Text(label)
        .fontSize(15)
        .fontColor($r('app.color.font_primary'))
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
    .onClick(() => this.toggleCheck(kind))
  }
}
