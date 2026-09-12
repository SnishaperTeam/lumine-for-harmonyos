import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { ConfigRepository } from '../data/ConfigRepository';
import { DEFAULT_CONFIG_NAME } from '../common/Constants';
import { LumineConfig, Policy } from '../model/LumineConfig';

interface RuleTypeOption {
  id: string;
  label: string;
  desc: string;
}

const RULE_TYPE_OPTIONS: RuleTypeOption[] = [
  { id: 'domain', label: '域名规则', desc: '按域名匹配，例如 *.bing.com' },
  { id: 'ip', label: 'IP 规则', desc: '按 IP/CIDR 匹配，例如 1.2.3.0/24' }
];

function containsIgnoreCase(haystack: string, needle: string): boolean {
  return haystack.toLowerCase().indexOf(needle.toLowerCase()) >= 0;
}

@Entry
@Component
struct RuleList {
  @State config: LumineConfig | null = null;
  @State searchText: string = '';
  @State showCreate: boolean = false;
  @State newType: string = 'domain';
  @State newKey: string = '';
  @State disabledRules: string[] = [];
  @State deletingKey: string = '';
  @State deletingIsDomain: boolean = false;

  private repo: ConfigRepository | null = null;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.repo = ConfigRepository.getInstance(ctx);
    this.repo.init().then(() => {
      this.loadRules();
    });
  }

  async loadRules(): Promise<void> {
    if (!this.repo) {
      return;
    }
    this.config = await this.repo.loadConfig('config');
    this.disabledRules = await this.repo.disabledRuleKeys('config');
  }

  keysOf(isDomain: boolean): string[] {
    if (!this.config) {
      return [];
    }
    const map = isDomain ? this.config.domain_policies : this.config.ip_policies;
    const keys: string[] = Object.keys(map);
    keys.sort();
    return keys;
  }

  filteredKeys(isDomain: boolean): string[] {
    const q = this.searchText.trim();
    const all = this.keysOf(isDomain);
    if (q.length === 0) {
      return all;
    }
    const extra = isDomain ? '域名规则 domain' : 'IP 规则 ip ip/cidr';
    const out: string[] = [];
    for (const k of all) {
      if (containsIgnoreCase(k, q) || containsIgnoreCase(extra, q)) {
        out.push(k);
      }
    }
    return out;
  }

  private isEnabled(key: string): boolean {
    return this.disabledRules.indexOf(key) < 0;
  }

  async toggleRule(key: string, enabled: boolean): Promise<void> {
    if (this.repo && this.config) {
      await this.repo.setRuleEnabled('config', this.config, key, enabled);
      this.disabledRules = await this.repo.disabledRuleKeys('config');
    }
  }

  openEditor(key: string, isDomain: boolean): void {
    const params: Record<string, Object> = { 'key': encodeURIComponent(key), 'tab': isDomain ? 0 : 1 };
    router.pushUrl({ url: 'pages/RuleEditor', params: params });
  }

  confirmCreate(): void {
    const key = this.newKey.trim();
    if (key.length === 0) {
      return;
    }
    this.showCreate = false;
    this.openEditor(key, this.newType === 'domain');
  }

  async confirmDelete(): Promise<void> {
    const key = this.deletingKey;
    const isDomain = this.deletingIsDomain;
    this.deletingKey = '';
    if (key.length === 0 || !this.repo || !this.config) {
      return;
    }
    const map = isDomain ? this.config.domain_policies : this.config.ip_policies;
    const next: Record<string, Policy> = {};
    const keys: string[] = Object.keys(map);
    for (const k of keys) {
      if (k !== key) {
        next[k] = map[k];
      }
    }
    if (isDomain) {
      this.config.domain_policies = next;
    } else {
      this.config.ip_policies = next;
    }
    await this.repo.saveConfig('config', this.config);
    await this.repo.setRuleEnabled('config', this.config, key, true);
    await this.loadRules();
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
            Text('网站规则')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.font_primary'))
            Text(DEFAULT_CONFIG_NAME)
              .fontSize(12)
              .fontColor($r('app.color.font_secondary'))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Text('+')
            .fontSize(24)
            .fontColor($r('app.color.accent'))
            .width(40)
            .height(40)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.newKey = '';
              this.newType = 'domain';
              this.showCreate = true;
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16 })

        Row() {
          TextInput({ text: this.searchText, placeholder: '搜索规则、分类或域名...' })
            .width('100%')
            .height(44)
            .backgroundColor($r('app.color.card_bg'))
            .borderRadius(22)
            .padding({ left: 16, right: 16 })
            .onChange((v: string) => {
              this.searchText = v;
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
        .margin({ top: 8, bottom: 8 })

        Scroll() {
          Column({ space: 4 }) {
            if (this.filteredKeys(true).length === 0 && this.filteredKeys(false).length === 0) {
              Text('未找到结果')
                .fontSize(14)
                .fontColor($r('app.color.font_secondary'))
                .width('100%')
                .padding(16)
            }

            this.SectionHeader('域名规则 (' + this.filteredKeys(true).length + ')')

            if (this.filteredKeys(true).length > 0) {
              Column() {
                ForEach(this.filteredKeys(true), (key: string, i: number) => {
                  this.RuleRow(key, true)
                  if (i < this.filteredKeys(true).length - 1) {
                    Divider()
                      .color($r('app.color.divider'))
                      .strokeWidth(1)
                      .margin({ left: 72 })
                  }
                }, (key: string) => key)
              }
              .width('100%')
              .padding({ left: 16, right: 16 })
              .backgroundColor($r('app.color.card_bg'))
              .borderRadius(12)
            }

            this.SectionHeader('IP 规则 (' + this.filteredKeys(false).length + ')')

            if (this.filteredKeys(false).length > 0) {
              Column() {
                ForEach(this.filteredKeys(false), (key: string, i: number) => {
                  this.RuleRow(key, false)
                  if (i < this.filteredKeys(false).length - 1) {
                    Divider()
                      .color($r('app.color.divider'))
                      .strokeWidth(1)
                      .margin({ left: 72 })
                  }
                }, (key: string) => key)
              }
              .width('100%')
              .padding({ left: 16, right: 16 })
              .backgroundColor($r('app.color.card_bg'))
              .borderRadius(12)
            }

            Blank().height(24)
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
        }
        .layoutWeight(1)
        .width('100%')
        .edgeEffect(EdgeEffect.None)
        .scrollBar(BarState.Off)
      }
      .align(Alignment.Top)
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))

      if (this.showCreate) {
        this.CreateDialog()
      }
      if (this.deletingKey.length > 0) {
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
      .padding({ top: 10, bottom: 4 })
  }

  @Builder
  RuleRow(key: string, isDomain: boolean) {
    Row({ space: 12 }) {
      Column() {
        Text(isDomain ? '域名' : 'IP')
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
        Text(key)
          .fontSize(15)
          .fontColor($r('app.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(isDomain ? '域名规则' : 'IP/CIDR')
          .fontSize(12)
          .fontColor($r('app.color.font_secondary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .onClick(() => this.openEditor(key, isDomain))

      Text('删除')
        .fontSize(12)
        .fontColor($r('app.color.error'))
        .onClick(() => {
          this.deletingKey = key;
          this.deletingIsDomain = isDomain;
        })

      Toggle({ type: ToggleType.Switch, isOn: this.isEnabled(key) })
        .selectedColor($r('app.color.accent'))
        .onChange((on: boolean) => {
          this.toggleRule(key, on);
        })
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }

  @Builder
  CreateDialog() {
    Column({ space: 12 }) {
      Text('新建规则')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.font_primary'))
        .width('100%')
      ForEach(RULE_TYPE_OPTIONS, (opt: RuleTypeOption) => {
        Row({ space: 12 }) {
          Column()
            .width(18)
            .height(18)
            .borderRadius(9)
            .backgroundColor(Color.Transparent)
            .borderWidth(this.newType === opt.id ? 5 : 1.5)
            .borderColor(this.newType === opt.id ? $r('app.color.accent') : $r('app.color.font_secondary'))
          Column({ space: 2 }) {
            Text(opt.label)
              .fontSize(15)
              .fontColor($r('app.color.font_primary'))
            Text(opt.desc)
              .fontSize(12)
              .fontColor($r('app.color.font_secondary'))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding({ top: 6, bottom: 6 })
        .onClick(() => {
          this.newType = opt.id;
        })
      }, (opt: RuleTypeOption) => opt.id)
      Text(this.newType === 'domain' ? '域名匹配' : 'IP/CIDR')
        .fontSize(12)
        .fontColor($r('app.color.font_secondary'))
        .width('100%')
      TextInput({ text: this.newKey, placeholder: this.newType === 'domain' ? '例如 *.bing.com' : '例如 1.2.3.0/24' })
        .width('100%')
        .onChange((v: string) => {
          this.newKey = v;
        })
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .backgroundColor($r('app.color.card_bg'))
          .fontColor($r('app.color.font_primary'))
          .onClick(() => {
            this.showCreate = false;
          })
        Button('继续')
          .layoutWeight(1)
          .backgroundColor($r('app.color.accent'))
          .fontColor($r('app.color.font_on_accent'))
          .enabled(this.newKey.trim().length > 0)
          .onClick(() => this.confirmCreate())
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
      Text('删除规则')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.font_primary'))
        .width('100%')
      Text('确定要删除规则 ' + this.deletingKey + ' 吗？')
        .fontSize(13)
        .fontColor($r('app.color.font_secondary'))
        .width('100%')
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .backgroundColor($r('app.color.card_bg'))
          .fontColor($r('app.color.font_primary'))
          .onClick(() => {
            this.deletingKey = '';
          })
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
