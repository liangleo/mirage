import { display, router } from '@kit.ArkUI';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { closeDecoder, DecoderEvent, onEvent, openDecoder, submitVideo } from 'libmirage.so';
import { Runtime } from '../core/Runtime';
import { ClientSession } from '../core/ClientSession';
import { KeyAction, KeyInput, TextInput as TextInputMessage } from '../core/InputProtocol';
import { SessionConfig, VideoFrame } from '../core/Protocol';
import { GestureEvent } from '../input/GestureMapper';
import { ContentRect } from '../input/InputGeometry';
import { androidKeycode, ModifierTracker, unicodeFor } from '../input/KeyMapping';
import { InputOverlay } from '../ui/InputOverlay';
import { KeyboardDock } from '../ui/KeyboardDock';
import { VideoSurface } from '../ui/VideoSurface';
import { StatsOverlay } from '../ui/StatsOverlay';

const DOMAIN = 0x0100;
const TAG = 'MirageStream';
const DECODER_OPEN_TIMEOUT_MS = 3000;
const DIAG_TIMEOUT_MS = 3000;

@Entry
@Component
struct StreamPage {
  @State private configWidth: number = Runtime.hasConfig ? Runtime.config.width : 16;
  @State private configHeight: number = Runtime.hasConfig ? Runtime.config.height : 9;
  @State private statusText: string = Runtime.hasConfig ? '' : '等待视频配置';
  @State private contentW: number = 0;
  @State private contentH: number = 0;
  @State private keyboardOn: boolean = false;
  @State private confirmDisconnect: boolean = false;
  @State private toolbarOpen: boolean = false;
  @State private debugOn: boolean = Runtime.debugOn;
  @State private inputOn: boolean = Runtime.inputOn;
  @State private capsOk: boolean = true;
  @State private gateEnabled: boolean = true;
  @State private gateReason: string = '';
  private surfaceId: string = '';
  private decoderOpen: boolean = false;
  private decoderPending: boolean = false;
  private decoderToken: number = 0;
  private openTimer: number = -1;
  private diagTimer: number = -1;
  private rxFrames: number = 0;
  private decodedFrames: number = 0;
  private tracker: ModifierTracker = new ModifierTracker();
  // 本页开始时的那条会话；退栈时只停它，不能误停 AUTO 降级新建的会话
  private ownedSession: ClientSession | null = null;
  // 降级重连可能在本页退栈前再次失败，防止连续 router.back() 多弹一层
  private closing: boolean = false;
  @State private waiting: boolean = false;
  @State private waitingText: string = '';
  @State private remainSec: number = 0;
  private waitDeadlineMs: number = 0;
  private waitTimer: number = -1;
  private confirmTimer: number = -1;
  private sizeListener: ((size: window.Size) => void) | null = null;
  private streamWindow: window.Window | null = null;

