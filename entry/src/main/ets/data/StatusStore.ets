import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { VpnState, SessionStats, LogEntry } from '../model/VpnTypes';
import { VPN_STATE_FILE, RUNTIME_LOG_FILE, MAX_LOG_ENTRIES } from '../common/Constants';

export class StatusStore {
  private static instance: StatusStore | null = null;
  private context: common.Context | null = null;

  static getInstance(context: common.Context): StatusStore {
    if (!StatusStore.instance) {
      StatusStore.instance = new StatusStore();
      StatusStore.instance.context = context;
    }
    return StatusStore.instance;
  }

  cacheDir(): string {
    return this.context ? this.context.cacheDir : '';
  }

  private getFilePath(fileName: string): string {
    return this.context!.filesDir + '/' + fileName;
  }

  async readVpnState(): Promise<VpnState> {
    try {
      const path = this.getFilePath(VPN_STATE_FILE);
      if (!fileIo.accessSync(path)) {
        return { stage: 'idle', updatedAt: Date.now() };
      }
      const content = fileIo.readTextSync(path);
      return JSON.parse(content) as VpnState;
    } catch {
      return { stage: 'idle', updatedAt: Date.now() };
    }
  }

  async writeVpnState(state: VpnState): Promise<void> {
    state.updatedAt = Date.now();
    const path = this.getFilePath(VPN_STATE_FILE);
    const content = JSON.stringify(state);
    try {
      const fd = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(fd.fd, content);
      fileIo.closeSync(fd);
    } catch {
      // Best effort
    }
  }

  async appendLog(entry: LogEntry): Promise<void> {
    const path = this.getFilePath(RUNTIME_LOG_FILE);
    const line = JSON.stringify(entry) + '\n';
    try {
      const fd = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.APPEND);
      fileIo.writeSync(fd.fd, line);
      fileIo.closeSync(fd);
    } catch {
      // Best effort
    }
  }

  async readLogsTail(count: number = MAX_LOG_ENTRIES): Promise<LogEntry[]> {
    try {
      const path = this.getFilePath(RUNTIME_LOG_FILE);
      if (!fileIo.accessSync(path)) {
        return [];
      }
      const content = fileIo.readTextSync(path);
      const lines = content.trim().split('\n').filter((l: string) => l.length > 0);
      const tail = lines.slice(-count);
      const entries: LogEntry[] = [];
      for (const line of tail) {
        try {
          entries.push(JSON.parse(line) as LogEntry);
        } catch {
          // skip malformed
        }
      }
      return entries;
    } catch {
      return [];
    }
  }

  async clearLogs(): Promise<void> {
    const path = this.getFilePath(RUNTIME_LOG_FILE);
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch {
      // Best effort
    }
  }
}
