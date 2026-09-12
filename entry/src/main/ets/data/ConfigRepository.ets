import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { LumineConfig, parseLumineConfig, serializeLumineConfig, defaultLumineConfig } from '../model/LumineConfig';
import { PrefsStore } from './PrefsStore';

const CONFIGS_DIR = 'configs';
const EXPORTS_DIR = 'exports';
const MAX_EXPORTS = 10;

export interface ImportResult {
  config: LumineConfig;
  error: string | null;
}

export class ConfigRepository {
  private static instance: ConfigRepository | null = null;
  private context: common.UIAbilityContext | null = null;
  private prefs: PrefsStore | null = null;

  static getInstance(context: common.UIAbilityContext): ConfigRepository {
    if (!ConfigRepository.instance) {
      ConfigRepository.instance = new ConfigRepository();
      ConfigRepository.instance.context = context;
    }
    return ConfigRepository.instance;
  }

  async init(): Promise<void> {
    this.prefs = await PrefsStore.getInstance(this.context!);
    this.ensureDir(this.context!.filesDir + '/' + CONFIGS_DIR);
    this.ensureDir(this.context!.cacheDir + '/' + EXPORTS_DIR);
    await this.ensureDefaultConfig();
  }

  private ensureDir(path: string): void {
    if (fileIo.accessSync(path)) {
      return;
    }
    fileIo.mkdirSync(path, true);
  }

  private async ensureDefaultConfig(): Promise<void> {
    const existing = await this.listConfigs();
    if (existing.length === 0) {
      try {
        const buf = await this.context!.resourceManager.getRawFileContent('config_default.json');
        const decoder = new util.TextDecoder('utf-8');
        const json = decoder.decodeToString(new Uint8Array(buf));
        await this.saveConfig('config', parseLumineConfig(json));
      } catch {
        await this.saveConfig('config', defaultLumineConfig());
      }
    }
  }

  private getConfigPath(name: string): string {
    return this.context!.filesDir + '/' + CONFIGS_DIR + '/' + name + '.json';
  }

  async listConfigs(): Promise<string[]> {
    const configsPath = this.context!.filesDir + '/' + CONFIGS_DIR;
    try {
      const entries = fileIo.listFileSync(configsPath);
      return entries
        .filter((e: string) => e.endsWith('.json'))
        .map((e: string) => e.replace('.json', ''))
        .sort();
    } catch {
      return [];
    }
  }

  async loadConfig(name: string): Promise<LumineConfig | null> {
    try {
      const path = this.getConfigPath(name);
      const content = fileIo.readTextSync(path);
      return parseLumineConfig(content);
    } catch {
      return null;
    }
  }

  async saveConfig(name: string, config: LumineConfig): Promise<void> {
    const path = this.getConfigPath(name);
    const json = serializeLumineConfig(config);
    const fd = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(fd.fd, json);
    fileIo.closeSync(fd);
  }

  async deleteConfig(name: string): Promise<void> {
    if (name === 'config') return;
    try {
      const path = this.getConfigPath(name);
      fileIo.unlinkSync(path);
    } catch {
      // Best effort
    }
  }

  async getSelectedConfigName(): Promise<string> {
    return await this.prefs!.getString('selectedConfig', 'config');
  }

  async setSelectedConfigName(name: string): Promise<void> {
    await this.prefs!.setString('selectedConfig', name);
  }

  async getVpnShouldRun(): Promise<boolean> {
    return await this.prefs!.getBool('vpnShouldRun', false);
  }

  async setVpnShouldRun(value: boolean): Promise<void> {
    await this.prefs!.setBool('vpnShouldRun', value);
  }

  async getLastRunningConfig(): Promise<string> {
    return await this.prefs!.getString('lastRunningConfig', 'config');
  }

  async setLastRunningConfig(name: string): Promise<void> {
    await this.prefs!.setString('lastRunningConfig', name);
  }

  async disabledRuleKeys(configName: string): Promise<string[]> {
    return await this.prefs!.getStringList('disabledRules_' + configName);
  }

  async setRuleEnabled(configName: string, config: LumineConfig, ruleKey: string, enabled: boolean): Promise<void> {
    let disabled = await this.disabledRuleKeys(configName);
    if (enabled) {
      disabled = disabled.filter((k: string) => k !== ruleKey);
    } else {
      if (!disabled.includes(ruleKey)) {
        disabled.push(ruleKey);
      }
    }
    await this.prefs!.setStringList('disabledRules_' + configName, disabled);
  }

  async importConfig(json: string): Promise<ImportResult> {
    try {
      const config = parseLumineConfig(json);
      const result: ImportResult = { config: config, error: null };
      return result;
    } catch (e) {
      const result: ImportResult = { config: defaultLumineConfig(), error: '配置解析失败: ' + String(e) };
      return result;
    }
  }

  async exportConfig(name: string): Promise<string | null> {
    try {
      const config = await this.loadConfig(name);
      if (!config) return null;
      return serializeLumineConfig(config);
    } catch {
      return null;
    }
  }
}
