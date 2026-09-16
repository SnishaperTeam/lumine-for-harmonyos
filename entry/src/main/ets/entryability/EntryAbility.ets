import { AbilityConstant, ConfigurationConstant, UIAbility, Want, errorManager } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import { window } from '@kit.ArkUI';

const DOMAIN = 0x0000;
const MAX_CRASH_FILES = 10;

export default class EntryAbility extends UIAbility {
  private crashObserver: ((reason: errorManager.GlobalError) => void) | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    this.registerCrashLogger();
  }

  private registerCrashLogger(): void {
    const cb = (reason: errorManager.GlobalError) => {
      this.writeCrashFile('crash', reason);
    };
    try {
      errorManager.on('globalErrorOccurred', cb);
      this.crashObserver = cb;
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'register crash observer failed: %{public}s', JSON.stringify(err));
    }
  }

  private writeCrashFile(kind: string, errObj: errorManager.GlobalError): void {
    try {
      const dir = this.context.filesDir + '/logs';
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
      const stamp = new Date().toISOString().replace(/[:.]/g, '-');
      const path = dir + '/' + kind + '_' + stamp + '.txt';
      const files = fileIo.listFileSync(dir)
        .filter((f: string) => f.startsWith(kind + '_') && f.endsWith('.txt'))
        .sort();
      const excess = files.length - (MAX_CRASH_FILES - 1);
      for (let i = 0; i < excess; i++) {
        try {
          fileIo.unlinkSync(dir + '/' + files[i]);
        } catch (e) {
        }
      }
      const body = 'Lumine Crash Report\nKind: ' + kind + '\nAt: ' + new Date().toISOString() +
        '\nName: ' + (errObj.name || '') + '\nMessage: ' + (errObj.message || '') +
        '\nStack:\n' + (errObj.stack || '') + '\n';
      const fd = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(fd.fd, body);
      fileIo.closeSync(fd);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'write crash file failed: %{public}s', JSON.stringify(err));
    }
  }

  onDestroy(): void {
    if (this.crashObserver) {
      try {
        errorManager.off('globalErrorOccurred', this.crashObserver);
      } catch (err) {
      }
      this.crashObserver = null;
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });

    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
