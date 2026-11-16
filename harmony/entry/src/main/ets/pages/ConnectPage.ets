import { preferences } from '@kit.ArkData';
import { display } from '@kit.ArkUI';
import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ClientSession, SessionListener } from '../core/ClientSession';
import { Hello, SessionConfig, VideoFrame } from '../core/Protocol';
import { Runtime } from '../core/Runtime';
import { SessionModel, SessionState } from '../core/SessionMachine';
import { Stats } from '../core/Stats';
import { decideDiscovery, DiscoveredMac, MdnsDiscovery } from '../net/MdnsDiscovery';
import { PairingPayload, parsePairingUrl } from '../net/Pairing';
import { PreferencesKeyValueStore, Settings, SettingsStore, TransportMode } from '../settings/SettingsStore';
import { TcpTransport } from '../transport/TcpTransport';
import { TlsTransport } from '../transport/TlsTransport';
import { Transport } from '../transport/Transport';
import { selectTransport, TransportChoice, TransportKind } from '../transport/TransportSelector';

const DOMAIN = 0x0200;
const TAG = 'MirageConnect';

class UiListener extends SessionListener {
  private stateCb: (model: SessionModel) => void;
  private configCb: (config: SessionConfig) => void;
  private closedCb: (reason: string) => void;
  private gateCb: (enabled: boolean, reason: string) => void;

  constructor(stateCb: (model: SessionModel) => void, configCb: (config: SessionConfig) => void,
    closedCb: (reason: string) => void, gateCb: (enabled: boolean, reason: string) => void) {
    super();
    this.stateCb = stateCb;
    this.configCb = configCb;
    this.closedCb = closedCb;
    this.gateCb = gateCb;
  }

  onState(model: SessionModel): void {
    this.stateCb(model);
  }

  onConfig(config: SessionConfig): void {
    this.configCb(config);
  }

  onVideo(frame: VideoFrame): void {
    Runtime.onVideo(frame);
  }

  onClosed(reason: string): void {
    this.closedCb(reason);
  }

  onInputGate(enabled: boolean, reason: string): void {
    this.gateCb(enabled, reason);
  }
}

@Entry
@Component
struct ConnectPage {
  @State private host: string = '';
  @State private portText: string = '';
  @State private fingerprint: string = '';
  @State private mode: TransportMode = TransportMode.AUTO;
  @State private pairingUrl: string = '';
  @State private status: string = '未连接';
  @State private busy: boolean = false;
  private store: SettingsStore | null = null;
  private hello: Hello = new Hello();
  private pushed: boolean = false;
  private discovery: MdnsDiscovery | null = null;

  aboutToAppear(): void {
    this.init();
  }

  aboutToDisappear(): void {
    if (this.discovery !== null) {
      this.discovery.stop();
      this.discovery = null;
    }
  }

  onPageShow(): void {
    this.pushed = false;
    if (Runtime.session === null) {
      this.busy = false;
    }
  }

