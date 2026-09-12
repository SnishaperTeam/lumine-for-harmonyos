import { common, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { vpnExtension } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BUNDLE_NAME } from '../common/Constants';

const START_TIMEOUT_MS: number = 20000;

export class VpnController {
  private static instance: VpnController | null = null;

  static getInstance(): VpnController {
    if (!VpnController.instance) {
      VpnController.instance = new VpnController();
    }
    return VpnController.instance;
  }

  async startVpn(context: common.UIAbilityContext, configName: string): Promise<void> {
    const want: Want = {
      bundleName: BUNDLE_NAME,
      abilityName: 'LumineVpnExtAbility',
      parameters: { configName: configName }
    };
    await this.startExtensionWithTimeout(want);
  }

  async stopVpn(context: common.UIAbilityContext): Promise<void> {
    const want: Want = {
      bundleName: BUNDLE_NAME,
      abilityName: 'LumineVpnExtAbility'
    };
    try {
      await vpnExtension.stopVpnExtensionAbility(want);
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(0x0000, 'LumineUI',
        'stopVpnExtensionAbility rejected: code=%{public}d message=%{public}s', e.code, e.message);
      throw new Error(`stopVpnExtensionAbility failed: code=${e.code}, message=${e.message}`);
    }
  }

  private startExtensionWithTimeout(want: Want): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      let settled: boolean = false;
      const timer: number = setTimeout(() => {
        if (settled) {
          return;
        }
        settled = true;
        hilog.error(0x0000, 'LumineUI',
          'startVpnExtensionAbility no response within %{public}d ms', START_TIMEOUT_MS);
        reject(new Error(`系统 ${START_TIMEOUT_MS / 1000}s 内未响应 VPN 授权请求`));
      }, START_TIMEOUT_MS);

      vpnExtension.startVpnExtensionAbility(want).then(() => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        hilog.info(0x0000, 'LumineUI', 'startVpnExtensionAbility resolved');
        resolve();
      }).catch((err: BusinessError) => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        hilog.error(0x0000, 'LumineUI',
          'startVpnExtensionAbility rejected: code=%{public}d message=%{public}s', err.code, err.message);
        reject(new Error(`startVpnExtensionAbility failed: code=${err.code}, message=${err.message}`));
      });
    });
  }
}
