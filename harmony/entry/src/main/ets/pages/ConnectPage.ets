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
const RECONNECT_WINDOW_MS = 300000;
const AUTO_RETRY_MS = 5000;
const USB_WATCH_POLL_MS = 3000;

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
  // AUTO 走 Wi-Fi/TCP 时盯住配件：插回数据线就切回 USB
  private usbWatchTimer: number = -1;
  // 连续切 USB 失败三次就停手，避免 Wi-Fi/USB 反复抖动
  private usbSwitchFailures: number = 0;
  // 本轮降级链的起点是否是拔线；降级全部失败后用它决定等待文案
  private usbDropped: boolean = false;
  // 等待重连遮罩的截止时刻；0 表示本轮尚未进入等待
  private waitDeadlineMs: number = 0;
  // AUTO 降级全部失败后，每隔几秒重试 Wi-Fi/TCP，等 Mac 服务重新启动
  private retryTimer: number = -1;
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
    this.stopRetry();
    this.stopUsbWatch();
  }

  onPageShow(): void {
    this.pushed = false;
    if (Runtime.session === null) {
      // 用户手动断开或等待超时后退回：停止所有自动重连
      this.busy = false;
      this.stopRetry();
      this.stopUsbWait();
      this.stopUsbWatch();
      this.usbWanted = false;
      this.waitDeadlineMs = 0;
    }
  }

  private async init(): Promise<void> {
    try {
      const prefs = await preferences.getPreferences(getContext(this), 'mirage');
      const store = new SettingsStore(new PreferencesKeyValueStore(prefs));
      this.store = store;
      Runtime.store = store;
      const settings: Settings = store.load();
      Runtime.debugOn = settings.debugOn;
      Runtime.inputOn = settings.inputOn;
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
    if (model.state === SessionState.Recovering && this.pushed) {
      this.notifyWaiting('连接中断，正在重连…');
    }
    // 串流页退栈时会对旧会话 stop()，那次 Stopped 会晚于 handleClosed 到达；
    // 等待重连期间不能被它把提示文案冲成「已断开」
    if (model.state === SessionState.Stopped &&
      (this.usbWaitTimer !== -1 || this.retryTimer !== -1)) {
      hilog.warn(DOMAIN, TAG, 'stopped after close; keeping wait status');
    } else {
      this.status = this.describe(model.state);
    }
    if (model.state === SessionState.Stopped || model.state === SessionState.Idle) {
      this.busy = false;
    }
  }

  handleConfig(config: SessionConfig): void {
    Runtime.config = config;
    this.busy = false;
    this.autoStage = 0;
    this.usbSwitchFailures = 0;
    this.waitDeadlineMs = 0;
    this.stopRetry();
    if (this.mode === TransportMode.AUTO &&
      (this.lastKind === TransportKind.WIFI || this.lastKind === TransportKind.TCP)) {
      this.startUsbWatch();
    } else {
      this.stopUsbWatch();
    }
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
    hilog.info(DOMAIN, TAG, 'closed: %{public}s mode=%{public}d usbWanted=%{public}s waiting=%{public}s',
      reason, this.mode, `${this.usbWanted}`, `${this.usbWaitTimer !== -1}`);
    this.status = reason;
    this.busy = false;
    this.stopUsbWatch();
    // 指纹错误是永久错误：重连只会重复失败
    if (reason.indexOf('证书指纹不匹配') >= 0) {
      this.stopRetry();
      this.stopUsbWait();
      this.usbWanted = false;
      Runtime.onClosed(reason);
      return;
    }
    // AUTO 降级：USB 不通试 Wi-Fi，Wi-Fi 不通试 TCP
    if (this.mode === TransportMode.AUTO && this.lastKind !== null &&
      this.lastKind !== TransportKind.TCP && this.autoStage < 2) {
      this.autoStage = this.lastKind === TransportKind.USB ? 1 : 2;
      this.usbDropped = shouldWaitForUsb(reason);
      this.usbWanted = false;
      this.stopUsbWait();
      hilog.info(DOMAIN, TAG, 'auto fallback stage %{public}d after: %{public}s',
        this.autoStage, reason);
      this.notifyWaiting((this.usbDropped ? 'USB 已断开，' : '连接中断，') +
        (this.autoStage === 1 ? '正在尝试 Wi-Fi…' : '正在尝试 TCP…'));
      // 串流页会保持显示（遮罩），这里只建新会话；等它出配置后页面自己清遮罩
      setTimeout(() => {
        this.connect(true);
      }, 50);
      return;
    }
    // AUTO 的通道都试完了：回到等待 USB 重插 + 周期重试
    if (this.mode === TransportMode.AUTO) {
      const cable = this.usbDropped || shouldWaitForUsb(reason);
      this.usbWanted = true;
      this.autoStage = 0;
      this.usbDropped = false;
      hilog.info(DOMAIN, TAG, 'auto exhausted; waiting for USB after: %{public}s', reason);
      this.startUsbWait(cable ? 'USB 已断开，请重新插入' : '');
      this.notifyWaiting(cable ? 'USB 已断开，等待重新插入…' : '连接中断，等待 USB 重连…');
      this.startRetry();
      return;
    }
    // USB 模式：拔线与主机失联都走同一套等待 + 周期重试
    if (this.usbWanted && shouldWaitForUsb(reason)) {
      const message = reason === 'USB 已断开' ? 'USB 已断开，请重新插入' : '';
      this.startUsbWait(message);
      this.notifyWaiting(message.length > 0 ? 'USB 已断开，等待重新插入…' : '正在等待 USB 重连…');
      this.startRetry();
      return;
    }
    if (this.usbWanted && reason.indexOf('USB 权限') < 0 && reason.indexOf('USB 授权') < 0) {
      // Mac 侧退出（连接无响应等）：周期重试，服务恢复后自动连回
      this.notifyWaiting('Mac 已断开，正在重连…');
      this.startRetry();
      return;
    }
    // Wi-Fi / TCP 模式
    if (this.mode === TransportMode.WIFI || this.mode === TransportMode.TCP) {
      this.notifyWaiting(this.mode === TransportMode.WIFI ? 'Wi-Fi 已断开，正在重连…' : '连接已断开，正在重连…');
      this.startRetry();
      return;
    }
    // 串流页在栈顶，由它弹回本页；这里只负责最终状态
    Runtime.onClosed(reason);
  }

  private startRetry(): void {
    if (this.retryTimer !== -1) {
      return;
    }
    if (this.waitDeadlineMs === 0) {
      this.waitDeadlineMs = Date.now() + RECONNECT_WINDOW_MS;
    }
    this.retryTimer = setTimeout(() => {
      this.retryTimer = -1;
      if (Date.now() > this.waitDeadlineMs) {
        return;
      }
      if (this.busy) {
        this.startRetry();
        return;
      }
      // AUTO 下重试从 USB 优先开始：数据线可用时切回低延迟通道
      this.connect(true);
    }, AUTO_RETRY_MS);
  }

  private stopRetry(): void {
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
  }

  // AUTO 走 Wi-Fi/TCP 时盯住配件；配件在就切回 USB（AOA 模式下配件可能一直存在，
// 不能只等「消失再出现」）
  private startUsbWatch(): void {
    if (this.usbWatchTimer !== -1 || this.mode !== TransportMode.AUTO) {
      return;
    }
    this.usbWatchTimer = setInterval(() => {
      if (this.mode !== TransportMode.AUTO || this.busy) {
        return;
      }
      if (!hasUsbAccessory(new SystemUsbPort())) {
        this.usbSwitchFailures = 0;
        return;
      }
      if (this.usbSwitchFailures >= 3) {
        return;
      }
      this.switchToUsb();
    }, USB_WATCH_POLL_MS);
  }

  private stopUsbWatch(): void {
    if (this.usbWatchTimer !== -1) {
      clearInterval(this.usbWatchTimer);
      this.usbWatchTimer = -1;
    }
  }

  private switchToUsb(): void {
    this.stopUsbWatch();
    this.usbSwitchFailures += 1;
    hilog.info(DOMAIN, TAG, 'accessory available; switching to USB');
    this.notifyWaiting('已插回 USB，正在切换…');
    const session = Runtime.session;
    if (session !== null) {
      session.stop();
    }
    Runtime.session = null;
    this.autoStage = 0;
    this.usbDropped = false;
    // 等服务端彻底释放旧连接（helper 只接受一个客户端）再开新会话
    setTimeout(() => {
      this.connect();
    }, 300);
  }

  private notifyWaiting(message: string): void {
    // 不在播放页就没有遮罩可显示，状态文案已经在连接页上
    if (!this.pushed) {
      return;
    }
    if (this.waitDeadlineMs === 0) {
      this.waitDeadlineMs = Date.now() + RECONNECT_WINDOW_MS;
    }
    Runtime.onWaiting(message, this.waitDeadlineMs);
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
    this.usbDropped = false;
    this.waitDeadlineMs = 0;
    this.stopRetry();
    this.stopUsbWait();
    this.stopUsbWatch();
    this.autoStage = 0;
    this.mode = mode;
    const store = this.store;
    if (store !== null) {
      store.saveMode(mode).catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'save mode failed: %{public}s', err.message);
      });
    }
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
      this.usbDropped = false;
      this.stopRetry();
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
    if (auto && this.autoStage === 0 && choice.kind === TransportKind.TCP &&
      !this.autoDiscoveryTried && !fromFallback) {
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
    if (store !== null && !fromFallback && host.length > 0 && Number.isFinite(port) && port > 0) {
      store.saveAddress(host, port).catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'save address failed: %{public}s', err.message);
      });
    }
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
    this.usbDropped = false;
    this.waitDeadlineMs = 0;
    this.stopRetry();
    this.stopUsbWait();
    this.stopUsbWatch();
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

  private startUsbWait(message: string = ''): void {
    if (this.usbWaitTimer !== -1) {
      return;
    }
    const now = Date.now();
    if (now >= this.usbWaitDeadlineMs) {
      this.usbWaitDeadlineMs = now + RECONNECT_WINDOW_MS;
    }
    // 配件一直在（AOA 里主机没起来）时反复 open/close 会把 USB 服务拖死，界面跟着卡住；
    // 这种只有用户手动点连接靠谱。必须看到配件先消失再出现，才认为是一次重新插线。
    let sawAbsent = !hasUsbAccessory(new SystemUsbPort());
    hilog.info(DOMAIN, TAG, 'usb wait armed: absent=%{public}s message=%{public}s',
      `${sawAbsent}`, message);
    this.status = sawAbsent
      ? (message.length > 0 ? message : '等待 USB 连接…')
      : '正在等待 USB 恢复…';
    this.usbWaitTimer = setInterval(() => {
      if (Date.now() > this.usbWaitDeadlineMs) {
        this.stopUsbWait();
        this.status = sawAbsent ? '未检测到 USB 设备' : 'Mac 未响应，请确认 Mac 端 USB 已开启后重试';
        return;
      }
      if (this.busy) {
        return;
      }
      const present = hasUsbAccessory(new SystemUsbPort());
      if (!present) {
        if (!sawAbsent) {
          sawAbsent = true;
          hilog.info(DOMAIN, TAG, 'usb absent; watching for replug');
        }
        return;
      }
      if (!sawAbsent) {
        return;
      }
      hilog.info(DOMAIN, TAG, 'usb present after replug; reconnecting');
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