  private async init(): Promise<void> {
    try {
      const prefs = await preferences.getPreferences(getContext(this), 'mirage');
      const store = new SettingsStore(new PreferencesKeyValueStore(prefs));
      this.store = store;
      const settings: Settings = store.load();
      this.host = settings.host;
      this.portText = settings.port > 0 ? `${settings.port}` : '';
      this.fingerprint = settings.fingerprintHex;
      this.mode = settings.transportMode;
      const deviceId = await store.deviceId();
      this.hello.deviceID = deviceId;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'settings load failed: %{public}s', (err as Error).message);
    }
    try {
      const screen = display.getDefaultDisplaySync();
      this.hello.screenWidth = Math.min(screen.width, 65535);
      this.hello.screenHeight = Math.min(screen.height, 65535);
      this.hello.xdpi = Math.min(Math.round(screen.densityDPI), 65535);
      this.hello.ydpi = Math.min(Math.round(screen.densityDPI), 65535);
      this.hello.rotation = screen.rotation;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'display query failed: %{public}s', (err as Error).message);
    }
    this.hello.name = 'HarmonyOS';
    this.hello.features = 0x70;
    if (Runtime.session !== null) {
      this.status = this.describe(Runtime.state);
    }
  }

  private describe(state: SessionState): string {
    if (state === SessionState.Idle) {
      return '未连接';
    }
    if (state === SessionState.AwaitingUsbAuth) {
      return '等待 USB 授权…';
    }
    if (state === SessionState.Selecting) {
      return '正在选择通道…';
    }
    if (state === SessionState.Connecting) {
      return '连接中…';
    }
    if (state === SessionState.Streaming) {
      return '已连接';
    }
    if (state === SessionState.Recovering) {
      return '重连中…';
    }
    if (state === SessionState.Stopped) {
      return '已断开';
    }
    return state;
  }

  handleState(model: SessionModel): void {
    Runtime.state = model.state;
    this.status = this.describe(model.state);
    if (model.state === SessionState.Stopped || model.state === SessionState.Idle) {
      this.busy = false;
    }
  }

  handleConfig(config: SessionConfig): void {
    Runtime.config = config;
    Runtime.hasConfig = true;
    Runtime.stats.setCodecLabel('HW');
    Runtime.onConfig(config);
    if (!this.pushed) {
      this.pushed = true;
      router.pushUrl({ url: 'pages/StreamPage' }).catch((err: Error) => {
        hilog.error(DOMAIN, TAG, 'push StreamPage failed: %{public}s', err.message);
      });
    }
  }

  handleClosed(reason: string): void {
    Runtime.closedReason = reason;
    this.status = reason;
    this.busy = false;
  }

  private applyPairing(): void {
    const payload: PairingPayload | null = parsePairingUrl(this.pairingUrl);
    if (payload === null) {
      this.status = '配对链接无效';
      return;
    }
    this.host = payload.host;
    this.portText = `${payload.port}`;
    this.fingerprint = payload.fingerprintHex;
    this.status = `已导入 ${payload.name}`;
    const store = this.store;
    if (store !== null) {
      store.savePairing(payload.host, payload.port, payload.fingerprintHex).catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'save pairing failed: %{public}s', err.message);
      });
    }
  }

  private discover(): void {
    if (this.discovery !== null) {
      return;
    }
    this.status = '正在发现 Mac…';
    const discovery = new MdnsDiscovery(getContext(this));
    this.discovery = discovery;
    let timer = -1;
    timer = setTimeout(() => {
      if (this.discovery === discovery) {
        discovery.stop();
        this.discovery = null;
        this.status = '未发现 Mac，可手动填写或扫码';
      }
    }, 5000);
    discovery.start((mac: DiscoveredMac) => {
      clearTimeout(timer);
      this.discovery = null;
      this.host = mac.host;
      this.portText = `${mac.port}`;
      if (decideDiscovery(mac.fingerprintHex, this.fingerprint) === 'auto') {
        this.fingerprint = mac.fingerprintHex;
        this.status = `发现 ${mac.name}，自动连接…`;
        this.connect();
      } else {
        this.status = `发现 ${mac.name}，需扫码确认指纹`;
      }
    }, (message: string) => {
      clearTimeout(timer);
      discovery.stop();
      this.discovery = null;
      this.status = message;
    });
  }

  private selectMode(mode: TransportMode): void {
    this.mode = mode;
    if (mode === TransportMode.WIFI) {
      this.portText = '7778';
    } else if (mode === TransportMode.TCP) {
      this.portText = '7777';
    } else if (mode === TransportMode.AUTO) {
      this.portText = '';
    }
    const store = this.store;
    if (store !== null) {
      store.saveTransportMode(mode).catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'save mode failed: %{public}s', err.message);
      });
    }
  }

  private connect(): void {
    if (this.busy) {
      return;
    }
    const host = this.host.trim();
    const port = Number(this.portText.trim());
    const choice = selectTransport(this.mode, false, host, Number.isFinite(port) ? port : 0);
    if (choice === null) {
      this.status = '请填写主机与端口';
      return;
    }
    if (choice.kind === TransportKind.WAIT_USB) {
      this.status = '等待 USB 设备（H1 暂未接入）';
      return;
    }
    this.busy = true;
    this.status = '连接中…';
    const fingerprint = this.fingerprint.trim().toLowerCase();
    const tls = choice.kind === TransportKind.WIFI && fingerprint.length === 64;
    Runtime.transportLabel = tls ? `Wi-Fi TLS ${choice.host}:${choice.port}` :
      `${choice.kind} ${choice.host}:${choice.port}`;
    Runtime.transportName = choice.kind === TransportKind.WIFI ? 'Wi-Fi' :
      (choice.kind === TransportKind.USB ? 'USB' : 'TCP');
    Runtime.stats = new Stats();

    const session = new ClientSession(choice, (selected: TransportChoice): Transport => {
      if (selected.kind === TransportKind.WIFI && tls) {
        return new TlsTransport(selected.host, selected.port, fingerprint);
      }
      return new TcpTransport(selected.host, selected.port);
    }, this.hello, Runtime.stats, new UiListener(
      (model: SessionModel) => {
        this.handleState(model);
      },
      (config: SessionConfig) => {
        this.handleConfig(config);
      },
      (reason: string) => {
        this.handleClosed(reason);
      },
      (enabled: boolean, reason: string) => {
        Runtime.onInputGate(enabled, reason);
      }));
    Runtime.session = session;

    const store = this.store;
    if (store !== null) {
      store.savePairing(host, choice.port > 0 ? choice.port : 0, this.fingerprint).catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'save host failed: %{public}s', err.message);
      });
    }
    session.start();
  }

  private disconnect(): void {
    const session = Runtime.session;
    if (session !== null) {
      session.stop();
    }
    Runtime.session = null;
    Runtime.hasConfig = false;
    this.busy = false;
    this.status = '已断开';
  }

  build() {
    Column({ space: 14 }) {
      Text('Mirage').fontSize(28).fontWeight(FontWeight.Bold)
      Text(this.status).fontSize(16).fontColor('#888888')

      Row({ space: 10 }) {
        Text('主机').width(56).fontSize(14)
        TextInput({ text: this.host, placeholder: '192.168.1.10' })
          .layoutWeight(1)
          .onChange((value: string) => {
            this.host = value;
          })
        TextInput({ text: this.portText, placeholder: '7777' })
          .width(90)
          .type(InputType.Number)
          .onChange((value: string) => {
            this.portText = value;
          })
      }
      .width('100%')

      TextInput({ text: this.pairingUrl, placeholder: 'mirage://pair?…（可选）' })
        .width('100%')
        .onChange((value: string) => {
          this.pairingUrl = value;
        })

      Row({ space: 8 }) {
        Button('导入配对')
          .fontSize(14)
          .onClick(() => {
            this.applyPairing();
          })
        Button('AUTO')
          .fontSize(14)
          .backgroundColor(this.mode === TransportMode.AUTO ? '#4A6CF7' : '#333333')
          .onClick(() => {
            this.selectMode(TransportMode.AUTO);
          })
        Button('Wi-Fi')
          .fontSize(14)
          .backgroundColor(this.mode === TransportMode.WIFI ? '#4A6CF7' : '#333333')
          .onClick(() => {
            this.selectMode(TransportMode.WIFI);
          })
        Button('TCP')
          .fontSize(14)
          .backgroundColor(this.mode === TransportMode.TCP ? '#4A6CF7' : '#333333')
          .onClick(() => {
            this.selectMode(TransportMode.TCP);
          })
        Button('USB')
          .fontSize(14)
          .backgroundColor(this.mode === TransportMode.USB ? '#4A6CF7' : '#333333')
          .onClick(() => {
            this.selectMode(TransportMode.USB);
          })
        Button('发现 Mac')
          .fontSize(14)
          .onClick(() => {
            this.discover();
          })
        Button('扫码')
          .fontSize(14)
          .enabled(false)
      }

      Row({ space: 12 }) {
        Button('连接')
          .width(120)
          .enabled(!this.busy)
          .onClick(() => {
            this.connect();
          })
        Button('断开')
          .width(120)
          .backgroundColor('#444444')
          .onClick(() => {
            this.disconnect();
          })
      }

      Text(Runtime.transportLabel).fontSize(12).fontColor('#777777')
    }
    .width('100%')
    .height('100%')
    .padding(24)
    .justifyContent(FlexAlign.Center)
  }
}