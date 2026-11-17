import { ClientSession } from './ClientSession';
import { SessionConfig, VideoFrame } from './Protocol';
import { SessionState } from './SessionMachine';
import { Stats } from './Stats';
import { SettingsStore } from '../settings/SettingsStore';

export class Runtime {
  static session: ClientSession | null = null;
  static store: SettingsStore | null = null;
  static debugOn: boolean = false;
  static inputOn: boolean = true;
  static stats: Stats = new Stats();
  static state: SessionState = SessionState.Idle;
  static config: SessionConfig = new SessionConfig();
  static hasConfig: boolean = false;
  static closedReason: string = '';
  static transportLabel: string = '';
  static transportName: string = '';
  static onVideo: (frame: VideoFrame) => void = (frame: VideoFrame) => {
  };
  static onConfig: (config: SessionConfig) => void = (config: SessionConfig) => {
  };
  static onState: (state: SessionState) => void = (state: SessionState) => {
  };
  static onClosed: (reason: string) => void = (reason: string) => {
  };
  // 断线等待重连：保留播放页，显示遮罩与倒计时，deadlineMs 到期后再退回连接页
  static onWaiting: (message: string, deadlineMs: number) => void = (message: string, deadlineMs: number) => {
  };
  static onInputGate: (enabled: boolean, reason: string) => void = (enabled: boolean, reason: string) => {
  };

  static reset(): void {
    Runtime.session = null;
    Runtime.store = null;
    Runtime.debugOn = false;
    Runtime.inputOn = true;
    Runtime.stats = new Stats();
    Runtime.state = SessionState.Idle;
    Runtime.config = new SessionConfig();
    Runtime.hasConfig = false;
    Runtime.closedReason = '';
    Runtime.transportName = '';
    Runtime.onVideo = (frame: VideoFrame) => {
    };
    Runtime.onConfig = (config: SessionConfig) => {
    };
    Runtime.onState = (state: SessionState) => {
    };
    Runtime.onClosed = (reason: string) => {
    };
    Runtime.onWaiting = (message: string, deadlineMs: number) => {
    };
    Runtime.onInputGate = (enabled: boolean, reason: string) => {
    };
  }
}