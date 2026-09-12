import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { connection, socket } from '@kit.NetworkKit';
import { ConfigRepository } from '../data/ConfigRepository';
import { LumineConfig } from '../model/LumineConfig';

interface TypeOption {
  id: string;
  label: string;
}

const TYPE_OPTIONS: TypeOption[] = [
  { id: 'https', label: 'DoH (HTTPS)' },
  { id: 'quic', label: 'DoQ (QUIC)' },
  { id: 'tcp', label: 'TCP' },
  { id: 'tls', label: 'DoT (TLS)' },
  { id: 'udp', label: 'UDP' }
];

const DNS_PRESETS: TypeOption[] = [
  { id: 'Cloudflare Gateway (DoH)', label: 'https://xwfpeb16ii.cloudflare-gateway.com/dns-query' },
  { id: 'IIJ (DoH)', label: 'https://public.dns.iij.jp/dns-query' },
  { id: 'IIJ DoQ (QUIC, DoQ)', label: 'public.dns.iij.jp:853' }
];

function parseNode(node: string, type: string): string[] {
  const raw = node.trim();
  const host = raw.includes('://') ? raw.substring(raw.indexOf('://') + 3) : raw;
  const cut = host.indexOf('/');
  const hostNoPath = cut >= 0 ? host.substring(0, cut) : host;
  if (hostNoPath.includes(':')) {
    const h = hostNoPath.substring(0, hostNoPath.lastIndexOf(':'));
    const p = hostNoPath.substring(hostNoPath.lastIndexOf(':') + 1);
    let numeric = p.length > 0;
    for (let i = 0; i < p.length; i++) {
      const c = p.charCodeAt(i);
      if (c < 48 || c > 57) {
        numeric = false;
        break;
      }
    }
    if (numeric) {
      return [h, p];
    }
  }
  return [hostNoPath, type === 'https' ? '443' : '853'];
}

@Entry
@Component
struct Dns {
  @State config: LumineConfig | null = null;
  @State type: string = 'https';
  @State nodes: string[] = [];
  @State showAdd: boolean = false;
  @State editingIdx: number = -1;
  @State deletingIdx: number = -1;
  @State dialogValue: string = '';
  @State testing: boolean = false;
  @State results: Record<string, string> = {};
  @State notice: string = '';

