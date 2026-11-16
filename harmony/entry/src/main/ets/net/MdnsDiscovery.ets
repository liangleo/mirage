import { mdns } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';

export interface DiscoveredMac {
  host: string;
  port: number;
  fingerprintHex: string;
  name: string;
}

export type DiscoveryDecision = 'auto' | 'needs-pairing';

export function decideDiscovery(advertisedFp: string, savedFp: string): DiscoveryDecision {
  const advertised = advertisedFp.trim().toLowerCase();
  const saved = savedFp.trim().toLowerCase();
  if (advertised.length !== 64 || saved.length !== 64) {
    return 'needs-pairing';
  }
  return advertised === saved ? 'auto' : 'needs-pairing';
}

export class MdnsDiscovery {
  private ctx: common.Context;
  private service: mdns.DiscoveryService | null = null;
  private found = false;

  constructor(ctx: common.Context) {
    this.ctx = ctx;
  }

  start(onFound: (mac: DiscoveredMac) => void, onError: (message: string) => void): void {
    this.found = false;
    const service = mdns.createDiscoveryService(this.ctx, '_mirage._tcp');
    service.on('discoveryStart', (info: mdns.DiscoveryEventInfo) => {
      // errorCode 是可选的，成功启动时不带该字段
      if (info.errorCode !== undefined && info.errorCode !== 0) {
        onError(`发现服务启动失败（${info.errorCode}）`);
      }
    });
    service.on('serviceFound', (info: mdns.LocalServiceInfo) => {
      if (this.found) {
        return;
      }
      mdns.resolveLocalService(this.ctx, info).then((resolved: mdns.LocalServiceInfo) => {
        const mac = this.toDiscovered(resolved);
        if (mac === null || this.found) {
          return;
        }
        this.found = true;
        this.stop();
        onFound(mac);
      }).catch((err: BusinessError) => {
        onError(`解析服务失败（${err.code}）`);
      });
    });
    service.startSearchingMDNS();
    this.service = service;
  }

  stop(): void {
    const service = this.service;
    this.service = null;
    if (service === null) {
      return;
    }
    service.stopSearchingMDNS();
    service.off('serviceFound');
    service.off('discoveryStart');
  }

  private toDiscovered(info: mdns.LocalServiceInfo): DiscoveredMac | null {
    const host = info.host === undefined ? '' : info.host.address;
    const port = info.port === undefined ? 0 : info.port;
    if (host.length === 0 || port <= 0) {
      return null;
    }
    let fingerprintHex = '';
    let name = info.serviceName === undefined ? host : info.serviceName;
    const attributes = info.serviceAttribute;
    if (attributes !== undefined) {
      const decoder = util.TextDecoder.create('utf-8');
      for (const attr of attributes) {
        const value = decoder.decodeToString(new Uint8Array(attr.value));
        if (attr.key === 'fp') {
          fingerprintHex = value.trim().toLowerCase();
        } else if (attr.key === 'name' && value.length > 0) {
          name = value;
        }
      }
    }
    return { host: host, port: port, fingerprintHex: fingerprintHex, name: name };
  }
}