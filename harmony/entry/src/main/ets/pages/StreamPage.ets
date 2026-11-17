import { router } from '@kit.ArkUI';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { closeDecoder, DecoderEvent, onEvent, openDecoder, submitVideo } from 'libmirage.so';
import { Runtime } from '../core/Runtime';
import { KeyAction, KeyInput, TextInput as TextInputMessage } from '../core/InputProtocol';
import { SessionConfig, VideoFrame } from '../core/Protocol';
import { GestureEvent } from '../input/GestureMapper';
import { ContentRect } from '../input/InputGeometry';
import { androidKeycode, ModifierTracker, unicodeFor } from '../input/KeyMapping';
import { ControlDrawer } from '../ui/ControlDrawer';
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
  @State private drawerOpen: boolean = false;
  @State private debugOn: boolean = false;
  @State private inputOn: boolean = true;
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

  aboutToAppear(): void {
    this.applyWindow(true);
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
      this.configWidth = config.width;
      this.configHeight = config.height;
      this.statusText = '';
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
    // 会话彻底结束（重试耗尽或 Mac 侧关闭）后不能停在冻结的画面，退回连接页等待
    Runtime.onClosed = (reason: string) => {
      hilog.info(DOMAIN, TAG, 'session closed: %{public}s; back to connect', reason);
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
    this.applyWindow(false);
    Runtime.onVideo = (frame: VideoFrame) => {
    };
    Runtime.onConfig = (config: SessionConfig) => {
    };
    Runtime.onInputGate = (enabled: boolean, reason: string) => {
    };
    Runtime.onClosed = (reason: string) => {
    };
    this.stopDecoder();
    const session = Runtime.session;
    if (session !== null) {
      session.releaseAll();
      session.stop();
    }
    Runtime.session = null;
    Runtime.hasConfig = false;
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
    return this.inputOn && this.capsOk && this.gateEnabled && !this.drawerOpen;
  }

  private applyInputCaps(): void {
    this.capsOk = (Runtime.config.inputCaps & 0x01) !== 0;
    this.inputOn = this.capsOk;
    this.syncInput();
  }

  private syncInput(): void {
    const session = Runtime.session;
    if (session !== null) {
      session.setInputEnabled(this.inputActive());
    }
  }

  private openDrawer(): void {
    const session = Runtime.session;
    if (session !== null) {
      session.releaseAll();
    }
    this.setKeyboard(false);
    this.drawerOpen = true;
    this.syncInput();
  }

  private closeDrawer(): void {
    this.drawerOpen = false;
    this.syncInput();
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
    Stack({ alignContent: Alignment.TopEnd }) {
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
          inputEnabled: this.keyboardOn && this.inputActive(),
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

      if (!this.drawerOpen) {
        Column() {
          Column() {
          }
          .width('100%')
          .height(80)
          .borderRadius({ topLeft: 7, bottomLeft: 7 })
          .backgroundColor('#66000000')
          .onClick(() => {
            this.openDrawer();
          })
        }
        .width(14)
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }

      if (this.drawerOpen) {
        ControlDrawer({
          inputOn: this.inputOn,
          keyboardOn: this.keyboardOn,
          debugOn: this.debugOn,
          capsOk: this.capsOk,
          gateEnabled: this.gateEnabled,
          gateReason: this.gateReason,
          onToggleInput: () => {
            this.inputOn = !this.inputOn;
            this.syncInput();
          },
          onToggleKeyboard: () => {
            const turnOn = !this.keyboardOn;
            if (turnOn) {
              this.closeDrawer();
            }
            this.setKeyboard(turnOn);
          },
          onToggleDebug: () => {
            this.debugOn = !this.debugOn;
          },
          onDisconnect: () => {
            this.disconnect();
          },
          onClose: () => {
            this.closeDrawer();
          }
        })
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