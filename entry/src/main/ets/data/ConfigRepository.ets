import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { LumineConfig, parseLumineConfig, serializeLumineConfig, defaultLumineConfig } from '../model/LumineConfig';
import { PrefsStore } from './PrefsStore';

const CONFIGS_DIR = 'configs';
const EXPORTS_DIR = 'exports';
const MAX_EXPORTS = 10;
const MAX_CONFIG_NAME_LEN = 64;

export function isSafeConfigName(name: string): boolean {
  if (name.length === 0 || name.length > MAX_CONFIG_NAME_LEN) {
    return false;
  }
  if (name.startsWith('.')) {
    return false;
  }
  if (name.includes('/') || name.includes('\\') || name.includes('..') || name.includes(':')) {
    return false;
  }
  for (let i = 0; i < name.length; i++) {
    const code = name.charCodeAt(i);
    if (code < 0x20 || code === 0x7f) {
      return false;
    }
  }
  return true;
}

export function sanitizeConfigName(name: string, fallback: string): string {
  if (isSafeConfigName(name)) {
    return name;
  }
  const cleaned = name.replace(/[^a-zA-Z0-9_\u4e00-\u9fff-]/g, '_').substring(0, MAX_CONFIG_NAME_LEN);
  if (isSafeConfigName(cleaned)) {
    return cleaned;
  }
  return fallback;
}

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
    if (!this.context) {
      return;
    }
    this.prefs = await PrefsStore.getInstance(this.context);
    this.ensureDir(this.context.filesDir + '/' + CONFIGS_DIR);
    this.ensureDir(this.context.cacheDir + '/' + EXPORTS_DIR);
    await this.ensureDefaultConfig();
  }

  private ensureDir(path: string): void {
    try {
      if (fileIo.accessSync(path)) {
        return;
      }
      fileIo.mkdirSync(path, true);
    } catch {
    }
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
    if (!this.context) {
      return '';
    }
    return this.context.filesDir + '/' + CONFIGS_DIR + '/' + sanitizeConfigName(name, 'config') + '.json';
  }

  async listConfigs(): Promise<string[]> {
    if (!this.context) {
      return [];
    }
    const configsPath = this.context.filesDir + '/' + CONFIGS_DIR;
    try {
      const entries = fileIo.listFileSync(configsPath);
      return entries
        .filter((e: string) => e.endsWith('.json'))
        .map((e: string) => e.substring(0, e.length - '.json'.length))
        .filter((e: string) => isSafeConfigName(e))
        .sort();
    } catch {
      return [];
    }
  }

  async loadConfig(name: string): Promise<LumineConfig | null> {
    try {
      const path = this.getConfigPath(name);
      if (path.length === 0) {
        return null;
      }
      const content = fileIo.readTextSync(path);
      return parseLumineConfig(content);
    } catch {
      return null;
    }
  }

  async saveConfig(name: string, config: LumineConfig): Promise<void> {
    const path = this.getConfigPath(name);
    if (path.length === 0) {
      throw new Error('存储未就绪');
    }
    const json = serializeLumineConfig(config);
    const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, json);
    } finally {
      try {
        fileIo.closeSync(file);
      } catch {
      }
    }
  }

  async deleteConfig(name: string): Promise<void> {
    if (name === 'config') {
      return;
    }
    try {
      const path = this.getConfigPath(name);
      if (path.length === 0) {
        return;
      }
      fileIo.unlinkSync(path);
    } catch {
    }
  }

  async getSelectedConfigName(): Promise<string> {
    if (!this.prefs) {
      return 'config';
    }
    return await this.prefs.getString('selectedConfig', 'config');
  }

  async setSelectedConfigName(name: string): Promise<void> {
    if (!this.prefs) {
      return;
    }
    await this.prefs.setString('selectedConfig', sanitizeConfigName(name, 'config'));
  }

  async getVpnShouldRun(): Promise<boolean> {
    if (!this.prefs) {
      return false;
    }
    return await this.prefs.getBool('vpnShouldRun', false);
  }

  async setVpnShouldRun(value: boolean): Promise<void> {
    if (!this.prefs) {
      return;
    }
    await this.prefs.setBool('vpnShouldRun', value);
  }

  async getLastRunningConfig(): Promise<string> {
    if (!this.prefs) {
      return 'config';
    }
    return await this.prefs.getString('lastRunningConfig', 'config');
  }

  async setLastRunningConfig(name: string): Promise<void> {
    if (!this.prefs) {
      return;
    }
    await this.prefs.setString('lastRunningConfig', sanitizeConfigName(name, 'config'));
  }

  async disabledRuleKeys(configName: string): Promise<string[]> {
    if (!this.prefs) {
      return [];
    }
    return await this.prefs.getStringList('disabledRules_' + configName);
  }

  async setRuleEnabled(configName: string, config: LumineConfig, ruleKey: string, enabled: boolean): Promise<void> {
    if (!this.prefs) {
      return;
    }
    let disabled = await this.disabledRuleKeys(configName);
    if (enabled) {
      disabled = disabled.filter((k: string) => k !== ruleKey);
    } else {
      if (!disabled.includes(ruleKey)) {
        disabled.push(ruleKey);
      }
    }
    await this.prefs.setStringList('disabledRules_' + configName, disabled);
  }

  async importConfig(json: string): Promise<ImportResult> {
    try {
      const config = parseLumineConfig(json);
      const result: ImportResult = { config: config, error: null };
      return result;
    } catch (e) {
      const detail = e instanceof Error ? e.message : String(e);
      const result: ImportResult = { config: defaultLumineConfig(), error: '配置解析失败: ' + detail };
      return result;
    }
  }

  async exportConfig(name: string): Promise<string | null> {
    try {
      const config = await this.loadConfig(name);
      if (!config) {
        return null;
      }
      return serializeLumineConfig(config);
    } catch {
      return null;
    }
  }
}
