import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const STORE_NAME = 'lumine_prefs';

export class PrefsStore {
  private static instance: PrefsStore | null = null;
  private static pending: Promise<PrefsStore> | null = null;
  private store: preferences.Preferences | null = null;

  static async getInstance(context: common.UIAbilityContext): Promise<PrefsStore> {
    if (PrefsStore.instance !== null && PrefsStore.instance.store !== null) {
      return PrefsStore.instance;
    }
    if (PrefsStore.pending !== null) {
      return await PrefsStore.pending;
    }
    PrefsStore.pending = PrefsStore.create(context);
    try {
      return await PrefsStore.pending;
    } finally {
      PrefsStore.pending = null;
    }
  }

  private static async create(context: common.UIAbilityContext): Promise<PrefsStore> {
    const store = new PrefsStore();
    try {
      store.store = await preferences.getPreferences(context, STORE_NAME);
    } catch (err) {
      store.store = null;
    }
    PrefsStore.instance = store;
    return store;
  }

  isReady(): boolean {
    return this.store !== null;
  }

  async getString(key: string, defaultValue: string = ''): Promise<string> {
    if (!this.store) {
      return defaultValue;
    }
    try {
      const val = await this.store.get(key, defaultValue);
      return typeof val === 'string' ? val as string : defaultValue;
    } catch {
      return defaultValue;
    }
  }

  async setString(key: string, value: string): Promise<void> {
    if (!this.store) {
      return;
    }
    try {
      await this.store.put(key, value);
      await this.store.flush();
    } catch {
    }
  }

  async getNumber(key: string, defaultValue: number = 0): Promise<number> {
    if (!this.store) {
      return defaultValue;
    }
    try {
      const val = await this.store.get(key, defaultValue);
      return typeof val === 'number' ? val as number : defaultValue;
    } catch {
      return defaultValue;
    }
  }

  async setNumber(key: string, value: number): Promise<void> {
    if (!this.store) {
      return;
    }
    try {
      await this.store.put(key, value);
      await this.store.flush();
    } catch {
    }
  }

  async getBool(key: string, defaultValue: boolean = false): Promise<boolean> {
    if (!this.store) {
      return defaultValue;
    }
    try {
      const val = await this.store.get(key, defaultValue);
      return typeof val === 'boolean' ? val as boolean : defaultValue;
    } catch {
      return defaultValue;
    }
  }

  async setBool(key: string, value: boolean): Promise<void> {
    if (!this.store) {
      return;
    }
    try {
      await this.store.put(key, value);
      await this.store.flush();
    } catch {
    }
  }

  async getStringArray(key: string): Promise<string[]> {
    if (!this.store) {
      return [];
    }
    try {
      const val = await this.store.get(key, []);
      if (!Array.isArray(val)) {
        return [];
      }
      const out: string[] = [];
      for (const item of val as Object[]) {
        if (typeof item === 'string') {
          out.push(item as string);
        }
      }
      return out;
    } catch {
      return [];
    }
  }

  async setStringArray(key: string, value: string[]): Promise<void> {
    if (!this.store) {
      return;
    }
    try {
      await this.store.put(key, value);
      await this.store.flush();
    } catch {
    }
  }

  async getStringList(key: string): Promise<string[]> {
    return this.getStringArray(key);
  }

  async setStringList(key: string, value: string[]): Promise<void> {
    await this.setStringArray(key, value);
  }
}
