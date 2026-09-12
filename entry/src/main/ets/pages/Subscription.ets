import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { ConfigRepository, ImportResult } from '../data/ConfigRepository';
import { PrefsStore } from '../data/PrefsStore';
import { LumineCore } from '../service/LumineCore';
import { SubscriptionProfile } from '../model/VpnTypes';
import { generateConfigName } from '../common/Formatters';

const NEW_SUBSCRIPTION_ID = '__new_subscription__';
const CORE_RUNNING_HINT = 'core is running, cannot validate config now';

interface ImportState {
  stage: string;
  title: string;
  detail: string;
}

function idleImportState(): ImportState {
  const state: ImportState = { stage: 'idle', title: '', detail: '' };
  return state;
}

function pad2(value: number): string {
  return value < 10 ? '0' + value : '' + value;
}

function formatRelativeTime(timestamp: number): string {
  if (timestamp <= 0) {
    return '尚未更新';
  }
  const delta = Date.now() - timestamp;
  const safe = delta > 0 ? delta : 0;
  const minutes = Math.floor(safe / 60000);
  const hours = Math.floor(safe / 3600000);
  const days = Math.floor(safe / 86400000);
  if (minutes < 1) {
    return '刚刚';
  }
  if (minutes < 60) {
    return minutes + ' 分钟前';
  }
  if (hours < 24) {
    return hours + ' 小时前';
  }
  return days + ' 天前';
}

function formatAbsoluteTime(timestamp: number): string {
  if (timestamp <= 0) {
    return '--';
  }
  const d = new Date(timestamp);
  return d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate()) + ' '
    + pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' + pad2(d.getSeconds());
}

function sortSubscriptions(list: SubscriptionProfile[]): SubscriptionProfile[] {
  const out = list.slice();
  out.sort((a: SubscriptionProfile, b: SubscriptionProfile) => {
    if (a.updatedAt !== b.updatedAt) {
      return b.updatedAt - a.updatedAt;
    }
    const an = a.name.toLowerCase();
    const bn = b.name.toLowerCase();
    if (an < bn) {
      return -1;
    }
    if (an > bn) {
      return 1;
    }
    return 0;
  });
  return out;
}

@Entry
@Component
struct Subscription {
  @State subscriptions: SubscriptionProfile[] = [];
  @State selectedConfigName: string = 'config';
  @State busyId: string = '';
  @State refreshingAll: boolean = false;
  @State message: string = '';
  @State showAddDialog: boolean = false;
  @State newName: string = '';
  @State newUrl: string = '';
  @State importState: ImportState = idleImportState();
  @State deletingId: string = '';

