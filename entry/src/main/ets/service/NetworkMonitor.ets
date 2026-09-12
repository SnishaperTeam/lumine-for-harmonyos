import { connection } from '@kit.NetworkKit';

export class NetworkMonitor {
  private static instance: NetworkMonitor | null = null;
  private callback: (() => void) | null = null;
  private netConn: connection.NetConnection | null = null;

  static getInstance(): NetworkMonitor {
    if (!NetworkMonitor.instance) {
      NetworkMonitor.instance = new NetworkMonitor();
    }
    return NetworkMonitor.instance;
  }

  setCallback(cb: () => void): void {
    this.callback = cb;
  }

  start(): void {
    this.netConn = connection.createNetConnection();
    this.netConn.register(() => {
    });
    this.netConn.on('netAvailable', (data: connection.NetHandle) => {
      if (this.callback) this.callback();
    });
    this.netConn.on('netLost', (data: connection.NetHandle) => {
      if (this.callback) this.callback();
    });
    this.netConn.on('netCapabilitiesChange', (data: connection.NetCapabilityInfo) => {
      if (this.callback) this.callback();
    });
  }

  stop(): void {
    if (this.netConn) {
      this.netConn.unregister(() => {
      });
      this.netConn = null;
    }
  }
}
