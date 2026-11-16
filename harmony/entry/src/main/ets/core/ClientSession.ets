import {
  decodePing,
  decodeSessionConfig,
  decodeVideo,
  encodeHello,
  encodePing,
  Frame,
  FrameDecoder,
  Hello,
  MessageType,
  SessionConfig,
  VideoFrame
} from './Protocol';
import {
  reduce,
  ReduceResult,
  SessionEvent,
  SessionEventKind,
  SessionEffectKind,
  SessionModel,
  SessionState
} from './SessionMachine';
import { Stats } from './Stats';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Transport } from '../transport/Transport';
import { TransportChoice } from '../transport/TransportSelector';
import { InputGate } from './InputGate';
import {
  CtrlCode,
  decodeCtrl,
  encodeCtrl,
  encodeKeyFrame,
  encodePointerFrame,
  encodeScrollFrame,
  encodeTextFrame,
  KeyInput,
  PointerSample,
  ScrollInput,
  TextInput
} from './InputProtocol';

const PING_INTERVAL_MS = 1000;
const LIVENESS_TIMEOUT_MS = 3000;
const WATCHDOG_INTERVAL_MS = 500;
const MAX_E2E_MS = 10000;

export type TransportFactory = (choice: TransportChoice) => Transport;

export class SessionListener {
  onState(model: SessionModel): void {
  }

  onConfig(config: SessionConfig): void {
  }

  onVideo(frame: VideoFrame): void {
  }

  onClosed(reason: string): void {
  }

  onInputGate(enabled: boolean, reason: string): void {
  }
}

export class ClientSession {
  private readonly choice: TransportChoice;
  private readonly factory: TransportFactory;
  private readonly hello: Hello;
  private readonly stats: Stats;
  private readonly listener: SessionListener;
  private readonly model: SessionModel = new SessionModel();
  private readonly gate: InputGate = new InputGate();

  private transport: Transport | null = null;
  private decoder: FrameDecoder = new FrameDecoder();
  private generation: number = 0;
  private connected: boolean = false;
  private stopped: boolean = false;
  private lastInboundMs: number = 0;
  private lastPingMs: number = 0;
  private pendingPingMicros: number = -1;
  private pendingPingAtMs: number = 0;
  private clockOffsetMicros: number = NaN;
  private pingTimer: number = -1;
  private watchdogTimer: number = -1;
  private retryTimer: number = -1;

  constructor(choice: TransportChoice, factory: TransportFactory, hello: Hello, stats: Stats,
    listener: SessionListener) {
    this.choice = choice;
    this.factory = factory;
    this.hello = hello;
    this.stats = stats;
    this.listener = listener;
  }

  getStats(): Stats {
    return this.stats;
  }

  getModel(): SessionModel {
    return this.model.copy();
  }

  start(): void {
    this.stopped = false;
    this.dispatch(new SessionEvent(SessionEventKind.CONNECT), () => {
    });
    this.dispatch(new SessionEvent(SessionEventKind.SELECT, '', this.choice.kind), () => {
      this.openTransport();
    });
  }

  stop(): void {
    this.stopped = true;
    this.releaseAll();
    this.clearTimers();
    this.dispatch(new SessionEvent(SessionEventKind.DISCONNECT), () => {
    });
    this.closeTransport();
  }

  requestKeyframe(): void {
    this.send(encodeCtrl(CtrlCode.REQUEST_KEYFRAME));
  }

  setInputEnabled(enabled: boolean): void {
    this.gate.setLocalEnabled(enabled);
    if (!enabled) {
      this.releaseAll();
    }
  }

  sendPointer(samples: PointerSample[]): void {
    if (!this.gate.allow()) {
      return;
    }
    try {
      this.send(encodePointerFrame(samples));
    } catch (err) {
      hilog.warn(0x0200, 'MirageSession', 'pointer encode failed: %{public}s', (err as Error).message);
    }
  }

  sendKey(key: KeyInput): void {
    if (!this.gate.allow()) {
      return;
    }
    this.send(encodeKeyFrame(key));
  }

  sendText(text: TextInput): void {
    if (!this.gate.allow()) {
      return;
    }
    try {
      this.send(encodeTextFrame(text));
    } catch (err) {
      hilog.warn(0x0200, 'MirageSession', 'text encode failed: %{public}s', (err as Error).message);
    }
  }

