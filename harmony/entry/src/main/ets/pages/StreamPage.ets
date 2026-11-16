import { router } from '@kit.ArkUI';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { closeDecoder, DecoderEvent, onEvent, openDecoder, setSurface, submitVideo } from 'libmirage.so';
import { Runtime } from '../core/Runtime';
import { SessionConfig, VideoFrame } from '../core/Protocol';
import { VideoSurface } from '../ui/VideoSurface';
import { StatsOverlay } from '../ui/StatsOverlay';

const DOMAIN = 0x0100;
const TAG = 'MirageStream';

@Entry
@Component
struct StreamPage {
  @State private configWidth: number = Runtime.hasConfig ? Runtime.config.width : 16;
  @State private configHeight: number = Runtime.hasConfig ? Runtime.config.height : 9;
  @State private statusText: string = Runtime.hasConfig ? '' : '等待视频配置';
  private surfaceId: string = '';
  private decoderOpen: boolean = false;

  aboutToAppear(): void {
    this.applyWindow(true);
    onEvent((event: DecoderEvent) => {
      if (event.kind === 'frame') {
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
      this.startDecoder();
    };
    Runtime.onVideo = (frame: VideoFrame) => {
      this.submitFrame(frame);
    };
    if (Runtime.hasConfig) {
      this.configWidth = Runtime.config.width;
      this.configHeight = Runtime.config.height;
      this.startDecoder();
    }
  }

  aboutToDisappear(): void {
    this.applyWindow(false);
    Runtime.onVideo = (frame: VideoFrame) => {
    };
    Runtime.onConfig = (config: SessionConfig) => {
    };
    this.stopDecoder();
    const session = Runtime.session;
    if (session !== null) {
      session.stop();
    }
    Runtime.session = null;
    Runtime.hasConfig = false;
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
    if (this.decoderOpen || this.surfaceId.length === 0 || !Runtime.hasConfig) {
      return;
    }
    const config = Runtime.config;
    const opened = openDecoder(config.width, config.height, config.fps > 0 ? config.fps : 60, this.surfaceId);
    if (opened) {
      this.decoderOpen = true;
      hilog.info(DOMAIN, TAG, 'decoder opened %{public}dx%{public}d surface=%{public}s',
        config.width, config.height, this.surfaceId);
      const session = Runtime.session;
      if (session !== null) {
        session.requestKeyframe();
      }
    } else {
      hilog.error(DOMAIN, TAG, 'decoder open failed');
    }
  }

  private stopDecoder(): void {
    if (!this.decoderOpen) {
      return;
    }
    this.decoderOpen = false;
    closeDecoder();
    hilog.info(DOMAIN, TAG, 'decoder closed');
  }

  private submitFrame(frame: VideoFrame): void {
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
        }
      })

      if (this.statusText.length > 0) {
        Text(this.statusText)
          .fontSize(16)
          .fontColor('#888888')
      }

      Column({ space: 10 }) {
        StatsOverlay()
        Button('返回')
          .fontSize(13)
          .height(32)
          .backgroundColor('#66000000')
          .onClick(() => {
            router.back();
          })
      }
      .alignItems(HorizontalAlign.End)
      .padding(12)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
  }
}