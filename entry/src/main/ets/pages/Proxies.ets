import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { connection, socket } from '@kit.NetworkKit';
import { NetworkMonitor, mapNat64 } from '../service/NetworkMonitor';
import { PrefsStore } from '../data/PrefsStore';
import { NAT64Profile } from '../model/VpnTypes';

const SEED_PROFILES: NAT64Profile[] = [
  { id: 'level66', name: 'level66', prefix: '2001:67c:2960:6464::' },
  { id: 'nat64.net', name: 'nat64.net', prefix: '2a01:4f9:c010:3f02:64::' },
  { id: 'ztvi', name: 'ZTVI.org', prefix: '2602:fc59:11:64::' }
];

@Entry
@Component
struct Proxies {
  @State nat64Profiles: NAT64Profile[] = [];
  @State ipv6Ok: boolean = false;
  @State ipv6Checked: boolean = false;
  @State showAdd: boolean = false;
  @State editingProfile: NAT64Profile | null = null;
  @State deletingProfile: NAT64Profile | null = null;
  @State dialogName: string = '';
  @State dialogPrefix: string = '';
  @State testResults: Record<string, string> = {};
  @State testingIds: string[] = [];
  @State notice: string = '';

  private prefs: PrefsStore | null = null;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.loadProfiles(ctx);
    this.probeIpv6();
  }

  async probeIpv6(): Promise<void> {
    this.ipv6Ok = await NetworkMonitor.getInstance().checkIpv6Available();
    this.ipv6Checked = true;
  }

  async loadProfiles(ctx: common.UIAbilityContext): Promise<void> {
    this.prefs = await PrefsStore.getInstance(ctx);
    const raw = await this.prefs.getString('nat64Profiles', '');
    let loaded: NAT64Profile[] = [];
    if (raw.length > 0) {
      try {
        loaded = JSON.parse(raw) as NAT64Profile[];
      } catch {
        loaded = [];
      }
    }
    if (loaded.length === 0) {
      loaded = SEED_PROFILES;
    }
    this.nat64Profiles = loaded;
    await this.persistProfiles();
  }

  async persistProfiles(): Promise<void> {
    if (this.prefs) {
      await this.prefs.setString('nat64Profiles', JSON.stringify(this.nat64Profiles));
    }
  }

  async saveProfiles(list: NAT64Profile[]): Promise<void> {
    this.nat64Profiles = list;
    await this.persistProfiles();
    this.notice = '已保存';
  }

  confirmProfileDialog(): void {
    const name = this.dialogName.trim();
    const prefix = this.dialogPrefix.trim();
    if (name.length === 0 || prefix.length === 0) {
      return;
    }
    if (this.editingProfile) {
      const target = this.editingProfile.id;
      this.saveProfiles(this.nat64Profiles.map((p: NAT64Profile) => {
        if (p.id === target) {
          return { id: p.id, name: name, prefix: prefix };
        }
        return p;
      }));
      this.editingProfile = null;
    } else {
      this.saveProfiles(this.nat64Profiles.concat({
        id: 'nat64_' + Date.now(),
        name: name,
        prefix: prefix
      }));
      this.showAdd = false;
    }
  }

  async confirmDelete(): Promise<void> {
    const target = this.deletingProfile;
    this.deletingProfile = null;
    if (target) {
      await this.saveProfiles(this.nat64Profiles.filter((p: NAT64Profile) => p.id !== target.id));
    }
  }

  async testProfile(p: NAT64Profile): Promise<void> {
    if (this.testingIds.indexOf(p.id) >= 0) {
      return;
    }
    this.testingIds = this.testingIds.concat(p.id);
    const rtt = await this.nat64Rtt(p.prefix);
    if (rtt >= 0) {
      this.testResults[p.id] = rtt + 'ms';
      this.notice = p.name + ': 连接成功，延迟 ' + rtt + ' ms';
    } else {
      this.testResults[p.id] = '连接失败';
      this.notice = p.name + ': 连接失败';
    }
    this.testingIds = this.testingIds.filter((id: string) => id !== p.id);
  }

  async nat64Rtt(prefix: string): Promise<number> {
    try {
      const netHandle = await connection.getDefaultNet();
      const addrs = await netHandle.getAddressesByName('www.cloudflare.com');
      let mapped = '';
      for (const a of addrs) {
        const ip = a.address;
        if (ip.indexOf(':') >= 0) {
          continue;
        }
        const m = mapNat64(ip, prefix);
        if (m !== null) {
          mapped = m;
          break;
        }
      }
      if (mapped.length === 0) {
        return -1;
      }
      const s = socket.constructTCPSocketInstance();
      const start = Date.now();
      try {
        await s.bind({ address: '::', port: 0, family: 2 });
        await s.connect({ address: { address: mapped, port: 443, family: 2 }, timeout: 4000 });
        return Date.now() - start;
      } catch (err) {
        return -1;
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
            Text('代理')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.font_primary'))
              .layoutWeight(1)
          }
          .width('100%')

          if (this.ipv6Checked) {
            Text(this.ipv6Ok
              ? '配置独立规则前缀以便绕过特定黑名单封锁；在「分流规则 → 编辑 → NAT64」中可选用这些配置。'
              : '当前网络为纯 IPv4：NAT64 配置已禁用且不可点击，检测到 IPv6 后将自动恢复。')
              .fontSize(12)
              .fontColor($r('app.color.font_secondary'))
              .width('100%')
          }

          this.SectionHeader('NAT64 配置管理')

          if (this.nat64Profiles.length === 0) {
            Text('暂无 NAT64 配置')
              .fontSize(14)
              .fontColor($r('app.color.font_secondary'))
              .width('100%')
              .padding(16)
              .backgroundColor($r('app.color.card_bg'))
              .borderRadius(12)
          }

          Column() {
            ForEach(this.nat64Profiles, (p: NAT64Profile, i: number) => {
              Row({ space: 12 }) {
                Column() {
                  Text('NAT64')
                    .fontSize(9)
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
                  Text(p.name)
                    .fontSize(15)
                    .fontColor($r('app.color.font_primary'))
                  Text('前缀：' + p.prefix)
                    .fontSize(12)
                    .fontColor($r('app.color.font_secondary'))
                  if (this.testResults[p.id]) {
                    Text(this.testResults[p.id])
                      .fontSize(12)
                      .fontColor(this.testResults[p.id] === '连接失败'
                        ? $r('app.color.error') : $r('app.color.font_secondary'))
                  }
                  Text(this.testingIds.indexOf(p.id) >= 0 ? '测试中...' : '测试连接')
                    .fontSize(12)
                    .fontColor($r('app.color.accent'))
                    .padding({ top: 2, bottom: 2 })
                    .onClick(() => this.testProfile(p))
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Text('编辑')
                  .fontSize(12)
                  .fontColor($r('app.color.accent'))
                  .onClick(() => {
                    this.editingProfile = p;
                    this.dialogName = p.name;
                    this.dialogPrefix = p.prefix;
                  })
                Text('删除')
                  .fontSize(12)
                  .fontColor($r('app.color.error'))
                  .onClick(() => { this.deletingProfile = p; })
              }
              .width('100%')
              .padding({ top: 10, bottom: 10 })
              .onClick(() => {
                if (this.ipv6Ok) {
                  this.editingProfile = p;
                  this.dialogName = p.name;
                  this.dialogPrefix = p.prefix;
                }
              })

              if (i < this.nat64Profiles.length - 1) {
                Divider()
                  .color($r('app.color.divider'))
                  .strokeWidth(1)
              }
            }, (p: NAT64Profile) => p.id + ':' + p.name + ':' + p.prefix)
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(12)

          Button('添加 NAT64 配置')
            .type(ButtonType.Normal)
            .borderRadius(12)
            .width('100%')
            .height(40)
            .backgroundColor($r('app.color.card_bg'))
            .fontColor($r('app.color.font_primary'))
            .enabled(this.ipv6Ok)
            .onClick(() => {
              this.showAdd = true;
              this.dialogName = '';
              this.dialogPrefix = '2001:67c:2960:6464::';
            })

          Text(this.notice)
            .fontSize(12)
            .fontColor($r('app.color.accent'))
            .width('100%')

          this.SectionHeader('ECH 配置管理')
          this.DisabledCard('ECH 配置管理', '需要 CA 证书与桌面代理架构（MITM/ECH 终结），移动端不支持。')

          this.SectionHeader('连接迁移服务')
          this.DisabledCard('连接迁移服务', '依赖 TLS 会话票据重写（桌面代理专有），移动端不支持。')

          Blank().height(24)
        }
        .width('100%')
        .padding(16)
      }
      .align(Alignment.Top)
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))

      if (this.showAdd || this.editingProfile) {
        this.ProfileDialog(this.editingProfile ? '编辑 NAT64 配置' : '添加 NAT64 配置')
      }
      if (this.deletingProfile) {
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
  DisabledCard(title: string, desc: string) {
    Row({ space: 14 }) {
      Text('×')
        .fontSize(18)
        .fontColor($r('app.color.font_secondary'))
      Column({ space: 2 }) {
        Text(title)
          .fontSize(15)
          .fontColor($r('app.color.font_secondary'))
        Text(desc)
          .fontSize(12)
          .fontColor($r('app.color.font_secondary'))
          .opacity(0.7)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(12)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  ProfileDialog(title: string) {
    Column({ space: 12 }) {
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.font_primary'))
        .width('100%')
      Text('配置名称')
        .fontSize(12)
        .fontColor($r('app.color.font_secondary'))
        .width('100%')
      TextInput({ text: this.dialogName, placeholder: '例如：特定黑名单绕过' })
        .width('100%')
        .onChange((v: string) => { this.dialogName = v; })
      Text('NAT64 前缀')
        .fontSize(12)
        .fontColor($r('app.color.font_secondary'))
        .width('100%')
      TextInput({ text: this.dialogPrefix, placeholder: '例如：64:ff9b::' })
        .width('100%')
        .onChange((v: string) => { this.dialogPrefix = v; })
      Text('支持裸前缀或 CIDR（如 /96）。常用：level66 2001:67c:2960:6464:: · nat64.net 2a01:4f9:c010:3f02:64::')
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
            this.editingProfile = null;
          })
        Button('保存')
          .layoutWeight(1)
          .backgroundColor($r('app.color.accent'))
          .fontColor($r('app.color.font_on_accent'))
          .enabled(this.dialogName.trim().length > 0 && this.dialogPrefix.trim().length > 0)
          .onClick(() => this.confirmProfileDialog())
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
      Text('删除 NAT64 配置')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.font_primary'))
        .width('100%')
      Text('确定要删除此 NAT64 配置吗？')
        .fontSize(13)
        .fontColor($r('app.color.font_secondary'))
        .width('100%')
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .backgroundColor($r('app.color.card_bg'))
          .fontColor($r('app.color.font_primary'))
          .onClick(() => { this.deletingProfile = null; })
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
