import { TransportMode } from '../settings/SettingsStore';

export enum TransportKind {
  USB = 'USB',
  WIFI = 'WIFI',
  TCP = 'TCP',
  WAIT_USB = 'WAIT_USB'
}

export class TransportChoice {
  kind: TransportKind;
  host: string;
  port: number;

  constructor(kind: TransportKind, host: string, port: number) {
    this.kind = kind;
    this.host = host;
    this.port = port;
  }
}

const TCP_HOST = '127.0.0.1';
const TCP_PORT = 7777;

export function selectTransport(
  mode: TransportMode,
  hasAccessory: boolean,
  savedHost: string,
  savedPort: number): TransportChoice | null {
  const host = savedHost.trim();
  const hasWifi = host.length > 0 && savedPort >= 1 && savedPort <= 65535;

  if (mode === TransportMode.AUTO) {
    if (hasAccessory) {
      return new TransportChoice(TransportKind.USB, '', 0);
    }
    if (hasWifi) {
      return new TransportChoice(TransportKind.WIFI, host, savedPort);
    }
    return new TransportChoice(TransportKind.TCP, TCP_HOST, TCP_PORT);
  }
  if (mode === TransportMode.USB) {
    return hasAccessory
      ? new TransportChoice(TransportKind.USB, '', 0)
      : new TransportChoice(TransportKind.WAIT_USB, '', 0);
  }
  if (mode === TransportMode.WIFI) {
    return hasWifi ? new TransportChoice(TransportKind.WIFI, host, savedPort) : null;
  }
  return new TransportChoice(TransportKind.TCP, TCP_HOST, TCP_PORT);
}