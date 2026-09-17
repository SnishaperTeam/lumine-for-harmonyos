import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { VpnState, SessionStats, LogEntry } from '../model/VpnTypes';
import { VPN_STATE_FILE, RUNTIME_LOG_FILE, MAX_LOG_ENTRIES } from '../common/Constants';

const MAX_RUNTIME_LOG_BYTES: number = 512 * 1024;
const TRIM_KEEP_LINES: number = 500;

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
    if (!this.context) {
      return '';
    }
    return this.context.filesDir + '/' + fileName;
  }

  async readVpnState(): Promise<VpnState> {
    const idle: VpnState = { stage: 'idle', updatedAt: Date.now() };
    try {
      const path = this.getFilePath(VPN_STATE_FILE);
      if (path.length === 0 || !fileIo.accessSync(path)) {
        return idle;
      }
      const content = fileIo.readTextSync(path);
      const parsed = JSON.parse(content) as VpnState;
      if (parsed === null || typeof parsed !== 'object' || typeof parsed.stage !== 'string') {
        return idle;
      }
      return parsed;
    } catch {
      return idle;
    }
  }

  async writeVpnState(state: VpnState): Promise<void> {
    state.updatedAt = Date.now();
    const path = this.getFilePath(VPN_STATE_FILE);
    if (path.length === 0) {
      return;
    }
    let content: string = '';
    try {
      content = JSON.stringify(state);
    } catch {
      return;
    }
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, content);
    } catch {
    } finally {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch {
        }
      }
    }
  }

  async appendLog(entry: LogEntry): Promise<void> {
    const path = this.getFilePath(RUNTIME_LOG_FILE);
    if (path.length === 0) {
      return;
    }
    let line: string = '';
    try {
      line = JSON.stringify(entry) + '\n';
    } catch {
      return;
    }
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.APPEND);
      fileIo.writeSync(file.fd, line);
    } catch {
    } finally {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch {
        }
      }
    }
    this.trimIfOversized(path);
  }

  private trimIfOversized(path: string): void {
    try {
      if (fileIo.statSync(path).size <= MAX_RUNTIME_LOG_BYTES) {
        return;
      }
      const lines = fileIo.readTextSync(path).split('\n');
      const kept = lines.slice(-TRIM_KEEP_LINES).join('\n');
      const fd = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(fd.fd, kept);
      } finally {
        fileIo.closeSync(fd);
      }
    } catch {
    }
  }

  async readLogsTail(count: number = MAX_LOG_ENTRIES): Promise<LogEntry[]> {
    const bounded = count > 0 ? count : MAX_LOG_ENTRIES;
    try {
      const path = this.getFilePath(RUNTIME_LOG_FILE);
      if (path.length === 0 || !fileIo.accessSync(path)) {
        return [];
      }
      const content = fileIo.readTextSync(path);
      const lines = content.trim().split('\n').filter((l: string) => l.length > 0);
      const tail = lines.slice(-bounded);
      const entries: LogEntry[] = [];
      for (const line of tail) {
        try {
          const parsed = JSON.parse(line) as LogEntry;
          if (parsed !== null && typeof parsed === 'object') {
            entries.push(parsed);
          }
        } catch {
        }
      }
      return entries;
    } catch {
      return [];
    }
  }

  async clearLogs(): Promise<void> {
    const path = this.getFilePath(RUNTIME_LOG_FILE);
    if (path.length === 0) {
      return;
    }
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch {
    }
  }
}