  aboutToAppear(): void {
    this.ownedSession = Runtime.session;
    this.applyWindow(true);
    // 旋转检测：display.on('change') 在真机上不回调，用窗口尺寸变化
    this.sizeListener = (size: window.Size): void => {
      const session = Runtime.session;
      if (session === null) {
        return;
      }
      try {
        const d = display.getDefaultDisplaySync();
        hilog.info(DOMAIN, TAG, 'window size %{public}dx%{public}d display %{public}dx%{public}d rot=%{public}d',
          size.width, size.height, d.width, d.height, d.rotation);
        session.updateScreen(d.width, d.height, d.rotation);
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'display query failed: %{public}s', (err as Error).message);
      }
    };
    const host = this.getUIContext().getHostContext();
    if (host !== null) {
      window.getLastWindow(host).then((win: window.Window) => {
        this.streamWindow = win;
        if (this.sizeListener !== null) {
          win.on('windowSizeChange', this.sizeListener);
        }
      }).catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'window listener failed: %{public}s', err.message);
      });
    }
    onEvent((event: DecoderEvent) => {
      if (event.kind === 'frame') {
        this.decodedFrames += 1;
        Runtime.stats.setDecodeMs(event.decodeMs);
      } else if (event.kind === 'dropped') {
        Runtime.stats.onDropped();
      } else if (event.kind === 'decoderError') {
        hilog.error(DOMAIN, TAG, 'decoder error: %{public}s', event.reason);
      }
    });
    Runtime.onConfig = (config: SessionConfig) => {
      Runtime.config = config;
      Runtime.hasConfig = true;
      this.ownedSession = Runtime.session;
      this.clearWait();
      // 旋转后服务端按新尺寸重建，解码器必须跟着重开
      const resized = this.decoderOpen &&
        (config.width !== this.configWidth || config.height !== this.configHeight);
      this.configWidth = config.width;
      this.configHeight = config.height;
      this.statusText = '';
      if (resized) {
        this.stopDecoder();
      }
      this.applyInputCaps();
      this.startDecoder();
    };
    Runtime.onVideo = (frame: VideoFrame) => {
      this.submitFrame(frame);
    };
    Runtime.onInputGate = (enabled: boolean, reason: string) => {
      this.gateEnabled = enabled;
      this.gateReason = reason;
      this.syncInput();
    };
    // 短暂断线时留在本页等重连，用遮罩 + 倒计时提示；到期才退回连接页
    Runtime.onWaiting = (message: string, deadlineMs: number) => {
      this.waitingText = message;
      this.waitDeadlineMs = deadlineMs;
      this.waiting = true;
      this.tickWait();
      if (this.waitTimer === -1) {
        this.waitTimer = setInterval(() => {
          this.tickWait();
        }, 500);
      }
    };
    // 会话彻底结束（重试耗尽或 Mac 侧关闭）后不能停在冻结的画面，退回连接页等待
    Runtime.onClosed = (reason: string) => {
      hilog.info(DOMAIN, TAG, 'session closed: %{public}s; back to connect', reason);
      if (this.closing) {
        return;
      }
      this.closing = true;
      router.back();
    };
    if (Runtime.hasConfig) {
      this.configWidth = Runtime.config.width;
      this.configHeight = Runtime.config.height;
      this.applyInputCaps();
      this.startDecoder();
    }
  }

  aboutToDisappear(): void {
    if (this.streamWindow !== null && this.sizeListener !== null) {
      try {
        this.streamWindow.off('windowSizeChange', this.sizeListener);
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'window off failed: %{public}s', (err as Error).message);
      }
    }
    this.sizeListener = null;
    this.streamWindow = null;
    this.applyWindow(false);
    Runtime.onVideo = (frame: VideoFrame) => {
    };
    Runtime.onConfig = (config: SessionConfig) => {
    };
    Runtime.onInputGate = (enabled: boolean, reason: string) => {
    };
    Runtime.onClosed = (reason: string) => {
    };
    Runtime.onWaiting = (message: string, deadlineMs: number) => {
    };
    this.clearWait();
    if (this.confirmTimer !== -1) {
      clearTimeout(this.confirmTimer);
      this.confirmTimer = -1;
    }
    this.stopDecoder();
    const session = this.ownedSession;
    this.ownedSession = null;
    if (session !== null) {
      session.releaseAll();
      session.stop();
    }
    // 退栈回调可能比降级重连晚几百毫秒；此时 Runtime.session 已是新会话，不能清
    if (Runtime.session === session) {
      Runtime.session = null;
      Runtime.hasConfig = false;
    }
  }

  onPageHide(): void {
    const session = Runtime.session;
    if (session !== null) {
      session.releaseAll();
    }
    this.tracker.reset();
  }

  private applyWindow(streaming: boolean): void {
    const context = this.getUIContext().getHostContext();
    if (context === null) {
      return;
    }
    window.getLastWindow(context).then((win: window.Window) => {
      win.setWindowLayoutFullScreen(streaming);
      win.setWindowKeepScreenOn(streaming);
    }).catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'window setup failed: %{public}s', err.message);
    });
  }

  private startDecoder(): void {
    if (this.decoderOpen || this.decoderPending || this.surfaceId.length === 0 || !Runtime.hasConfig) {
      return;
    }
    const config = Runtime.config;
    const token = ++this.decoderToken;
    this.decoderPending = true;
    // 打开在 codec 工作线程上执行；一直不回调说明那条线程卡住了，别让用户面对纯黑屏
    this.openTimer = setTimeout(() => {
      this.openTimer = -1;
      if (token === this.decoderToken && this.decoderPending) {
        this.statusText = '解码器启动超时，请断开重连';
      }
    }, DECODER_OPEN_TIMEOUT_MS);
    openDecoder(config.width, config.height, config.fps > 0 ? config.fps : 60, this.surfaceId,
      (opened: boolean) => {
        if (token !== this.decoderToken) {
          return;
        }
        this.clearOpenTimer();
        this.decoderPending = false;
        if (!opened) {
          hilog.error(DOMAIN, TAG, 'decoder open failed');
          return;
        }
        this.decoderOpen = true;
        hilog.info(DOMAIN, TAG, 'decoder opened %{public}dx%{public}d surface=%{public}s',
          config.width, config.height, this.surfaceId);
        this.startDiagWatch();
        const session = Runtime.session;
        if (session !== null) {
          session.requestKeyframe();
        }
      });
  }

  private stopDecoder(): void {
    this.clearOpenTimer();
    this.stopDiagWatch();
    if (!this.decoderOpen && !this.decoderPending) {
      return;
    }
    this.decoderOpen = false;
    this.decoderPending = false;
    this.decoderToken++;
    closeDecoder();
    hilog.info(DOMAIN, TAG, 'decoder closed');
  }

  private clearOpenTimer(): void {
    if (this.openTimer !== -1) {
      clearTimeout(this.openTimer);
      this.openTimer = -1;
    }
  }

  // 黑屏时唯一能自证的信息：帧到底有没有到、解码器有没有出图
  private startDiagWatch(): void {
    if (this.diagTimer !== -1) {
      return;
    }
    this.rxFrames = 0;
    this.decodedFrames = 0;
    this.diagTimer = setInterval(() => {
      if (this.decodedFrames > 0) {
        this.stopDiagWatch();
        this.statusText = '';
        return;
      }
      if (this.rxFrames > 0) {
        // Frames flow but nothing comes out: ask for an IDR instead of sitting
        // on a black screen — a decoder that started mid-stream may have missed
        // the parameter sets.
        this.statusText = `无画面：收到 ${this.rxFrames} 帧，解码 0 帧`;
        const session = Runtime.session;
        if (session !== null) {
          session.requestKeyframe();
        }
      } else {
        this.statusText = '无画面：未收到视频帧';
      }
    }, DIAG_TIMEOUT_MS);
  }

  private stopDiagWatch(): void {
    if (this.diagTimer !== -1) {
      clearInterval(this.diagTimer);
      this.diagTimer = -1;
    }
  }

  private submitFrame(frame: VideoFrame): void {
    this.rxFrames += 1;
    if (!this.decoderOpen) {
      return;
    }
    const data = frame.annexB;
    const buffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
    const rc = submitVideo(buffer, frame.header.flags, frame.header.frameId, frame.header.captureTsMicros);
    if (rc < 0) {
      hilog.warn(DOMAIN, TAG, 'submit rejected %{public}d', rc);
    }
  }

  private inputActive(): boolean {
    return this.inputOn && this.capsOk && this.gateEnabled;
  }

  private applyInputCaps(): void {
    this.capsOk = (Runtime.config.inputCaps & 0x01) !== 0;
    this.syncInput();
  }

  private syncInput(): void {
    const session = Runtime.session;
    if (session !== null) {
      session.setInputEnabled(this.inputActive());
      session.setKeyboardEnabled(this.keyboardReady());
    }
  }

  private saveUi(): void {
    Runtime.debugOn = this.debugOn;
    Runtime.inputOn = this.inputOn;
    const store = Runtime.store;
    if (store !== null) {
      store.saveUi(this.debugOn, this.inputOn).catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'save ui settings failed: %{public}s', err.message);
      });
    }
  }

  private keyboardReady(): boolean {
    return (Runtime.config.inputCaps & 0x06) !== 0 && this.gateEnabled;
  }

  private inputReady(): boolean {
    return this.capsOk && this.gateEnabled;
  }

  
  // 白 = 已开启，灰 = 未开启/不可用；断开用 normal→danger 表示警告
  private inputGlyph(): Resource {
    return this.inputOn && this.inputReady() ? $r('app.media.ic_input_active') :
      $r('app.media.ic_input_disabled');
  }

  private keyboardGlyph(): Resource {
    return this.keyboardOn && this.capsOk ? $r('app.media.ic_keyboard_active') :
      $r('app.media.ic_keyboard_disabled');
  }

  private debugGlyph(): Resource {
    return this.debugOn ? $r('app.media.ic_debug_active') : $r('app.media.ic_debug_disabled');
  }

  private disconnectGlyph(): Resource {
    return this.confirmDisconnect ? $r('app.media.ic_disconnect_active') :
      $r('app.media.ic_disconnect_disabled');
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'toast failed: %{public}s', (err as Error).message);
    }
  }

  private toggleInput(): void {
    if (!this.capsOk) {
      this.toast('服务端未开放输入');
      return;
    }
    if (!this.gateEnabled) {
      this.toast(this.gateReason.length > 0 ? this.gateReason : '输入已暂停');
      return;
    }
    this.inputOn = !this.inputOn;
    this.syncInput();
    this.saveUi();
    this.toast(this.inputOn ? '触控已开启' : '触控已关闭');
  }

  private toggleKeyboard(): void {
    const on = !this.keyboardOn;
    this.setKeyboard(on);
    this.toast(on ? '键盘已打开' : '键盘已关闭');
  }

  private toggleDebug(): void {
    this.debugOn = !this.debugOn;
    this.saveUi();
    this.toast(this.debugOn ? '调试信息已开启' : '调试信息已关闭');
  }

  // 断开是破坏性操作：第一次点变红，3 秒内再点才真正断开
  private requestDisconnect(): void {
    if (!this.confirmDisconnect) {
      this.confirmDisconnect = true;
      this.confirmTimer = setTimeout(() => {
        this.confirmTimer = -1;
        this.confirmDisconnect = false;
      }, 3000);
      this.toast('再点一次断开连接');
      return;
    }
    if (this.confirmTimer !== -1) {
      clearTimeout(this.confirmTimer);
      this.confirmTimer = -1;
    }
    this.confirmDisconnect = false;
    this.disconnect();
  }

  private disconnect(): void {
    const session = Runtime.session;
    if (session !== null) {
      session.releaseAll();
      session.stop();
    }
    Runtime.session = null;
    router.back();
  }

  private tickWait(): void {
    const left = Math.max(0, Math.ceil((this.waitDeadlineMs - Date.now()) / 1000));
    this.remainSec = left;
    if (left > 0) {
      return;
    }
    this.clearWait();
    if (!this.closing) {
      this.closing = true;
      router.back();
    }
  }

  private clearWait(): void {
    this.waiting = false;
    if (this.waitTimer !== -1) {
      clearInterval(this.waitTimer);
      this.waitTimer = -1;
    }
  }

  private setKeyboard(on: boolean): void {
    this.keyboardOn = on;
    if (on) {
      setTimeout(() => {
        try {
          this.getUIContext().getFocusController().requestFocus('mirageKb');
        } catch (err) {
          hilog.warn(DOMAIN, TAG, 'keyboard focus failed: %{public}s', (err as Error).message);
        }
      }, 100);
      return;
    }
    this.getUIContext().getFocusController().clearFocus();
    this.tracker.reset();
    const session = Runtime.session;
    if (session !== null) {
      session.releaseAll();
    }
  }

  private onHardwareKey(event: KeyEvent): void {
    if (event.type !== KeyType.Down && event.type !== KeyType.Up) {
      return;
    }
    const harmonyCode = event.keyCode;
    if (harmonyCode === 2 || harmonyCode === 16 || harmonyCode === 17 || harmonyCode === 23) {
      return;
    }
    const down = event.type === KeyType.Down;
    const modifiers = this.tracker.update(harmonyCode, down);
    const code = androidKeycode(harmonyCode);
    if (code === 0) {
      return;
    }
    const unicode = event.unicode !== undefined && event.unicode > 0 ? event.unicode :
      unicodeFor(code, modifiers);
    const session = Runtime.session;
    if (session === null) {
      return;
    }
    session.sendKey(new KeyInput(down ? KeyAction.DOWN : KeyAction.UP, modifiers, 0, code, unicode,
      Date.now() * 1000));
  }

  private sendText(text: string): void {
    const session = Runtime.session;
    if (session === null) {
      return;
    }
    session.sendText(new TextInputMessage(text, Date.now() * 1000));
  }

  private sendDelete(count: number): void {
    const session = Runtime.session;
    if (session === null) {
      return;
    }
    for (let i = 0; i < count; i++) {
      const ts = Date.now() * 1000;
      session.sendKey(new KeyInput(KeyAction.DOWN, 0, 0, 67, 0, ts));
      session.sendKey(new KeyInput(KeyAction.UP, 0, 0, 67, 0, ts));
    }
  }

  private dispatchEvents(events: GestureEvent[]): void {
    const session = Runtime.session;
    if (session === null) {
      return;
    }
    for (const event of events) {
      if (event.pointer !== null) {
        session.sendPointer(event.pointer);
      }
      if (event.scroll !== null) {
        session.sendScroll(event.scroll);
      }
    }
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      VideoSurface({
        configWidth: this.configWidth,
        configHeight: this.configHeight,
        onSurfaceReady: (surfaceId: string) => {
          this.surfaceId = surfaceId;
          hilog.info(DOMAIN, TAG, 'surface ready %{public}s', surfaceId);
          this.startDecoder();
        },
        onSurfaceDestroyed: () => {
          hilog.info(DOMAIN, TAG, 'surface destroyed');
          this.stopDecoder();
          this.surfaceId = '';
        },
        onContentRect: (rect: ContentRect) => {
          this.contentW = rect.width;
          this.contentH = rect.height;
        }
      })

      if (this.contentW > 0 && this.inputActive()) {
        Column() {
          InputOverlay({
            contentWidth: this.contentW,
            contentHeight: this.contentH,
            onEvents: (events: GestureEvent[]) => {
              this.dispatchEvents(events);
            }
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .hitTestBehavior(HitTestMode.Transparent)
      }

      if (this.keyboardOn) {
        KeyboardDock({
          inputEnabled: this.keyboardOn && this.keyboardReady(),
          onText: (text: string) => {
            this.sendText(text);
          },
          onDelete: (count: number) => {
            this.sendDelete(count);
          },
          onKey: (event: KeyEvent) => {
            this.onHardwareKey(event);
          }
        })
      }

      if (this.statusText.length > 0) {
        Text(this.statusText)
          .fontSize(16)
          .fontColor('#888888')
      }

      if (this.debugOn) {
        Column() {
          StatsOverlay()
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(12)
        .hitTestBehavior(HitTestMode.None)
      }

      // 右上角抽屉：收起时只剩齿轮，展开为 调试/输入/键盘/断开 + 关闭
      Column({ space: 6 }) {
        if (this.toolbarOpen) {
          Stack() {
            Image(this.debugGlyph()).width(20).height(20)
          }
          .width(32)
          .height(32)
          .backgroundColor('#99141A24')
          .borderRadius(8)
          .border({ width: 1, color: '#33FFFFFF' })
          .onClick(() => {
            this.toggleDebug();
          })
          Stack() {
            Image(this.inputGlyph()).width(20).height(20)
          }
          .width(32)
          .height(32)
          .backgroundColor('#99141A24')
          .borderRadius(8)
          .border({ width: 1, color: '#33FFFFFF' })
          .onClick(() => {
            this.toggleInput();
          })
          Stack() {
            Image(this.keyboardGlyph()).width(20).height(20)
          }
          .width(32)
          .height(32)
          .backgroundColor('#99141A24')
          .borderRadius(8)
          .border({ width: 1, color: '#33FFFFFF' })
          .onClick(() => {
            this.toggleKeyboard();
          })
          Stack() {
            Image(this.disconnectGlyph()).width(20).height(20)
          }
          .width(32)
          .height(32)
          .backgroundColor('#99141A24')
          .borderRadius(8)
          .border({ width: 1, color: '#33FFFFFF' })
          .onClick(() => {
            this.requestDisconnect();
          })
        }
        if (this.toolbarOpen) {
          Stack() {
            Image($r('app.media.ic_close_normal')).width(20).height(20)
          }
          .width(32)
          .height(32)
          .backgroundColor('#99141A24')
          .borderRadius(8)
          .border({ width: 1, color: '#33FFFFFF' })
          .onClick(() => {
            this.toolbarOpen = false;
          })
        } else {
          Stack() {
            Image($r('app.media.ic_settings_normal')).width(20).height(20)
          }
          .width(32)
          .height(32)
          .backgroundColor('#99141A24')
          .borderRadius(8)
          .border({ width: 1, color: '#33FFFFFF' })
          .onClick(() => {
            this.toolbarOpen = true;
          })
        }
      }
      .margin({ bottom: 10, right: 6 })
    if (this.waiting) {
        Column({ space: 14 }) {
          LoadingProgress().width(56).height(56).color(Color.White)
          Text(this.waitingText).fontSize(16).fontColor(Color.White)
          Text(`等待重连 ${this.remainSec}s`).fontSize(14).fontColor('#AAAAAA')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#99000000')
        .hitTestBehavior(HitTestMode.Block)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    .focusable(true)
    .defaultFocus(true)
    .onKeyEvent((event: KeyEvent) => {
      if (!this.keyboardOn) {
        this.onHardwareKey(event);
      }
    })
  }
}