import { Stats, StatsSnapshot } from '../core/Stats';
import { Runtime } from '../core/Runtime';

@Component
export struct StatsOverlay {
  private stats: Stats = Runtime.stats;
  @State private line1: string = 'Waiting for video';
  @State private line2: string = '';
  @State private transport: string = '';
  private timer: number = -1;

  aboutToAppear(): void {
    this.refresh();
    this.timer = setInterval(() => {
      this.refresh();
    }, 500);
  }

  aboutToDisappear(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private refresh(): void {
    const snap: StatsSnapshot = this.stats.snapshot();
    const e2e = snap.e2eMs >= 0 ? `${snap.e2eMs}ms` : '--';
    const rtt = snap.rttMs >= 0 ? `${snap.rttMs}ms` : '--';
    this.line1 = `${snap.fps} fps · ${snap.bitrateMbps.toFixed(1)} Mbps · drop ${snap.dropped}`;
    this.line2 = `decode ${snap.decodeMs.toFixed(1)}ms · e2e ${e2e} · RTT ${rtt} · ${snap.codec}`;
    this.transport = Runtime.transportName;
  }

  build() {
    Column({ space: 2 }) {
      Row() {
        Text(this.line1).fontSize(13).fontColor(Color.White)
        Blank()
        Text(this.transport).fontSize(12).fontColor('#AAAAAA')
      }
      .width('100%')
      Text(this.line2).fontSize(13).fontColor('#BBBBBB')
    }
    .width(300)
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 14, right: 14, top: 8, bottom: 8 })
    .backgroundColor('#66000000')
    .borderRadius(8)
  }
}