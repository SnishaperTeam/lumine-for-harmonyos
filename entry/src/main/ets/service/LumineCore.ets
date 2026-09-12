import lumine from 'liblumine_napi.so';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

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
      if (text.length <= 600) {
        return text;
      }
      return text.substring(text.length - 600);
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
      if (size <= this.logOffset) {
        this.logOffset = size;
        return '';
      }
      const length: number = size - this.logOffset;
      const fd = fileIo.openSync(this.logPath, fileIo.OpenMode.READ_ONLY);
      try {
        const buf = new ArrayBuffer(length);
        const read: number = fileIo.readSync(fd.fd, buf, { offset: this.logOffset, length: length });
        this.logOffset = size;
        const decoder = new util.TextDecoder('utf-8');
        return decoder.decodeToString(new Uint8Array(buf, 0, read));
      } finally {
        fileIo.closeSync(fd);
      }
    } catch (err) {
      return '';
    }
  }
}