  private prefs: PrefsStore | null = null;
  private repo: ConfigRepository | null = null;
  private core: LumineCore = LumineCore.getInstance();
  private currentRequest: http.HttpRequest | null = null;
  private closeTimer: number = -1;
  private menuGuard: boolean = false;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.repo = ConfigRepository.getInstance(ctx);
    this.repo.init().then(() => {
      this.loadAll();
    });
  }

  aboutToDisappear(): void {
    if (this.closeTimer >= 0) {
      clearTimeout(this.closeTimer);
      this.closeTimer = -1;
    }
    this.destroyCurrentRequest();
  }

  destroyCurrentRequest(): void {
    const req = this.currentRequest;
    this.currentRequest = null;
    if (req) {
      try {
        req.destroy();
      } catch (e) {
      }
    }
  }

  async loadAll(): Promise<void> {
    if (this.repo) {
      this.selectedConfigName = await this.repo.getSelectedConfigName();
    }
    await this.loadSubscriptions();
  }

  async loadSubscriptions(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    this.prefs = await PrefsStore.getInstance(ctx);
    const raw = await this.prefs.getString('subscriptions', '[]');
    let loaded: SubscriptionProfile[] = [];
    try {
      loaded = JSON.parse(raw) as SubscriptionProfile[];
    } catch (err) {
      loaded = [];
    }
    this.subscriptions = sortSubscriptions(loaded);
  }

  async persistSubscriptions(): Promise<void> {
    if (this.prefs) {
      await this.prefs.setString('subscriptions', JSON.stringify(this.subscriptions));
    }
  }

  setMessage(text: string): void {
    this.message = text;
  }

  resetImportState(): void {
    this.importState = idleImportState();
  }

  setImport(stage: string, title: string, detail: string): void {
    const state: ImportState = { stage: stage, title: title, detail: detail };
    this.importState = state;
  }

  openAddDialog(): void {
    this.resetImportState();
    this.newName = '';
    this.newUrl = '';
    this.showAddDialog = true;
  }

  errTextOf(e: Error, fallback: string): string {
    const msg = e.message;
    if (typeof msg === 'string' && msg.length > 0) {
      return msg;
    }
    return fallback;
  }

  async downloadText(url: string): Promise<string> {
    this.destroyCurrentRequest();
    const req = http.createHttp();
    this.currentRequest = req;
    const headers: Record<string, string> = {
      'Accept': 'application/json, text/plain, */*',
      'User-Agent': 'LumineHarmonyOS/1.0'
    };
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      connectTimeout: 15000,
      readTimeout: 20000,
      expectDataType: http.HttpDataType.STRING,
      header: headers
    };
    try {
      const resp = await req.request(url, options);
      const body = resp.result as string;
      if (resp.responseCode < 200 || resp.responseCode > 299) {
        throw new Error(('订阅请求失败: HTTP ' + resp.responseCode + ' ' + body.substring(0, 160)).trim());
      }
      if (body.length === 0) {
        throw new Error('订阅内容不是有效的 Lumine 配置 JSON');
      }
      return body;
    } finally {
      if (this.currentRequest === req) {
        this.currentRequest = null;
      }
      try {
        req.destroy();
      } catch (e) {
      }
    }
  }

  async validateAndParse(text: string): Promise<string> {
    const check = this.core.checkConfigJson(text);
    if (check === CORE_RUNNING_HINT) {
      return '核心正在运行，无法校验配置，请先停止核心后重试';
    }
    if (check.length > 0) {
      return '配置校验失败：' + check;
    }
    return '';
  }

  async uniqueConfigName(name: string): Promise<string> {
    const base = generateConfigName(name);
    if (!this.repo) {
      return base + '_' + Date.now();
    }
    const existing = await this.repo.listConfigs();
    if (existing.indexOf(base) < 0) {
      return base;
    }
    let i = 2;
    while (existing.indexOf(base + '_' + i) >= 0) {
      i++;
    }
    return base + '_' + i;
  }

  async applyDownloaded(text: string, configName: string): Promise<string> {
    if (!this.repo) {
      return '存储未就绪';
    }
    const parsed: ImportResult = await this.repo.importConfig(text);
    if (parsed.error !== null) {
      return parsed.error;
    }
    await this.repo.saveConfig(configName, parsed.config);
    return '';
  }

  async addSubscription(): Promise<void> {
    const name = this.newName.trim();
    const url = this.newUrl.trim();
    if (name.length === 0 || url.length === 0) {
      this.setImport('error', '名称和订阅链接都不能为空', '');
      return;
    }
    const dup = this.subscriptions.some((s: SubscriptionProfile) => s.url.toLowerCase() === url.toLowerCase());
    if (dup) {
      this.setImport('error', '这个订阅链接已经添加过了', '');
      return;
    }
    if (this.busyId.length > 0) {
      return;
    }
    this.busyId = NEW_SUBSCRIPTION_ID;
    try {
      this.setImport('validating', '正在校验订阅信息', name);
      this.setImport('connecting', '正在连接订阅服务器', name);
      const text = await this.downloadText(url);
      this.setImport('downloading', '正在下载配置', name);
      this.setImport('parsing', '正在解析配置', name);
      const checkErr = await this.validateAndParse(text);
      if (checkErr.length > 0) {
        this.setImport('error', checkErr, name);
        return;
      }
      this.setImport('saving', '正在保存配置', name);
      const configName = await this.uniqueConfigName(name);
      const saveErr = await this.applyDownloaded(text, configName);
      if (saveErr.length > 0) {
        this.setImport('error', saveErr, name);
        return;
      }
      const sub: SubscriptionProfile = {
        id: configName,
        name: name,
        url: url,
        configName: configName,
        updatedAt: Date.now()
      };
      this.subscriptions = sortSubscriptions(this.subscriptions.concat(sub));
      await this.persistSubscriptions();
      this.setImport('success', '导入完成', name);
      this.setMessage('已导入订阅 ' + name);
      this.closeTimer = setTimeout(() => {
        this.closeTimer = -1;
        this.showAddDialog = false;
        this.resetImportState();
        this.newName = '';
        this.newUrl = '';
      }, 850);
    } catch (err) {
      this.setImport('error', this.errTextOf(err as Error, '导入订阅失败'), name);
    } finally {
      this.busyId = '';
    }
  }

  async refreshSubscription(sub: SubscriptionProfile): Promise<void> {
    if (this.busyId.length > 0) {
      return;
    }
    this.busyId = sub.id;
    try {
      const text = await this.downloadText(sub.url);
      const checkErr = await this.validateAndParse(text);
      if (checkErr.length > 0) {
        throw new Error(checkErr);
      }
      const saveErr = await this.applyDownloaded(text, sub.configName);
      if (saveErr.length > 0) {
        throw new Error(saveErr);
      }
      const updated = this.subscriptions.map((s: SubscriptionProfile) => {
        if (s.id === sub.id) {
          const next: SubscriptionProfile = {
            id: s.id,
            name: s.name,
            url: s.url,
            configName: s.configName,
            updatedAt: Date.now()
          };
          return next;
        }
        return s;
      });
      this.subscriptions = sortSubscriptions(updated);
      await this.persistSubscriptions();
      this.setMessage('已更新 ' + sub.name);
    } catch (err) {
      this.setMessage(this.errTextOf(err as Error, '刷新订阅失败'));
    } finally {
      this.busyId = '';
    }
  }

  async refreshAll(): Promise<void> {
    if (this.refreshingAll || this.busyId.length > 0) {
      return;
    }
    if (this.subscriptions.length === 0) {
      this.setMessage('还没有订阅可以刷新');
      return;
    }
    this.refreshingAll = true;
    try {
      const items = this.subscriptions;
      for (let i = 0; i < items.length; i++) {
        const sub = items[i];
        this.busyId = sub.id;
        const text = await this.downloadText(sub.url);
        const checkErr = await this.validateAndParse(text);
        if (checkErr.length > 0) {
          throw new Error(checkErr);
        }
        const saveErr = await this.applyDownloaded(text, sub.configName);
        if (saveErr.length > 0) {
          throw new Error(saveErr);
        }
        const updated = this.subscriptions.map((s: SubscriptionProfile) => {
          if (s.id === sub.id) {
            const next: SubscriptionProfile = {
              id: s.id,
              name: s.name,
              url: s.url,
              configName: s.configName,
              updatedAt: Date.now()
            };
            return next;
          }
          return s;
        });
        this.subscriptions = sortSubscriptions(updated);
      }
      await this.persistSubscriptions();
      this.setMessage('订阅已全部刷新');
    } catch (err) {
      this.setMessage(this.errTextOf(err as Error, '批量刷新失败'));
    } finally {
      this.busyId = '';
      this.refreshingAll = false;
    }
  }

  async applySubscription(sub: SubscriptionProfile): Promise<void> {
    if (this.busyId.length > 0) {
      return;
    }
    if (this.repo) {
      await this.repo.setSelectedConfigName(sub.configName);
      this.selectedConfigName = sub.configName;
    }
    this.setMessage('已应用 ' + sub.name);
  }

  async deleteSubscription(sub: SubscriptionProfile): Promise<void> {
    if (this.busyId.length > 0) {
      return;
    }
    if (this.repo) {
      await this.repo.deleteConfig(sub.configName);
      if (this.selectedConfigName === sub.configName) {
        await this.repo.setSelectedConfigName('config');
        this.selectedConfigName = 'config';
      }
    }
    this.subscriptions = this.subscriptions.filter((s: SubscriptionProfile) => s.id !== sub.id);
    await this.persistSubscriptions();
    this.setMessage('已删除 ' + sub.name);
  }

  confirmDelete(): void {
    const id = this.deletingId;
    this.deletingId = '';
    const sub = this.subscriptions.find((s: SubscriptionProfile) => s.id === id);
    if (sub) {
      this.deleteSubscription(sub);
    }
  }

  build() {
    Stack() {
      if (this.subscriptions.length === 0) {
        Column() {
          this.TopBar()
          Blank().layoutWeight(1)
          Column({ space: 12 }) {
            Text('还没有配置订阅')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.font_primary'))
              .width('100%')
            Text('添加一个 URL 订阅后，就可以像 Clash 一样在多个配置之间切换。')
              .fontSize(13)
              .fontColor($r('app.color.font_secondary'))
              .width('100%')
            Button('添加订阅')
              .type(ButtonType.Normal)
              .borderRadius(12)
              .width('100%')
              .height(40)
              .backgroundColor($r('app.color.accent'))
              .fontColor($r('app.color.font_on_accent'))
              .onClick(() => this.openAddDialog())
          }
          .width('92%')
          .padding(20)
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(16)
          Blank().layoutWeight(1)
        }
        .width('100%')
        .height('100%')
        .padding(16)
        .backgroundColor($r('app.color.page_bg'))
      } else {
        Scroll() {
          Column({ space: 12 }) {
            this.TopBar()
            ForEach(this.subscriptions, (sub: SubscriptionProfile) => {
              this.SubscriptionCard(sub)
            }, (sub: SubscriptionProfile) => sub.id + ':' + sub.updatedAt.toString() + ':' + this.selectedConfigName)
            Text(this.message)
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
      }

      if (this.showAddDialog) {
        this.AddDialog()
      }
      if (this.deletingId.length > 0) {
        this.DeleteDialog()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  TopBar() {
    Row() {
      Text('<')
        .fontSize(18)
        .fontColor($r('app.color.font_primary'))
        .width(40)
        .height(40)
        .textAlign(TextAlign.Start)
        .onClick(() => router.back())
      Text('配置订阅')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.font_primary'))
        .layoutWeight(1)
      if (this.refreshingAll) {
        LoadingProgress()
          .width(18)
          .height(18)
          .color($r('app.color.accent'))
      } else {
        Text('刷新全部')
          .fontSize(14)
          .fontColor(this.subscriptions.length > 0 && this.busyId.length === 0
            ? $r('app.color.accent') : $r('app.color.font_secondary'))
          .onClick(() => this.refreshAll())
      }
      Text('添加')
        .fontSize(14)
        .fontColor($r('app.color.accent'))
        .margin({ left: 16 })
        .onClick(() => this.openAddDialog())
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
  }

  @Builder
  SubscriptionCard(sub: SubscriptionProfile) {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Column()
          .width(18)
          .height(18)
          .borderRadius(9)
          .backgroundColor(Color.Transparent)
          .borderWidth(this.selectedConfigName === sub.configName ? 5 : 1.5)
          .borderColor(this.selectedConfigName === sub.configName
            ? $r('app.color.accent') : $r('app.color.font_secondary'))
        Column({ space: 2 }) {
          Text(sub.name)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.font_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(sub.url)
            .fontSize(13)
            .fontColor($r('app.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(formatRelativeTime(sub.updatedAt) + '  ·  ' + formatAbsoluteTime(sub.updatedAt))
            .fontSize(12)
            .fontColor($r('app.color.font_secondary'))
          Text('配置名：' + sub.configName)
            .fontSize(12)
            .fontColor($r('app.color.font_secondary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (this.busyId === sub.id) {
          LoadingProgress()
            .width(20)
            .height(20)
            .color($r('app.color.accent'))
        } else {
          Text('更多')
            .fontSize(12)
            .fontColor($r('app.color.font_secondary'))
            .padding(6)
            .onClick(() => {
              this.menuGuard = true;
              setTimeout(() => {
                this.menuGuard = false;
              }, 0);
            })
            .bindMenu([
              {
                value: this.selectedConfigName === sub.configName ? '当前已应用' : '应用此配置',
                action: () => {
                  if (this.selectedConfigName !== sub.configName) {
                    this.applySubscription(sub);
                  }
                }
              },
              {
                value: '刷新订阅',
                action: () => {
                  this.refreshSubscription(sub);
                }
              },
              {
                value: '删除订阅',
                action: () => {
                  this.deletingId = sub.id;
                }
              }
            ])
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        if (this.menuGuard) {
          this.menuGuard = false;
          return;
        }
        if (this.busyId === '') {
          this.applySubscription(sub);
        }
      })

      if (this.busyId === sub.id) {
        LoadingProgress()
          .width(16)
          .height(16)
          .color($r('app.color.accent'))
      } else {
        Divider()
          .color($r('app.color.divider'))
          .strokeWidth(1)
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(16)
    .border({
      width: this.selectedConfigName === sub.configName ? 1.5 : 0,
      color: $r('app.color.accent')
    })
  }

  @Builder
  AddDialog() {
    Column() {
      Column({ space: 14 }) {
        Text(this.importState.stage === 'success' ? '导入完成' : '添加订阅')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.font_primary'))
          .width('100%')
        Text('配置名称')
          .fontSize(12)
          .fontColor($r('app.color.font_secondary'))
          .width('100%')
        TextInput({ text: this.newName, placeholder: '配置名称' })
          .width('100%')
          .enabled(this.busyId !== NEW_SUBSCRIPTION_ID)
          .onChange((v: string) => {
            this.newName = v;
          })
        Text('订阅 URL')
          .fontSize(12)
          .fontColor($r('app.color.font_secondary'))
          .width('100%')
        TextInput({ text: this.newUrl })
          .width('100%')
          .enabled(this.busyId !== NEW_SUBSCRIPTION_ID)
          .onChange((v: string) => {
            this.newUrl = v;
          })

        if (this.importState.stage !== 'idle') {
          Column({ space: 10 }) {
            Row({ space: 8 }) {
              if (this.importState.stage !== 'success' && this.importState.stage !== 'error') {
                LoadingProgress()
                  .width(16)
                  .height(16)
                  .color($r('app.color.accent'))
              }
              Text(this.importState.title)
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.importState.stage === 'success' ? $r('app.color.success')
                  : (this.importState.stage === 'error' ? $r('app.color.error') : $r('app.color.font_primary')))
                .layoutWeight(1)
            }
            .width('100%')
            if (this.importState.detail.length > 0) {
              Text(this.importState.detail)
                .fontSize(12)
                .fontColor($r('app.color.font_secondary'))
                .width('100%')
            }
            if (this.importState.stage === 'success') {
              Text('配置即将出现在列表中')
                .fontSize(12)
                .fontColor($r('app.color.font_secondary'))
                .width('100%')
            }
          }
          .width('100%')
          .padding(14)
          .backgroundColor($r('app.color.page_bg'))
          .borderRadius(12)
        }

        Row({ space: 12 }) {
          Button(this.importState.stage === 'success' ? '完成' : '取消')
            .layoutWeight(1)
            .backgroundColor($r('app.color.card_bg'))
            .fontColor($r('app.color.font_primary'))
            .enabled(this.busyId !== NEW_SUBSCRIPTION_ID)
            .onClick(() => {
              if (this.busyId !== NEW_SUBSCRIPTION_ID) {
                this.showAddDialog = false;
                this.resetImportState();
              }
            })
          Button(this.busyId === NEW_SUBSCRIPTION_ID ? '导入中...'
            : (this.importState.stage === 'error' ? '重试' : '导入'))
            .layoutWeight(1)
            .backgroundColor($r('app.color.accent'))
            .fontColor($r('app.color.font_on_accent'))
            .enabled(this.busyId !== NEW_SUBSCRIPTION_ID
              && this.newName.trim().length > 0 && this.newUrl.trim().length > 0)
            .onClick(() => this.addSubscription())
        }
        .width('100%')
      }
      .width('92%')
      .padding(16)
      .backgroundColor($r('app.color.card_bg'))
      .borderRadius(16)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('rgba(0,0,0,0.35)')
    .onClick(() => {
    })
  }

  @Builder
  DeleteDialog() {
    Column() {
      Column({ space: 12 }) {
        Text('删除订阅')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.font_primary'))
          .width('100%')
        Text('确定要删除此订阅吗？删除后其关联配置也将一并移除。')
          .fontSize(13)
          .fontColor($r('app.color.font_secondary'))
          .width('100%')
        Row({ space: 12 }) {
          Button('取消')
            .layoutWeight(1)
            .backgroundColor($r('app.color.card_bg'))
            .fontColor($r('app.color.font_primary'))
            .onClick(() => {
              this.deletingId = '';
            })
          Button('确定')
            .layoutWeight(1)
            .backgroundColor($r('app.color.error'))
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
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('rgba(0,0,0,0.35)')
    .onClick(() => {
    })
  }
}