  private repo: ConfigRepository | null = null;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.repo = ConfigRepository.getInstance(ctx);
    this.repo.init().then(() => {
      this.loadConfig();
    });
  }

  async loadConfig(): Promise<void> {
    if (this.repo) {
      this.config = await this.repo.loadConfig('config');
      if (this.config) {
        this.type = this.config.dns.type;
        this.nodes = [this.config.dns.addr].concat(this.config.dns.resolvers ?? []);
      }
    }
  }

  async persist(nextType: string, list: string[]): Promise<void> {
    if (list.length === 0 || !this.repo || !this.config) {
      return;
    }
    const resolvers: string[] = list.slice(1);
    this.config.dns.type = nextType;
    this.config.dns.addr = list[0];
    this.config.dns.resolvers = resolvers.length > 0 ? resolvers : undefined;
    await this.repo.saveConfig('config', this.config);
    this.notice = 'DNS 节点已更新';
  }

  moveNode(i: number, dir: number): void {
    const list = this.nodes.slice();
    const v = list.splice(i, 1)[0];
    list.splice(i + dir, 0, v);
    this.nodes = list;
    this.persist(this.type, list);
  }

  async testAll(): Promise<void> {
    if (this.testing || this.nodes.length === 0) {
      return;
    }
    this.testing = true;
    const out: Record<string, string> = {};
    for (let i = 0; i < this.nodes.length; i++) {
      const hp = parseNode(this.nodes[i], this.type);
      const rtt = await this.tcpRtt(hp[0], Number(hp[1]), 1);
      out[String(i)] = rtt >= 0 ? rtt + 'ms' : '不可达';
    }
    this.results = out;
    this.testing = false;
  }

  isIpLiteral(host: string): boolean {
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

  async resolveHost(host: string, family: number): Promise<string> {
    if (this.isIpLiteral(host)) {
      return host;
    }
    try {
      const netHandle = await connection.getDefaultNet();
      const addrs = await netHandle.getAddressesByName(host);
      for (const a of addrs) {
        const isV6 = a.address.indexOf(':') >= 0;
        if (family === 2 && isV6) {
          return a.address;
        }
        if (family === 1 && !isV6) {
          return a.address;
        }
      }
    } catch (err) {
      return '';
    }
    return '';
  }

  async tcpRtt(host: string, port: number, family: number): Promise<number> {
    const resolved = await this.resolveHost(host, family);
    if (resolved.length === 0) {
      return -1;
    }
    const s = socket.constructTCPSocketInstance();
    const start = Date.now();
    try {
      await s.bind({ address: family === 2 ? '::' : '0.0.0.0', port: 0, family: family });
      await s.connect({ address: { address: resolved, port: port, family: family }, timeout: 4000 });
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

  confirmDialog(): void {
    const v = this.dialogValue.trim();
    if (v.length === 0) {
      return;
    }
    if (this.showAdd) {
      const list = this.nodes.concat(v);
      this.nodes = list;
      this.persist(this.type, list);
      this.showAdd = false;
    } else if (this.editingIdx >= 0 && this.editingIdx < this.nodes.length) {
      const list = this.nodes.slice();
      list[this.editingIdx] = v;
      this.nodes = list;
      this.persist(this.type, list);
      this.editingIdx = -1;
    }
  }

  confirmDelete(): void {
    const i = this.deletingIdx;
    this.deletingIdx = -1;
    if (i < 0 || i >= this.nodes.length) {
      return;
    }
    if (this.nodes.length === 1) {
      this.notice = '至少需要保留一个 DNS 节点';
      return;
    }
    const list = this.nodes.slice();
    list.splice(i, 1);
    this.nodes = list;
    this.persist(this.type, list);
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
            Text('安全 DNS')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.font_primary'))
              .layoutWeight(1)
          }
          .width('100%')

          Text('第一个节点为主节点，其余为备用节点；解析失败会自动切换到下一个可用节点。')
            .fontSize(12)
            .fontColor($r('app.color.font_secondary'))
            .width('100%')

          this.SectionHeader('传输类型')

          Column() {
            ForEach(TYPE_OPTIONS, (opt: TypeOption) => {
              Row({ space: 12 }) {
                Column()
                  .width(18)
                  .height(18)
                  .borderRadius(9)
                  .backgroundColor(Color.Transparent)
                  .borderWidth(this.type === opt.id ? 5 : 1.5)
                  .borderColor(this.type === opt.id ? $r('app.color.accent') : $r('app.color.font_secondary'))
                Text(opt.label)
                  .fontSize(15)
                  .fontColor($r('app.color.font_primary'))
              }
              .width('100%')
              .height(42)
              .onClick(() => {
                this.type = opt.id;
                this.persist(opt.id, this.nodes);
              })
            }, (opt: TypeOption) => opt.id)
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(12)

          this.SectionHeader('DNS 节点')

          if (this.nodes.length === 0) {
            Text('暂无 DNS 节点')
              .fontSize(14)
              .fontColor($r('app.color.font_secondary'))
              .width('100%')
              .padding({ top: 8, bottom: 8 })
          }

          Column() {
            ForEach(this.nodes, (node: string, i: number) => {
              Row({ space: 12 }) {
                Column() {
                  Text('DNS')
                    .fontSize(10)
                    .fontWeight(FontWeight.Bold)
                    .fontColor($r('app.color.accent'))
                }
                .width(40)
                .height(40)
                .borderRadius(20)
                .backgroundColor($r('app.color.page_bg'))
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)

                Column({ space: 2 }) {
                  Row({ space: 8 }) {
                    Text(i === 0 ? '主节点' : '备用 ' + i)
                      .fontSize(12)
                      .fontColor($r('app.color.accent'))
                    Text(node)
                      .fontSize(14)
                      .fontColor($r('app.color.font_primary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .width('100%')
                  if (this.results[String(i)]) {
                    Text(this.results[String(i)])
                      .fontSize(12)
                      .fontColor(this.results[String(i)] === '不可达'
                        ? $r('app.color.error') : $r('app.color.font_secondary'))
                  }
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                if (i > 0) {
                  Text('↑')
                    .fontSize(16)
                    .fontColor($r('app.color.font_primary'))
                    .width(32)
                    .height(32)
                    .textAlign(TextAlign.Center)
                    .onClick(() => this.moveNode(i, -1))
                }
                if (i < this.nodes.length - 1) {
                  Text('↓')
                    .fontSize(16)
                    .fontColor($r('app.color.font_primary'))
                    .width(32)
                    .height(32)
                    .textAlign(TextAlign.Center)
                    .onClick(() => this.moveNode(i, 1))
                }
                Text('编辑')
                  .fontSize(12)
                  .fontColor($r('app.color.accent'))
                  .width(32)
                  .textAlign(TextAlign.Center)
                  .onClick(() => {
                    this.editingIdx = i;
                    this.dialogValue = node;
                  })
                Text('删除')
                  .fontSize(12)
                  .fontColor($r('app.color.error'))
                  .width(32)
                  .textAlign(TextAlign.Center)
                  .onClick(() => { this.deletingIdx = i; })
              }
              .width('100%')
              .padding({ top: 10, bottom: 10 })
              .onClick(() => {
                this.editingIdx = i;
                this.dialogValue = node;
              })

              if (i < this.nodes.length - 1) {
                Divider()
                  .color($r('app.color.divider'))
                  .strokeWidth(1)
              }
            }, (node: string, i: number) => i + ':' + node)
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(12)

          Row({ space: 10 }) {
            Button('添加节点')
              .type(ButtonType.Normal)
              .borderRadius(12)
              .layoutWeight(1)
              .height(40)
              .backgroundColor($r('app.color.card_bg'))
              .fontColor($r('app.color.font_primary'))
              .onClick(() => {
                this.showAdd = true;
                this.dialogValue = '';
              })
            Button(this.testing ? '测试中...' : '全部测试')
              .type(ButtonType.Normal)
              .borderRadius(12)
              .layoutWeight(1)
              .height(40)
              .backgroundColor($r('app.color.card_bg'))
              .fontColor($r('app.color.font_primary'))
              .enabled(this.nodes.length > 0 && !this.testing)
              .onClick(() => this.testAll())
          }
          .width('100%')

          Text(this.notice)
            .fontSize(12)
            .fontColor($r('app.color.accent'))
            .width('100%')

          Blank().height(24)
        }
        .width('100%')
        .padding(16)
      }
      .align(Alignment.Top)
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))

      if (this.showAdd || this.editingIdx >= 0) {
        this.NodeDialog(this.showAdd ? '添加 DNS 节点' : '编辑 DNS 节点')
      }
      if (this.deletingIdx >= 0) {
        this.DeleteDialog()
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
  NodeDialog(title: string) {
    Column({ space: 12 }) {
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.font_primary'))
        .width('100%')
      TextInput({ text: this.dialogValue, placeholder: 'https://dns.example.com/dns-query  或  1.1.1.1:853' })
        .width('100%')
        .onChange((v: string) => { this.dialogValue = v; })
      Text('QUIC/TLS 端点省略端口时默认 853；DoH 需完整 URL。')
        .fontSize(11)
        .fontColor($r('app.color.font_secondary'))
        .width('100%')
      Text('常用服务商')
        .fontSize(12)
        .fontColor($r('app.color.accent'))
        .width('100%')
      ForEach(DNS_PRESETS, (p: TypeOption) => {
        Text('· ' + p.id)
          .fontSize(13)
          .fontColor($r('app.color.accent'))
          .width('100%')
          .padding({ top: 3, bottom: 3 })
          .onClick(() => { this.dialogValue = p.label; })
      }, (p: TypeOption) => p.id)
      Text('提示：IIJ DoQ 节点需在传输类型中选择 QUIC；Cloudflare Gateway 与 IIJ (DoH) 需选择 DoH (HTTPS)。')
        .fontSize(11)
        .fontColor($r('app.color.font_secondary'))
        .width('100%')
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .backgroundColor($r('app.color.card_bg'))
          .fontColor($r('app.color.font_primary'))
          .onClick(() => {
            this.showAdd = false;
            this.editingIdx = -1;
          })
        Button('保存')
          .layoutWeight(1)
          .backgroundColor($r('app.color.accent'))
          .fontColor($r('app.color.font_on_accent'))
          .enabled(this.dialogValue.trim().length > 0)
          .onClick(() => this.confirmDialog())
      }
      .width('100%')
    }
    .width('92%')
    .padding(16)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(16)
  }

  @Builder
  DeleteDialog() {
    Column({ space: 12 }) {
      Text('删除 DNS 节点')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.font_primary'))
        .width('100%')
      Text('移除后将不再使用该节点进行 DNS 解析。')
        .fontSize(13)
        .fontColor($r('app.color.font_secondary'))
        .width('100%')
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .backgroundColor($r('app.color.card_bg'))
          .fontColor($r('app.color.font_primary'))
          .onClick(() => { this.deletingIdx = -1; })
        Button('确定')
          .layoutWeight(1)
          .backgroundColor($r('app.color.accent'))
          .fontColor($r('app.color.font_on_accent'))
          .onClick(() => this.confirmDelete())
      }
      .width('100%')
    }
    .width('92%')
    .padding(16)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(16)
  }
}