  sendScroll(scroll: ScrollInput): void {
    if (!this.gate.allow()) {
      return;
    }
    try {
      this.send(encodeScrollFrame(scroll));
    } catch (err) {
      hilog.warn(0x0200, 'MirageSession', 'scroll encode failed: %{public}s', (err as Error).message);
    }
  }

  releaseAll(): void {
    if (!this.gate.allowRelease()) {
      return;
    }
    this.send(encodeCtrl(CtrlCode.RELEASE_ALL));
  }

  private dispatch(event: SessionEvent, onOpen: () => void): void {
    const result: ReduceResult = reduce(this.model, event, Date.now());
    this.model.state = result.model.state;
    this.model.attempts = result.model.attempts;
    this.model.reconnectAtMs = result.model.reconnectAtMs;
    this.model.generation = result.model.generation;
    this.listener.onState(this.model.copy());
    for (const effect of result.effects) {
      if (effect === SessionEffectKind.OPEN_TRANSPORT) {
        onOpen();
      } else if (effect === SessionEffectKind.CLOSE_TRANSPORT) {
        this.closeTransport();
      } else if (effect === SessionEffectKind.REQUEST_KEYFRAME) {
        this.requestKeyframe();
      }
    }
  }

  private openTransport(): void {
    if (this.stopped) {
      return;
    }
    const transport = this.factory(this.choice);
    const generation = ++this.generation;
    this.transport = transport;
    this.decoder = new FrameDecoder();
    transport.onData((data: Uint8Array) => {
      this.onData(generation, data);
    });
    transport.onClosed((reason: string) => {
      this.onTransportClosed(generation, reason);
    });
    transport.open().then(() => {
      if (generation !== this.generation || this.stopped) {
        return;
      }
      this.connected = true;
      this.gate.setConnected(true);
      this.lastInboundMs = Date.now();
      const frame = encodeHello(this.hello);
      return transport.write(frame);
    }).then(() => {
      if (generation !== this.generation || this.stopped) {
        return;
      }
      this.startTimers();
    }).catch((err: Error) => {
      hilog.error(0x0200, 'MirageSession', 'open failed: %{public}s', err.message);
      this.onTransportClosed(generation, err.message.length > 0 ? err.message : '连接失败');
    });
  }

  private onData(generation: number, data: Uint8Array): void {
    if (generation !== this.generation || this.stopped) {
      return;
    }
    this.decoder.append(data);
    try {
      let frame: Frame | null = this.decoder.next();
      while (frame !== null) {
        this.lastInboundMs = Date.now();
        this.handleFrame(frame);
        frame = this.decoder.next();
      }
    } catch (err) {
      this.onTransportClosed(generation, (err as Error).message);
    }
  }

  private handleFrame(frame: Frame): void {
    if (frame.type === MessageType.SESSION_CONFIG) {
      const config = decodeSessionConfig(frame.payload);
      this.stats.setCodecLabel('HW');
      this.gate.reset();
      this.dispatch(new SessionEvent(SessionEventKind.CONFIG), () => {
      });
      this.listener.onConfig(config);
      this.listener.onInputGate(this.gate.getServerEnabled(), '');
    } else if (frame.type === MessageType.CTRL) {
      try {
        const ctrl = decodeCtrl(frame.payload);
        if (ctrl.code === CtrlCode.INPUT_ENABLED || ctrl.code === CtrlCode.INPUT_DISABLED) {
          this.gate.applyCtrl(ctrl.code, ctrl.reason);
          this.listener.onInputGate(this.gate.getServerEnabled(), ctrl.reason);
        }
      } catch (err) {
        hilog.warn(0x0200, 'MirageSession', 'ctrl decode failed: %{public}s', (err as Error).message);
      }
    } else if (frame.type === MessageType.VIDEO) {
      const video = decodeVideo(frame.payload);
      this.stats.onVideo(frame.payload.length);
      if (!Number.isNaN(this.clockOffsetMicros)) {
        const nowMicros = Date.now() * 1000;
        const e2eMicros = nowMicros - this.clockOffsetMicros - video.header.captureTsMicros;
        if (e2eMicros >= 0 && e2eMicros <= MAX_E2E_MS * 1000) {
          this.stats.setE2eMs(Math.floor(e2eMicros / 1000));
        }
      }
      this.listener.onVideo(video);
    } else if (frame.type === MessageType.PING) {
      this.handlePing(frame.payload);
    } else if (frame.type === MessageType.BYE) {
      this.onTransportClosed(this.generation, '服务端断开');
    }
  }

