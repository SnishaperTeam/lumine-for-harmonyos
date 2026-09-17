import lumine from 'liblumine_napi.so';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

const MAX_LOG_CHUNK_BYTES: number = 256 * 1024;
const MAX_CORE_LOG_CHARS: number = 600;

export class LumineCore {
  private static instance: LumineCore | null = null;
  private statsPath: string = '';
  private logPath: string = '';
  private coreLogPath: string = '';
  private logOffset: number = 0;

  static getInstance(): LumineCore {
    if (!LumineCore.instance) {
      LumineCore.instance = new LumineCore();
    }
    return LumineCore.instance;
  }

  start(workDir: string, configName: string, tunFd: number): string {
    this.statsPath = workDir + '/core_stats.json';
    this.logPath = workDir + '/logs/lumine.log';
    this.coreLogPath = workDir + '/core.log';
    this.logOffset = 0;
    lumine.LumineSetWorkingDir(workDir);
    return lumine.LumineStart(tunFd, configName);
  }

  stop(): void {
    lumine.LumineStop();
  }

  isRunning(): boolean {
    return lumine.LumineIsRunning();
  }

  onNetworkChanged(): void {
    lumine.LumineOnNetworkChanged();
  }

  getVersion(): string {
    return lumine.LumineGetVersion();
  }

  checkConfig(): string {
    return lumine.LumineCheckConfig();
  }

  checkConfigJson(json: string): string {
    return lumine.LumineCheckConfigJson(json);
  }

  getLogs(maxChunks: number): string {
    return lumine.LumineGetLogs(maxChunks);
  }

  setLogFileEnabled(enabled: boolean): void {
    lumine.LumineSetLogFileEnabled(enabled);
  }

  logFilePath(): string {
    return lumine.LumineLogFilePath();
  }

  readCoreLog(): string {
    const path: string = this.coreLogPath;
    if (path.length === 0) {
      return '';
    }
    try {
      if (!fileIo.accessSync(path)) {
        return '';
      }
      const text: string = fileIo.readTextSync(path);
      if (text.length <= MAX_CORE_LOG_CHARS) {
        return text;
      }
      return text.substring(text.length - MAX_CORE_LOG_CHARS);
    } catch (err) {
      return '';
    }
  }

  readStats(): string {
    if (this.statsPath.length === 0) {
      return '';
    }
    try {
      if (!fileIo.accessSync(this.statsPath)) {
        return '';
      }
      return fileIo.readTextSync(this.statsPath);
    } catch (err) {
      return '';
    }
  }

  readNewLogs(): string {
    if (this.logPath.length === 0) {
      return '';
    }
    try {
      if (!fileIo.accessSync(this.logPath)) {
        return '';
      }
      const size: number = fileIo.statSync(this.logPath).size;
      if (size <= this.logOffset || size < 0) {
        this.logOffset = size > 0 ? size : 0;
        return '';
      }
      const pending: number = size - this.logOffset;
      const length: number = pending > MAX_LOG_CHUNK_BYTES ? MAX_LOG_CHUNK_BYTES : pending;
      const fd = fileIo.openSync(this.logPath, fileIo.OpenMode.READ_ONLY);
      try {
        const buf = new ArrayBuffer(length);
        const read: number = fileIo.readSync(fd.fd, buf, { offset: this.logOffset, length: length });
        if (read <= 0) {
          return '';
        }
        const bytes = new Uint8Array(buf, 0, read);
        let usable = read;
        if (this.logOffset + read < size) {
          let lastNewline = -1;
          for (let i = read - 1; i >= 0; i--) {
            if (bytes[i] === 0x0a) {
              lastNewline = i;
              break;
            }
          }
          usable = lastNewline >= 0 ? lastNewline + 1 : read;
        }
        this.logOffset += usable;
        const decoder = new util.TextDecoder('utf-8');
        return decoder.decodeToString(new Uint8Array(buf, 0, usable));
      } finally {
        fileIo.closeSync(fd);
      }
    } catch (err) {
      return '';
    }
  }
}
