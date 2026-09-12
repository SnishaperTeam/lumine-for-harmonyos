import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const STORE_NAME = 'lumine_prefs';

export class PrefsStore {
  private static instance: PrefsStore | null = null;
  private store: preferences.Preferences | null = null;

  static async getInstance(context: common.UIAbilityContext): Promise<PrefsStore> {
    if (!PrefsStore.instance) {
      PrefsStore.instance = new PrefsStore();
      PrefsStore.instance.store = await preferences.getPreferences(context, STORE_NAME);
    }
    return PrefsStore.instance;
  }

  async getString(key: string, defaultValue: string = ''): Promise<string> {
    if (!this.store) return defaultValue;
    const val = await this.store.get(key, defaultValue);
    return val as string;
  }

  async setString(key: string, value: string): Promise<void> {
    if (!this.store) return;
    await this.store.put(key, value);
    await this.store.flush();
  }

  async getNumber(key: string, defaultValue: number = 0): Promise<number> {
    if (!this.store) return defaultValue;
    const val = await this.store.get(key, defaultValue);
    return val as number;
  }

  async setNumber(key: string, value: number): Promise<void> {
    if (!this.store) return;
    await this.store.put(key, value);
    await this.store.flush();
  }

  async getBool(key: string, defaultValue: boolean = false): Promise<boolean> {
    if (!this.store) return defaultValue;
    const val = await this.store.get(key, defaultValue);
    return val as boolean;
  }

  async setBool(key: string, value: boolean): Promise<void> {
    if (!this.store) return;
    await this.store.put(key, value);
    await this.store.flush();
  }

  async getStringArray(key: string): Promise<string[]> {
    if (!this.store) return [];
    const val = await this.store.get(key, []);
    return val as string[];
  }

  async setStringArray(key: string, value: string[]): Promise<void> {
    if (!this.store) return;
    await this.store.put(key, value);
    await this.store.flush();
  }

  async getStringList(key: string): Promise<string[]> {
    return this.getStringArray(key);
  }

  async setStringList(key: string, value: string[]): Promise<void> {
    await this.setStringArray(key, value);
  }
}
