import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { NetworkMonitor } from '../service/NetworkMonitor';
import { ConfigRepository } from '../data/ConfigRepository';
import { PrefsStore } from '../data/PrefsStore';
import { LumineCore } from '../service/LumineCore';
import { LumineConfig, IPPool, serializeLumineConfig, defaultPolicy } from '../model/LumineConfig';

interface TypeOption {
  id: string;
  label: string;
}

interface PoolEntry {
  tag: string;
  pool: IPPool;
}

interface CoreStats {
  down: number;
  up: number;
  blocked: number;
  tcp_conns: number;
  udp_conns: number;
  uptime_ms: number;
}

const DNS_TYPE_OPTIONS: TypeOption[] = [
  { id: 'https', label: 'DoH (HTTPS)' },
  { id: 'quic', label: 'DoQ (QUIC)' },
  { id: 'udp', label: 'UDP' },
  { id: 'tcp', label: 'TCP' },
  { id: 'tls', label: 'DoT (TLS)' }
];

const LOG_LEVELS: string[] = ['DEBUG', 'INFO', 'WARN', 'ERROR'];

const POLICY_MODES: string[] = ['tls-rf', 'direct', 'raw', 'ttl-d', 'block'];

const NAT64_PRESETS: string[] = [
  '2001:67c:2960:6464::',
  '2a01:4f9:c010:3f02:64::',
  '2602:fc59:11:64::'
];

function safeNum(v: number): number {
  if (typeof v !== 'number' || isNaN(v)) {
    return 0;
  }
  return v;
}

function formatBytesSafe(bytes: number): string {
  if (bytes < 0) {
    return '-';
  }
  if (bytes < 1024) {
    return String(bytes) + ' B';
  }
  if (bytes < 1024 * 1024) {
    return (bytes / 1024).toFixed(1) + ' KB';
  }
  return (bytes / (1024 * 1024)).toFixed(2) + ' MB';
}

function formatUptimeShort(ms: number): string {
  if (ms <= 0) {
    return '-';
  }
  const s = Math.floor(ms / 1000);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  if (h > 0) {
    return h + 'h' + m + 'm';
  }
  if (m > 0) {
    return m + 'm' + sec + 's';
  }
  return sec + 's';
}

function splitResolvers(raw: string): string[] {
  const parts = raw.replace(/,/g, ' ').replace(/，/g, ' ').replace(/\n/g, ' ').split(' ');
  const out: string[] = [];
  for (const p of parts) {
    const t = p.trim();
    if (t.length > 0) {
      out.push(t);
    }
  }
  return out;
}

function splitPoolIps(raw: string): string[] {
  const parts = raw.replace(/;/g, ',').replace(/，/g, ',').split(',');
  const out: string[] = [];
  for (const p of parts) {
    const t = p.trim();
    if (t.length > 0) {
      out.push(t);
    }
  }
  return out;
}

function parsePort(raw: string, fallback: number): number {
  let digits = '';
  for (let i = 0; i < raw.length; i++) {
    const c = raw.charCodeAt(i);
    if (c >= 48 && c <= 57) {
      digits += raw.charAt(i);
    }
  }
  if (digits.length === 0) {
    return fallback;
  }
  const n = Number(digits);
  if (n >= 1 && n <= 65535) {
    return n;
  }
  return fallback;
}

@Entry
@Component
struct Settings {
  @State config: LumineConfig | null = null;
  @State dnsType: string = 'https';
  @State dnsAddr: string = '';
  @State dnsResolvers: string = '';
  @State logLevel: string = 'INFO';
  @State defaultMode: string = 'tls-rf';
  @State nat64Prefix: string = '';
  @State notice: string = '';
  @State statsLine: string = '';
  @State logFilesLine: string = '';
  @State logPathLine: string = '';
  @State logToggle: boolean = true;
  @State pools: PoolEntry[] = [];
  @State ipv6Checked: boolean = false;
  @State ipv6Ok: boolean = false;
  @State showPoolDialog: boolean = false;
  @State editingPoolTag: string = '';
  @State deletingPoolTag: string = '';
  @State dialogTag: string = '';
  @State dialogIps: string = '';
  @State dialogPort: string = '443';
  @State importing: boolean = false;

