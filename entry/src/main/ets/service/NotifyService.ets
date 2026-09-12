import { notificationManager } from '@kit.NotificationKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const RUNNING_NOTIFICATION_ID: number = 0x4C55;

export class NotifyService {
  private static shown: boolean = false;
  private static lastText: string = '';

  static update(ctx: common.UIAbilityContext, active: boolean, title: string, text: string): void {
    if (active) {
      if (NotifyService.shown && NotifyService.lastText === text) {
        return;
      }
      NotifyService.publishRunning(ctx, title, text);
      return;
    }
    if (NotifyService.shown) {
      NotifyService.cancelRunning();
    }
  }

  private static publishRunning(ctx: common.UIAbilityContext, title: string, text: string): void {
    notificationManager.requestEnableNotification(ctx).then(() => {
      NotifyService.doPublish(title, text);
    }).catch((_err: BusinessError) => {
      NotifyService.doPublish(title, text);
    });
  }

  private static doPublish(title: string, text: string): void {
    const request: notificationManager.NotificationRequest = {
      id: RUNNING_NOTIFICATION_ID,
      isOngoing: true,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: text
        }
      }
    };
    notificationManager.publish(request).then(() => {
      NotifyService.shown = true;
      NotifyService.lastText = text;
      hilog.info(0x0000, 'LumineUI', 'running notification published');
    }).catch((err: BusinessError) => {
      NotifyService.shown = true;
      NotifyService.lastText = text;
      hilog.error(0x0000, 'LumineUI', 'publish notification failed: %{public}d %{public}s',
        err.code, err.message);
    });
  }

  private static cancelRunning(): void {
    notificationManager.cancel(RUNNING_NOTIFICATION_ID).then(() => {
      NotifyService.shown = false;
      NotifyService.lastText = '';
      hilog.info(0x0000, 'LumineUI', 'running notification cancelled');
    }).catch((err: BusinessError) => {
      hilog.error(0x0000, 'LumineUI', 'cancel notification failed: %{public}d %{public}s',
        err.code, err.message);
      NotifyService.shown = false;
      NotifyService.lastText = '';
    });
  }
}
