import { ClientSession } from './ClientSession';
import { SessionConfig, VideoFrame } from './Protocol';
import { SessionState } from './SessionMachine';
import { Stats } from './Stats';

export class Runtime {
  static session: ClientSession | null = null;
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
  static onInputGate: (enabled: boolean, reason: string) => void = (enabled: boolean, reason: string) => {
  };

  static reset(): void {
    Runtime.session = null;
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
    Runtime.onInputGate = (enabled: boolean, reason: string) => {
    };
  }
}