  private repo: ConfigRepository | null = null;
  private prefs: PrefsStore | null = null;
  private core: LumineCore | null = null;
  private appCtx: common.UIAbilityContext | null = null;
  private pollTimer: number = -1;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.appCtx = ctx;
    this.core = LumineCore.getInstance();
    this.repo = ConfigRepository.getInstance(ctx);
    this.repo.init().then(() => {
      this.loadConfig();
    });
    PrefsStore.getInstance(ctx).then((p: PrefsStore) => {
      this.prefs = p;
      p.getBool('logFileEnabled', true).then((v: boolean) => {
        this.logToggle = v;
      });
    });
    this.probeIpv6();
    this.refreshStats();
    this.pollTimer = setInterval(() => {
      this.refreshStats();
    }, 2000);
  }

  aboutToDisappear(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  async loadConfig(): Promise<void> {
    if (!this.repo) {
      return;
    }
    const cfg = await this.repo.loadConfig('config');
    if (cfg) {
      if (!cfg.default_policy) {
        cfg.default_policy = defaultPolicy();
      }
      this.config = cfg;
      this.dnsType = cfg.dns.type;
      this.dnsAddr = cfg.dns.addr;
      this.dnsResolvers = (cfg.dns.resolvers ?? []).join(' ');
      this.logLevel = cfg.log_level;
      this.defaultMode = cfg.default_policy.mode ?? 'tls-rf';
      this.nat64Prefix = cfg.default_policy.nat64_prefix ?? '';
      this.refreshPools();
    }
  }

  refreshPools(): void {
    const out: PoolEntry[] = [];
    const cfg = this.config;
    if (cfg) {
      const src = cfg.ip_pools;
      if (src) {
        const keys = Object.keys(src);
        for (const k of keys) {
          out.push({ tag: k, pool: src[k] });
        }
      }
    }
    this.pools = out;
  }

  refreshStats(): void {
    this.statsLine = this.buildStatsLine();
    this.logFilesLine = this.buildLogFilesLine();
    let path = '';
    if (this.core) {
      path = this.core.logFilePath();
    }
    if (path.length === 0 && this.appCtx) {
      path = this.appCtx.filesDir + '/logs';
    }
    this.logPathLine = path;
  }

  buildStatsLine(): string {
    let raw = '';
    if (this.core) {
      raw = this.core.readStats();
    }
    if (raw.length === 0 && this.appCtx) {
      try {
        const p = this.appCtx.filesDir + '/core_stats.json';
        if (fileIo.accessSync(p)) {
          raw = fileIo.readTextSync(p);
        }
      } catch (e) {
        raw = '';
      }
    }
    if (raw.length === 0) {
      return '';
    }
    try {
      const s = JSON.parse(raw) as CoreStats;
      const down = safeNum(s.down);
      const up = safeNum(s.up);
      const blocked = safeNum(s.blocked);
      const tcp = safeNum(s.tcp_conns);
      const udp = safeNum(s.udp_conns);
      const uptime = safeNum(s.uptime_ms);
      return '↓ ' + formatBytesSafe(down) + '  ↑ ' + formatBytesSafe(up) + '  阻断 ' + blocked
        + '  TCP ' + tcp + ' / UDP ' + udp + '  运行 ' + formatUptimeShort(uptime);
    } catch (e) {
      return '';
    }
  }

  buildLogFilesLine(): string {
    if (!this.appCtx) {
      return '会话日志：未落盘（引擎运行后自动写入 filesDir/logs）';
    }
    const dir = this.appCtx.filesDir + '/logs';
    try {
      if (!fileIo.accessSync(dir)) {
        return '会话日志：未落盘（引擎运行后自动写入 filesDir/logs）';
      }
      const entries = fileIo.listFileSync(dir);
      let count = 0;
      let total = 0;
      for (const name of entries) {
        if (name.startsWith('lumine')) {
          count++;
          total += fileIo.statSync(dir + '/' + name).size;
        }
      }
      if (count === 0) {
        return '会话日志：未落盘（引擎运行后自动写入 filesDir/logs）';
      }
      return '日志文件：' + count + ' 个，共 ' + formatBytesSafe(total) + '（logs/lumine*.log）';
    } catch (e) {
      return '会话日志：未落盘（引擎运行后自动写入 filesDir/logs）';
    }
  }

  async probeIpv6(): Promise<void> {
    this.ipv6Ok = await NetworkMonitor.getInstance().checkIpv6Available(this.ipv6Checked);
    this.ipv6Checked = true;
  }

  recheckNetwork(): void {
    this.ipv6Checked = false;
    this.probeIpv6();
  }

  dnsTypeHint(): string {
    if (this.dnsType === 'quic') {
      return 'quic = DoQ（RFC 9250，标准证书校验，默认端口 853）';
    }
    if (this.dnsType === 'https') {
      return 'https = DoH（默认端口 443）';
    }
    return '其余类型地址须为 ip:port';
  }

  async saveAll(): Promise<void> {
    if (!this.repo || !this.config) {
      return;
    }
    const cfg = this.config;
    cfg.dns.type = this.dnsType;
    cfg.dns.addr = this.dnsAddr;
    const resolvers = splitResolvers(this.dnsResolvers);
    cfg.dns.resolvers = resolvers.length > 0 ? resolvers : undefined;
    cfg.log_level = this.logLevel;
    cfg.default_policy.mode = this.defaultMode;
    const np = this.nat64Prefix.trim();
    cfg.default_policy.nat64_prefix = np.length > 0 ? np : undefined;
    const json = serializeLumineConfig(cfg);
    if (this.core) {
      const err = this.core.checkConfigJson(json);
      if (err.length > 0 && err.indexOf('working directory not set') < 0) {
        this.notice = err.indexOf('core is running') >= 0 ? '核心运行中，请停止核心后再试' : err;
        return;
      }
    }
    await this.repo.saveConfig('config', cfg);
    this.notice = '设置已保存';
  }

  async importConfigFile(): Promise<void> {
    if (!this.repo || this.importing) {
      return;
    }
    const docPicker = new picker.DocumentViewPicker();
    const selectOptions = new picker.DocumentSelectOptions();
    selectOptions.maxSelectNumber = 1;
    let picked: string[] = [];
    try {
      picked = await docPicker.select(selectOptions);
    } catch (e) {
      return;
    }
    if (picked.length === 0) {
      return;
    }
    this.importing = true;
    try {
      const text: string = fileIo.readTextSync(picked[0]);
      if (text.trim().length === 0) {
        this.notice = '导入失败：文件内容为空';
        return;
      }
      try {
        JSON.parse(text);
      } catch (e) {
        this.notice = '导入失败：配置不是有效的 JSON';
        return;
      }
      if (this.core) {
        const err = this.core.checkConfigJson(text);
        if (err.length > 0 && err.indexOf('working directory not set') < 0) {
          this.notice = err.indexOf('core is running') >= 0 ? '核心运行中，请停止核心后再试' : err;
          return;
        }
      }
      const result = await this.repo.importConfig(text);
      if (result.error !== null) {
        this.notice = result.error;
        return;
      }
      await this.repo.saveConfig('config', result.config);
      this.notice = '配置导入成功';
      await this.loadConfig();
    } catch (e) {
      this.notice = '导入失败：' + String(e);
    } finally {
      this.importing = false;
    }
  }

  async exportConfigFile(): Promise<void> {
    if (!this.repo || !this.appCtx) {
      return;
    }
    try {
      const json = await this.repo.exportConfig('config');
      if (json === null || json.length === 0) {
        this.notice = '导出失败：配置不存在';
        return;
      }
      const dir = this.appCtx.cacheDir + '/exports';
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
      const path = dir + '/lumine_config_' + Date.now() + '.json';
      const fd = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(fd.fd, json);
      fileIo.closeSync(fd);
      this.notice = '已导出 ' + json.length + ' 字节到 ' + path;
    } catch (e) {
      this.notice = '导出失败：' + String(e);
    }
  }

  openPoolDialog(p: PoolEntry): void {
    this.editingPoolTag = p.tag;
    this.dialogTag = p.tag;
    this.dialogIps = p.pool.ips ? p.pool.ips.join(', ') : '';
    this.dialogPort = String(p.pool.port ? p.pool.port : 443);
    this.showPoolDialog = true;
  }

  openAddPoolDialog(): void {
    this.editingPoolTag = '';
    this.dialogTag = '';
    this.dialogIps = '';
    this.dialogPort = '443';
    this.showPoolDialog = true;
  }

  closePoolDialog(): void {
    this.showPoolDialog = false;
    this.editingPoolTag = '';
  }

  async confirmPoolDialog(): Promise<void> {
    if (!this.repo || !this.config) {
      return;
    }
    const tag = this.dialogTag.trim();
    const ips = splitPoolIps(this.dialogIps);
    if (tag.length === 0 || ips.length === 0) {
      return;
    }
    const port = parsePort(this.dialogPort, 443);
    const pools: Record<string, IPPool> = {};
    const old = this.config.ip_pools;
    if (old) {
      const keys = Object.keys(old);
      for (const k of keys) {
        if (k !== this.editingPoolTag && k !== tag) {
          pools[k] = old[k];
        }
      }
    }
    pools[tag] = { ips: ips, port: port };
    this.config.ip_pools = pools;
    await this.repo.saveConfig('config', this.config);
    this.closePoolDialog();
    this.notice = '已保存 IP 池 ' + tag;
    this.refreshPools();
  }

  async confirmDeletePool(): Promise<void> {
    const tag = this.deletingPoolTag;
    this.deletingPoolTag = '';
    if (tag.length === 0 || !this.repo || !this.config) {
      return;
    }
    const pools: Record<string, IPPool> = {};
    const old = this.config.ip_pools;
    if (old) {
      const keys = Object.keys(old);
      for (const k of keys) {
        if (k !== tag) {
          pools[k] = old[k];
        }
      }
    }
    this.config.ip_pools = Object.keys(pools).length > 0 ? pools : undefined;
    await this.repo.saveConfig('config', this.config);
    this.notice = '已删除 IP 池 ' + tag;
    this.refreshPools();
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
            Text('系统设置')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.font_primary'))
              .layoutWeight(1)
            Button('保存')
              .type(ButtonType.Capsule)
              .height(32)
              .backgroundColor($r('app.color.accent'))
              .fontColor($r('app.color.font_on_accent'))
              .fontSize(13)
              .padding({ left: 16, right: 16 })
              .onClick(() => this.saveAll())
          }
          .width('100%')

          if (this.notice.length > 0) {
            Text(this.notice)
              .fontSize(13)
              .fontColor($r('app.color.accent'))
              .width('100%')
          }

          this.SectionHeader('核心设置')

          Column({ space: 8 }) {
            Text('DNS 传输类型')
              .fontSize(12)
              .fontColor($r('app.color.font_secondary'))
              .width('100%')
            ForEach(DNS_TYPE_OPTIONS, (opt: TypeOption) => {
              this.RadioRow(opt.label, this.dnsType === opt.id, () => {
                this.dnsType = opt.id;
              })
            }, (opt: TypeOption) => opt.id)
            Text(this.dnsTypeHint())
              .fontSize(12)
              .fontColor($r('app.color.font_secondary'))
              .width('100%')
            this.LabeledInput('上游 DNS', this.dnsAddr, 'https://... 或 1.1.1.1:53', 'DNS 解析使用的上游服务器地址',
              (v: string) => {
                this.dnsAddr = v;
              })
            this.LabeledInput('备用 DNS 节点 (resolvers)', this.dnsResolvers,
              'https://public.dns.iij.jp/dns-query 1.1.1.1:53 …', '同类型多端点自动故障切换（粘住健康节点），空格/逗号分隔。',
              (v: string) => {
                this.dnsResolvers = v;
              })
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(12)

          this.SectionHeader('日志级别')

          Column() {
            ForEach(LOG_LEVELS, (level: string) => {
              this.RadioRow(level, this.logLevel === level, () => {
                this.logLevel = level;
              })
            }, (level: string) => level)
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(12)

          this.SectionHeader('默认策略模式')

          Column({ space: 4 }) {
            Text('未匹配任何规则时的处理方式（引擎 default_policy.mode）')
              .fontSize(12)
              .fontColor($r('app.color.font_secondary'))
              .width('100%')
            ForEach(POLICY_MODES, (m: string) => {
              this.RadioRow(m, this.defaultMode === m, () => {
                this.defaultMode = m;
              })
            }, (m: string) => m)
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(12)

          this.SectionHeader('网络环境')

          Column({ space: 8 }) {
            Text('IPv6：' + (this.ipv6Checked ? (this.ipv6Ok ? '可用' : '不可用（仅 IPv4）') : '未知'))
              .fontSize(13)
              .fontColor($r('app.color.font_secondary'))
              .width('100%')
            Text(this.nat64Prefix.trim().length > 0
              ? 'NAT64 前缀：' + this.nat64Prefix.trim()
              : 'NAT64：未检测到运营商前缀（可手动在规则中配置）')
              .fontSize(13)
              .fontColor($r('app.color.font_secondary'))
              .width('100%')
            this.LabeledInput('NAT64 前缀', this.nat64Prefix, '例如：64:ff9b::', '',
              (v: string) => {
                this.nat64Prefix = v;
              })
            Text('常用前缀')
              .fontSize(12)
              .fontColor($r('app.color.accent'))
              .width('100%')
            ForEach(NAT64_PRESETS, (p: string) => {
              Text('· ' + p)
                .fontSize(13)
                .fontColor($r('app.color.accent'))
                .width('100%')
                .padding({ top: 3, bottom: 3 })
                .onClick(() => {
                  this.nat64Prefix = p;
                })
            }, (p: string) => p)
            Button('重新检测')
              .type(ButtonType.Normal)
              .borderRadius(12)
              .width('100%')
              .height(40)
              .backgroundColor($r('app.color.card_bg'))
              .fontColor($r('app.color.font_primary'))
              .onClick(() => this.recheckNetwork())
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(12)

          this.SectionHeader('会话统计 / 日志文件')

          Column({ space: 8 }) {
            Text(this.statsLine.length > 0 ? this.statsLine : '会话统计：引擎未运行')
              .fontSize(13)
              .fontColor($r('app.color.font_secondary'))
              .width('100%')
            Text(this.logFilesLine)
              .fontSize(12)
              .fontColor($r('app.color.font_secondary'))
              .width('100%')
            Divider()
              .color($r('app.color.divider'))
              .strokeWidth(1)
            Row() {
              Text('日志文件')
                .fontSize(15)
                .fontColor($r('app.color.font_primary'))
              Blank()
              Toggle({ type: ToggleType.Switch, isOn: this.logToggle })
                .onChange((on: boolean) => {
                  this.logToggle = on;
                  if (this.core) {
                    this.core.setLogFileEnabled(on);
                  }
                  if (this.prefs) {
                    this.prefs.setBool('logFileEnabled', on);
                  }
                })
            }
            .width('100%')
            if (this.logPathLine.length > 0) {
              Text('日志目录：' + this.logPathLine)
                .fontSize(12)
                .fontColor($r('app.color.font_secondary'))
                .width('100%')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(12)

          this.SectionHeader('IP 池 (ip_pools)')

          Column({ space: 8 }) {
            Text('带 $ 前缀引用（如 ip_policies 的 map_to: $cloudflare）。修改在下次启动连接时生效。')
              .fontSize(12)
              .fontColor($r('app.color.font_secondary'))
              .width('100%')
            if (this.pools.length === 0) {
              Text('未配置 IP 池')
                .fontSize(14)
                .fontColor($r('app.color.font_secondary'))
                .width('100%')
            }
            ForEach(this.pools, (p: PoolEntry, i: number) => {
              Column() {
                Row({ space: 12 }) {
                  Text('$' + p.tag + ' · ' + (p.pool.ips ? p.pool.ips.length : 0) + ' IP · :'
                    + (p.pool.port ? p.pool.port : 443))
                    .fontSize(14)
                    .fontColor($r('app.color.font_primary'))
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text('编辑')
                    .fontSize(12)
                    .fontColor($r('app.color.accent'))
                    .onClick(() => this.openPoolDialog(p))
                  Text('删除')
                    .fontSize(12)
                    .fontColor($r('app.color.error'))
                    .onClick(() => {
                      this.deletingPoolTag = p.tag;
                    })
                }
                .width('100%')
                .padding({ top: 6, bottom: 6 })

                if (i < this.pools.length - 1) {
                  Divider()
                    .color($r('app.color.divider'))
                    .strokeWidth(1)
                }
              }
              .width('100%')
            }, (p: PoolEntry) => p.tag + ':' + (p.pool.ips ? p.pool.ips.length : 0) + ':'
              + (p.pool.port ? p.pool.port : 443))
            Button('添加 / 覆盖 IP 池')
              .type(ButtonType.Normal)
              .borderRadius(12)
              .width('100%')
              .height(40)
              .backgroundColor($r('app.color.card_bg'))
              .fontColor($r('app.color.font_primary'))
              .onClick(() => this.openAddPoolDialog())
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(12)

          this.SectionHeader('配置导入 / 导出')

          Column({ space: 8 }) {
            Row({ space: 12 }) {
              Button('导入配置')
                .type(ButtonType.Normal)
                .borderRadius(12)
                .layoutWeight(1)
                .height(40)
                .backgroundColor($r('app.color.card_bg'))
                .fontColor($r('app.color.font_primary'))
                .enabled(!this.importing)
                .onClick(() => this.importConfigFile())
              Button('导出配置')
                .type(ButtonType.Normal)
                .borderRadius(12)
                .layoutWeight(1)
                .height(40)
                .backgroundColor($r('app.color.card_bg'))
                .fontColor($r('app.color.font_primary'))
                .onClick(() => this.exportConfigFile())
            }
            .width('100%')
            Text('导入会覆盖当前使用的配置；导出为完整配置 JSON（含引擎全部字段）。')
              .fontSize(12)
              .fontColor($r('app.color.font_secondary'))
              .width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(12)

          Blank().height(24)
        }
        .width('100%')
        .padding(16)
      }
      .align(Alignment.Top)
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))

      if (this.showPoolDialog) {
        this.PoolDialog()
      }
      if (this.deletingPoolTag.length > 0) {
        this.DeletePoolDialog()
      }
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
  RadioRow(label: string, selected: boolean, onSelect: () => void) {
    Row({ space: 12 }) {
      Column()
        .width(18)
        .height(18)
        .borderRadius(9)
        .backgroundColor(Color.Transparent)
        .borderWidth(selected ? 5 : 1.5)
        .borderColor(selected ? $r('app.color.accent') : $r('app.color.font_secondary'))
      Text(label)
        .fontSize(15)
        .fontColor($r('app.color.font_primary'))
    }
    .width('100%')
    .height(42)
    .onClick(() => onSelect())
  }

  @Builder
  LabeledInput(label: string, value: string, placeholder: string, hint: string, onChange: (v: string) => void) {
    Column({ space: 4 }) {
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.font_secondary'))
        .width('100%')
      TextInput({ text: value, placeholder: placeholder })
        .width('100%')
        .onChange((v: string) => onChange(v))
      if (hint.length > 0) {
        Text(hint)
          .fontSize(11)
          .fontColor($r('app.color.font_secondary'))
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  PoolDialog() {
    Column({ space: 12 }) {
      Text('IP 池')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.font_primary'))
        .width('100%')
      this.LabeledInput('标签', this.dialogTag, 'cloudflare', '', (v: string) => {
        this.dialogTag = v;
      })
      this.LabeledInput('IP / 域名（逗号分隔）', this.dialogIps, '1.1.1.1, 104.17.0.1, cdn.example.com', '',
        (v: string) => {
          this.dialogIps = v;
        })
      this.LabeledInput('探测端口', this.dialogPort, '443', '', (v: string) => {
        this.dialogPort = v;
      })
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .backgroundColor($r('app.color.card_bg'))
          .fontColor($r('app.color.font_primary'))
          .onClick(() => this.closePoolDialog())
        Button('保存')
          .layoutWeight(1)
          .backgroundColor($r('app.color.accent'))
          .fontColor($r('app.color.font_on_accent'))
          .enabled(this.dialogTag.trim().length > 0 && this.dialogIps.trim().length > 0)
          .onClick(() => this.confirmPoolDialog())
      }
      .width('100%')
    }
    .width('92%')
    .padding(16)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(16)
  }

  @Builder
  DeletePoolDialog() {
    Column({ space: 12 }) {
      Text('删除 IP 池')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.font_primary'))
        .width('100%')
      Text('确定要删除 IP 池 ' + this.deletingPoolTag + ' 吗？')
        .fontSize(13)
        .fontColor($r('app.color.font_secondary'))
        .width('100%')
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .backgroundColor($r('app.color.card_bg'))
          .fontColor($r('app.color.font_primary'))
          .onClick(() => {
            this.deletingPoolTag = '';
          })
        Button('确定')
          .layoutWeight(1)
          .backgroundColor($r('app.color.accent'))
          .fontColor($r('app.color.font_on_accent'))
          .onClick(() => this.confirmDeletePool())
      }
      .width('100%')
    }
    .width('92%')
    .padding(16)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(16)
  }
}
