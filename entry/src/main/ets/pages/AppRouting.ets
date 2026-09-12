import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { PrefsStore } from '../data/PrefsStore';
import { AppRoutingMode } from '../model/VpnTypes';

interface ModeOption {
  id: string;
  label: string;
  description: string;
}

const MODE_OPTIONS: ModeOption[] = [
  { id: AppRoutingMode.ALL, label: '代理全部应用', description: '所有应用流量经 Lumine 隧道转发' },
  { id: AppRoutingMode.WHITELIST, label: '白名单模式', description: '仅列表中选中的应用走代理，其余应用直连' },
  { id: AppRoutingMode.BYPASS, label: '绕过模式', description: '列表中选中的应用直连，其余应用走代理' }
];

function modeLabel(mode: string): string {
  if (mode === AppRoutingMode.WHITELIST) {
    return '白名单：仅所选应用走代理';
  }
  if (mode === AppRoutingMode.BYPASS) {
    return '绕过名单：所选应用直连';
  }
  return '代理全部应用';
}

@Entry
@Component
struct AppRouting {
  @State mode: string = AppRoutingMode.ALL;
  @State packages: string[] = [];
  @State manualApps: string[] = [];
  @State newPackage: string = '';

  private prefs: PrefsStore | null = null;
  private removeGuard: boolean = false;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.loadPrefs(ctx);
  }

  async loadPrefs(ctx: common.UIAbilityContext): Promise<void> {
    this.prefs = await PrefsStore.getInstance(ctx);
    this.mode = await this.prefs.getString('appRoutingMode', AppRoutingMode.ALL);
    this.packages = await this.prefs.getStringList('appRoutingPackages');
    const manual = await this.prefs.getString('appRoutingManualPackages', '[]');
    let loaded: string[] = [];
    try {
      loaded = JSON.parse(manual) as string[];
    } catch (err) {
      loaded = [];
    }
    this.manualApps = loaded;
  }

  async saveMode(nextMode: string): Promise<void> {
    this.mode = nextMode;
    if (this.prefs) {
      await this.prefs.setString('appRoutingMode', nextMode);
    }
  }

  async savePackages(next: string[]): Promise<void> {
    this.packages = next;
    if (this.prefs) {
      await this.prefs.setStringList('appRoutingPackages', next);
    }
  }

  async saveManualApps(next: string[]): Promise<void> {
    this.manualApps = next;
    if (this.prefs) {
      await this.prefs.setString('appRoutingManualPackages', JSON.stringify(next));
    }
  }

  addPackage(): void {
    const pkg = this.newPackage.trim();
    if (pkg.length === 0) {
      return;
    }
    this.newPackage = '';
    if (this.manualApps.indexOf(pkg) < 0) {
      this.saveManualApps(this.manualApps.concat(pkg));
    }
    if (this.packages.indexOf(pkg) < 0) {
      this.savePackages(this.packages.concat(pkg));
    }
  }

  togglePackage(pkg: string): void {
    if (this.packages.indexOf(pkg) >= 0) {
      this.savePackages(this.packages.filter((p: string) => p !== pkg));
    } else {
      this.savePackages(this.packages.concat(pkg));
    }
  }

  removePackage(pkg: string): void {
    this.savePackages(this.packages.filter((p: string) => p !== pkg));
    this.saveManualApps(this.manualApps.filter((p: string) => p !== pkg));
  }

  selectAllManual(): void {
    let next = this.packages.slice();
    for (let i = 0; i < this.manualApps.length; i++) {
      if (next.indexOf(this.manualApps[i]) < 0) {
        next = next.concat(this.manualApps[i]);
      }
    }
    this.savePackages(next);
  }

  clearManual(): void {
    this.savePackages(this.packages.filter((p: string) => this.manualApps.indexOf(p) < 0));
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
            Text('分应用路由')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.font_primary'))
              .layoutWeight(1)
          }
          .width('100%')

          this.SectionHeader('路由方式')

          Column() {
            ForEach(MODE_OPTIONS, (opt: ModeOption) => {
              this.RadioRow(opt)
            }, (opt: ModeOption) => opt.id)
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(12)

          if (this.mode !== AppRoutingMode.ALL) {
            Text('当前：' + modeLabel(this.mode) + ' · 已选 ' + this.packages.length + ' 个应用')
              .fontSize(12)
              .fontColor($r('app.color.font_secondary'))
              .width('100%')

            Row({ space: 8 }) {
              TextInput({ text: this.newPackage, placeholder: '输入应用包名' })
                .layoutWeight(1)
                .onChange((v: string) => {
                  this.newPackage = v;
                })
              Button('添加')
                .type(ButtonType.Normal)
                .borderRadius(12)
                .height(40)
                .backgroundColor($r('app.color.accent'))
                .fontColor($r('app.color.font_on_accent'))
                .onClick(() => this.addPackage())
            }
            .width('100%')

            Row({ space: 16 }) {
              Text('全选')
                .fontSize(14)
                .fontColor($r('app.color.accent'))
                .onClick(() => this.selectAllManual())
              Text('清空')
                .fontSize(14)
                .fontColor($r('app.color.accent'))
                .onClick(() => this.clearManual())
              Blank()
            }
            .width('100%')

            Text('鸿蒙端不支持枚举应用列表，请手动输入包名')
              .fontSize(12)
              .fontColor($r('app.color.font_secondary'))
              .width('100%')

            if (this.mode === AppRoutingMode.WHITELIST && this.packages.length === 0) {
              Text('未选择任何应用，VPN 建立后不会代理任何应用（等同关闭）。')
                .fontSize(12)
                .fontColor($r('app.color.error'))
                .width('100%')
            }

            Divider()
              .color($r('app.color.divider'))
              .strokeWidth(1)
              .margin({ top: 4, bottom: 4 })

            if (this.manualApps.length === 0) {
              Text('暂无手动添加的包名')
                .fontSize(13)
                .fontColor($r('app.color.font_secondary'))
                .width('100%')
                .padding(12)
                .backgroundColor($r('app.color.card_bg'))
                .borderRadius(12)
            } else {
              Column() {
                ForEach(this.manualApps, (pkg: string) => {
                  this.PackageRow(pkg)
                }, (pkg: string) => pkg)
              }
              .width('100%')
              .padding({ left: 16, right: 16 })
              .backgroundColor($r('app.color.card_bg'))
              .borderRadius(12)
            }
          } else {
            Text('白名单/绕过名单仅作用于 VPN 建连时刻，修改后需重启连接生效。')
              .fontSize(12)
              .fontColor($r('app.color.font_secondary'))
              .width('100%')
              .padding({ top: 8, bottom: 8 })
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
  RadioRow(opt: ModeOption) {
    Row({ space: 12 }) {
      Column()
        .width(18)
        .height(18)
        .borderRadius(9)
        .backgroundColor(Color.Transparent)
        .borderWidth(this.mode === opt.id ? 5 : 1.5)
        .borderColor(this.mode === opt.id ? $r('app.color.accent') : $r('app.color.font_secondary'))
      Column({ space: 2 }) {
        Text(opt.label)
          .fontSize(15)
          .fontColor($r('app.color.font_primary'))
        Text(opt.description)
          .fontSize(12)
          .fontColor($r('app.color.font_secondary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .onClick(() => {
      this.saveMode(opt.id);
    })
  }

  @Builder
  PackageRow(pkg: string) {
    Row({ space: 12 }) {
      Row() {
        if (this.packages.indexOf(pkg) >= 0) {
          Text('✓')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.font_on_accent'))
        }
      }
      .width(20)
      .height(20)
      .borderRadius(4)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.packages.indexOf(pkg) >= 0 ? $r('app.color.accent') : Color.Transparent)
      .borderWidth(this.packages.indexOf(pkg) >= 0 ? 0 : 1.5)
      .borderColor($r('app.color.font_secondary'))

      Text(pkg)
        .fontSize(14)
        .fontColor($r('app.color.font_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      Text('移除')
        .fontSize(12)
        .fontColor($r('app.color.error'))
        .onClick(() => {
          this.removeGuard = true;
          this.removePackage(pkg);
          setTimeout(() => {
            this.removeGuard = false;
          }, 0);
        })
    }
    .width('100%')
    .padding({ top: 9, bottom: 9 })
    .onClick(() => {
      if (this.removeGuard) {
        this.removeGuard = false;
        return;
      }
      this.togglePackage(pkg);
    })
  }
}
