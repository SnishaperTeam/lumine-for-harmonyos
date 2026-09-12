export const TUN_ADDRESS_V4: string = '172.19.0.1';
export const TUN_PREFIX_V4: number = 30;
export const TUN_ADDRESS_V6: string = 'fd66:6c75:6d69::1';
export const TUN_PREFIX_V6: number = 64;
export const TUN_MTU: number = 1500;
export const DNS_ADDRESS: string = '172.19.0.2';
export const BUNDLE_NAME: string = 'com.snishaper.lumine';
export const VPN_STATE_FILE: string = 'vpn_state.json';
export const RUNTIME_LOG_FILE: string = 'runtime.log';
export const MAX_LOG_ENTRIES: number = 500;
export const DEFAULT_CONFIG_NAME: string = 'config';
export const APP_NAME: string = 'Lumine';

export enum VpnStage {
  IDLE = 'idle',
  STARTING = 'starting',
  RUNNING = 'running',
  STOPPING = 'stopping',
  ERROR = 'error'
}

export const PRESET_APPS: string[] = [
  'com.tencent.mm',
  'com.tencent.mobileqq',
  'com.ss.android.ugc.aweme',
  'com.instagram.android',
  'com.twitter.android',
  'com.google.android.youtube',
  'com.zhiliaoapp.musically',
  'com.spotify.music',
  'com.discord',
  'org.telegram.messenger'
];
