import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { display } from '@kit.ArkUI';
import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { scanBarcode } from '@kit.ScanKit';
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
import {
  hasUsbAccessory,
  shouldWaitForUsb,
  SystemUsbPort,
  systemUsbBridge,
  UsbTransport
} from '../transport/UsbTransport';

const DOMAIN = 0x0200;
const TAG = 'MirageConnect';
const USB_WAIT_POLL_MS = 500;
const USB_WAIT_TIMEOUT_MS = 15000;

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
  private usbWaitTimer: number = -1;
  private usbWaitDeadlineMs: number = 0;
  private usbWanted: boolean = false;
  // 已配对/已手填的 Wi-Fi 地址；AUTO 切模式时用它恢复输入框
  private pairedHost: string = '';
  private pairedPort: number = 0;
  private autoDiscoveryTried: boolean = false;
  // AUTO 降级链：0=默认(USB 优先)，1=跳过 USB，2=只走 TCP
  private autoStage: number = 0;
  private lastKind: TransportKind | null = null;

  aboutToAppear(): void {
    this.init();
  }

  aboutToDisappear(): void {
    if (this.discovery !== null) {
      this.discovery.stop();
      this.discovery = null;
    }
    this.stopUsbWait();
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
      this.pairedHost = settings.host;
      this.pairedPort = settings.port;
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
    this.autoStage = 0;
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
    // AUTO 降级：USB 不通试 Wi-Fi，Wi-Fi 不通试 TCP；TCP 失败就停在连接页
    if (this.mode === TransportMode.AUTO && this.lastKind !== null &&
      this.lastKind !== TransportKind.TCP && this.autoStage < 2) {
      this.autoStage = this.lastKind === TransportKind.USB ? 1 : 2;
      this.usbWanted = false;
      this.stopUsbWait();
      hilog.info(DOMAIN, TAG, 'auto fallback stage %{public}d after: %{public}s',
        this.autoStage, reason);
      Runtime.onClosed(reason);
      // 串流页还在栈顶时，Runtime.onClosed 会把它弹回本页，而它的 aboutToDisappear
      // 会 stop 当前会话；等出栈落定再建新会话，否则新连接会被那一下 stop 掐掉
      setTimeout(() => {
        this.connect(true);
      }, 50);
      return;
    }
    if (this.usbWanted && shouldWaitForUsb(reason)) {
      this.startUsbWait();
    } else if (this.usbWanted && reason.indexOf('USB 权限') < 0 && reason.indexOf('USB 授权') < 0) {
      // Mac 侧退出后设备留在 AOA，重启 Mac App 也找不到它，只有拔插能恢复
      this.status = 'Mac 已断开，请拔插数据线后重连';
    }
    // 串流页在栈顶，由它弹回本页；这里只负责最终状态
    Runtime.onClosed(reason);
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
    this.pairedHost = payload.host;
    this.pairedPort = payload.port;
    this.status = `已导入 ${payload.name}`;
    const store = this.store;
    if (store !== null) {
      store.savePairing(payload.host, payload.port, payload.fingerprintHex).catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'save pairing failed: %{public}s', err.message);
      });
    }
  }

  // 系统扫码 UI 自带相机权限，不需要 App 声明 CAMERA
  private scanPairing(): void {
    const context = getContext(this) as common.UIAbilityContext;
    scanBarcode.startScanForResult(context).then((result: scanBarcode.ScanResult) => {
      this.pairingUrl = result.originalValue;
      this.applyPairing();
    }).catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'scan failed: %{public}s', err.message);
    });
  }

  private discover(auto: boolean = false): void {
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
        if (auto) {
          this.status = '未发现 Mac，改用 TCP 通道…';
          this.connect();
        } else {
          this.status = '未发现 Mac，可手动填写或扫码';
        }
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
        this.autoDiscoveryTried = false;
        this.status = `发现 ${mac.name}，需扫码确认指纹`;
      }
    }, (message: string) => {
      clearTimeout(timer);
      discovery.stop();
      this.discovery = null;
      this.status = message;
      if (auto) {
        this.connect();
      }
    });
  }

  private selectMode(mode: TransportMode): void {
    this.usbWanted = false;
    this.stopUsbWait();
    this.autoStage = 0;
    this.mode = mode;
    if (mode === TransportMode.WIFI) {
      this.portText = '7778';
    } else if (mode === TransportMode.TCP) {
      this.portText = '7777';
    } else if (mode === TransportMode.AUTO) {
      // AUTO 自己有判定顺序，别把已配对/已扫码的地址端口抹掉
      this.host = this.pairedHost;
      this.portText = this.pairedPort > 0 ? `${this.pairedPort}` : '';
    }
  }

  private connect(fromFallback: boolean = false): void {
    if (this.busy || this.discovery !== null) {
      return;
    }
    if (!fromFallback) {
      this.autoStage = 0;
    }
    this.stopUsbWait();
    const host = this.host.trim();
    const port = Number(this.portText.trim());
    const auto = this.mode === TransportMode.AUTO;
    let choice: TransportChoice | null;
    if (auto && this.autoStage >= 2) {
      choice = new TransportChoice(TransportKind.TCP, '127.0.0.1', 7777);
    } else {
      choice = selectTransport(
        this.mode,
        hasUsbAccessory(new SystemUsbPort()) && !(auto && this.autoStage >= 1),
        host,
        Number.isFinite(port) ? port : 0);
    }
    if (choice === null) {
      this.status = '请填写主机与端口';
      return;
    }
    // AUTO 且没有 USB 配件、也没有已配置地址时，先发现一次 Wi-Fi，找不到再回退 TCP
    if (auto && this.autoStage === 0 && choice.kind === TransportKind.TCP && !this.autoDiscoveryTried) {
      this.autoDiscoveryTried = true;
      this.discover(true);
      return;
    }
    this.autoDiscoveryTried = false;
    this.lastKind = choice.kind;
    if (choice.kind === TransportKind.WAIT_USB) {
      this.usbWanted = true;
      this.busy = false;
      this.status = '等待 USB 连接…';
      this.startUsbWait();
      return;
    }
    this.usbWanted = choice.kind === TransportKind.USB;
    this.busy = true;
    this.status = '连接中…';
    const fingerprint = this.fingerprint.trim().toLowerCase();
    const tls = choice.kind === TransportKind.WIFI && fingerprint.length === 64;
    Runtime.transportLabel = choice.kind === TransportKind.USB ? 'USB AOA' :
      (tls ? `Wi-Fi TLS ${choice.host}:${choice.port}` : `${choice.kind} ${choice.host}:${choice.port}`);
    Runtime.transportName = choice.kind === TransportKind.WIFI ? 'Wi-Fi' :
      (choice.kind === TransportKind.USB ? 'USB' : 'TCP');
    Runtime.stats = new Stats();

    const session = new ClientSession(choice, (selected: TransportChoice): Transport => {
      if (selected.kind === TransportKind.USB) {
        return new UsbTransport(new SystemUsbPort(), systemUsbBridge(), () => {
          this.status = '等待 USB 授权…';
        });
      }
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
    if (store !== null && choice.kind === TransportKind.WIFI) {
      this.pairedHost = host;
      this.pairedPort = choice.port;
      store.savePairing(host, choice.port, this.fingerprint).catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'save host failed: %{public}s', err.message);
      });
    }
    session.start();
  }

  private disconnect(): void {
    this.usbWanted = false;
    this.stopUsbWait();
    this.autoStage = 0;
    this.lastKind = null;
    const session = Runtime.session;
    if (session !== null) {
      session.stop();
    }
    Runtime.session = null;
    Runtime.hasConfig = false;
    this.busy = false;
    this.status = '已断开';
  }

  private startUsbWait(): void {
    if (this.usbWaitTimer !== -1) {
      return;
    }
    const now = Date.now();
    if (now >= this.usbWaitDeadlineMs) {
      this.usbWaitDeadlineMs = now + USB_WAIT_TIMEOUT_MS;
    }
    // 配件已经在（AOA 里主机没起来）时反复 open/close 会把 USB 服务拖死，界面跟着卡住；
    // 这种只有用户手动点连接靠谱。配件真的不在（等插线）才自动连。
    const autoConnect = !hasUsbAccessory(new SystemUsbPort());
    this.status = autoConnect ? '等待 USB 连接…' : '正在等待 USB 恢复…';
    this.usbWaitTimer = setInterval(() => {
      if (Date.now() > this.usbWaitDeadlineMs) {
        this.stopUsbWait();
        this.status = autoConnect ? '未检测到 USB 设备' : 'Mac 未响应，请确认 Mac 端 USB 已开启后重试';
        return;
      }
      if (!autoConnect || this.busy) {
        return;
      }
      const present = hasUsbAccessory(new SystemUsbPort());
      if (!present) {
        return;
      }
      this.stopUsbWait();
      this.connect();
    }, USB_WAIT_POLL_MS);
  }

  private stopUsbWait(): void {
    if (this.usbWaitTimer !== -1) {
      clearInterval(this.usbWaitTimer);
      this.usbWaitTimer = -1;
    }
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
          .enabled(!this.busy)
          .onClick(() => {
            this.scanPairing();
          })
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