  private handlePing(payload: Uint8Array): void {
    const echoed = decodePing(payload);
    if (this.pendingPingMicros >= 0 && echoed === this.pendingPingMicros) {
      const nowMs = Date.now();
      const rttMicros = (nowMs - this.pendingPingAtMs) * 1000;
      this.stats.setRttMs(Math.floor(rttMicros / 1000));
      if (payload.length >= 16) {
        const view = new DataView(payload.buffer, payload.byteOffset, payload.length);
        const macMicros = view.getUint32(8) * 4294967296 + view.getUint32(12);
        this.clockOffsetMicros = nowMs * 1000 - Math.floor(rttMicros / 2) - macMicros;
      }
      this.pendingPingMicros = -1;
      return;
    }
    this.send(encodePing(echoed));
  }

  private onTransportClosed(generation: number, reason: string): void {
    if (generation !== this.generation || this.stopped) {
      return;
    }
    hilog.warn(0x0200, 'MirageSession', 'closed: %{public}s (gen %{public}d)', reason, generation);
    this.closeTransport();
    // 指纹不匹配是永久错误，重试没有意义，直接停到 Stopped 让 UI 提示
    if (reason.indexOf('证书指纹不匹配') >= 0) {
      this.dispatch(new SessionEvent(SessionEventKind.DISCONNECT), () => {
      });
      this.listener.onClosed(reason);
      return;
    }
    const wasStreaming = this.model.state === SessionState.Streaming ||
      this.model.state === SessionState.Connecting;
    this.dispatch(new SessionEvent(SessionEventKind.CLOSED, reason), () => {
    });
    if (this.model.state === SessionState.Recovering) {
      const delay = Math.max(this.model.reconnectAtMs - Date.now(), 0);
      this.retryTimer = setTimeout(() => {
        this.retryTimer = -1;
        if (this.stopped) {
          return;
        }
        this.dispatch(new SessionEvent(SessionEventKind.RETRY), () => {
          this.openTransport();
        });
      }, delay);
    } else if (this.model.state === SessionState.Stopped) {
      this.listener.onClosed(reason.length > 0 ? reason : (wasStreaming ? '连接已断开' : '连接失败'));
    }
  }

  private startTimers(): void {
    this.clearTimers();
    this.pingTimer = setInterval(() => {
      this.maybeSendPing();
    }, PING_INTERVAL_MS);
    this.watchdogTimer = setInterval(() => {
      if (this.connected && Date.now() - this.lastInboundMs > LIVENESS_TIMEOUT_MS) {
        this.onTransportClosed(this.generation, '连接无响应');
      }
    }, WATCHDOG_INTERVAL_MS);
  }

  private maybeSendPing(): void {
    const nowMs = Date.now();
    if (nowMs - this.lastPingMs < PING_INTERVAL_MS) {
      return;
    }
    this.lastPingMs = nowMs;
    const micros = nowMs * 1000;
    this.pendingPingMicros = micros;
    this.pendingPingAtMs = nowMs;
    this.send(encodePing(micros));
  }

  private send(frame: Uint8Array): void {
    const transport = this.transport;
    if (transport === null) {
      return;
    }
    transport.write(frame).catch((err: Error) => {
      if (!this.stopped) {
        this.onTransportClosed(this.generation, err.message);
      }
    });
  }

  private closeTransport(): void {
    this.clearTimers();
    this.connected = false;
    this.gate.setConnected(false);
    const transport = this.transport;
    this.transport = null;
    if (transport !== null) {
      transport.close().catch((err: Error) => {
      });
    }
  }

  private clearTimers(): void {
    if (this.pingTimer !== -1) {
      clearInterval(this.pingTimer);
      this.pingTimer = -1;
    }
    if (this.watchdogTimer !== -1) {
      clearInterval(this.watchdogTimer);
      this.watchdogTimer = -1;
    }
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
  }
}