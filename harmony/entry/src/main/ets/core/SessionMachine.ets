export enum SessionState {
  Idle = 'Idle',
  Selecting = 'Selecting',
  AwaitingUsbAuth = 'AwaitingUsbAuth',
  Connecting = 'Connecting',
  Streaming = 'Streaming',
  Recovering = 'Recovering',
  Stopped = 'Stopped'
}

export enum SessionEventKind {
  CONNECT = 'connect',
  SELECT = 'select',
  CONFIG = 'config',
  CLOSED = 'closed',
  RETRY = 'retry',
  DISCONNECT = 'disconnect',
  TRANSPORT_CHANGED = 'transportChanged',
  ROTATION = 'rotation',
  PAUSED = 'paused'
}

export enum SessionEffectKind {
  OPEN_TRANSPORT = 'openTransport',
  CLOSE_TRANSPORT = 'closeTransport',
  START_DECODER = 'startDecoder',
  STOP_DECODER = 'stopDecoder',
  REQUEST_KEYFRAME = 'requestKeyframe',
  POLL_USB = 'pollUsb'
}

export class SessionEvent {
  kind: SessionEventKind;
  reason: string;
  choiceKind: string;

  constructor(kind: SessionEventKind, reason: string = '', choiceKind: string = '') {
    this.kind = kind;
    this.reason = reason;
    this.choiceKind = choiceKind;
  }
}

export class SessionModel {
  state: SessionState = SessionState.Idle;
  attempts: number = 0;
  reconnectAtMs: number = 0;
  generation: number = 0;

  copy(): SessionModel {
    const model = new SessionModel();
    model.state = this.state;
    model.attempts = this.attempts;
    model.reconnectAtMs = this.reconnectAtMs;
    model.generation = this.generation;
    return model;
  }
}

export class ReduceResult {
  model: SessionModel;
  effects: SessionEffectKind[];

  constructor(model: SessionModel, effects: SessionEffectKind[]) {
    this.model = model;
    this.effects = effects;
  }
}

const MAX_ATTEMPTS = 10;

export function backoffMs(attempt: number): number {
  if (attempt < 1) {
    return 0;
  }
  const raw = 500 * Math.pow(2, attempt - 1);
  return Math.min(raw, 5000);
}

export function reduce(model: SessionModel, event: SessionEvent, nowMs: number): ReduceResult {
  const next = model.copy();
  const effects: SessionEffectKind[] = [];

  if (event.kind === SessionEventKind.CONNECT) {
    if (next.state === SessionState.Idle || next.state === SessionState.Stopped) {
      next.state = SessionState.Selecting;
      next.attempts = 0;
      next.generation += 1;
    }
    return new ReduceResult(next, effects);
  }

  if (event.kind === SessionEventKind.SELECT) {
    if (next.state !== SessionState.Selecting) {
      return new ReduceResult(next, effects);
    }
    if (event.choiceKind === 'WAIT_USB') {
      next.state = SessionState.Idle;
      effects.push(SessionEffectKind.POLL_USB);
    } else if (event.choiceKind === 'USB') {
      next.state = SessionState.Connecting;
      effects.push(SessionEffectKind.OPEN_TRANSPORT);
    } else {
      next.state = SessionState.Connecting;
      effects.push(SessionEffectKind.OPEN_TRANSPORT);
    }
    return new ReduceResult(next, effects);
  }

  if (event.kind === SessionEventKind.CONFIG) {
    if (next.state === SessionState.Connecting || next.state === SessionState.Streaming) {
      next.state = SessionState.Streaming;
      next.attempts = 0;
      next.reconnectAtMs = 0;
      effects.push(SessionEffectKind.START_DECODER);
      effects.push(SessionEffectKind.REQUEST_KEYFRAME);
    }
    return new ReduceResult(next, effects);
  }

  if (event.kind === SessionEventKind.CLOSED) {
    if (next.state !== SessionState.Connecting &&
      next.state !== SessionState.Streaming &&
      next.state !== SessionState.Recovering) {
      return new ReduceResult(next, effects);
    }
    effects.push(SessionEffectKind.CLOSE_TRANSPORT);
    effects.push(SessionEffectKind.STOP_DECODER);
    next.attempts += 1;
    if (next.attempts > MAX_ATTEMPTS) {
      next.state = SessionState.Stopped;
      next.reconnectAtMs = 0;
    } else {
      next.state = SessionState.Recovering;
      next.reconnectAtMs = nowMs + backoffMs(next.attempts);
    }
    return new ReduceResult(next, effects);
  }

  if (event.kind === SessionEventKind.RETRY) {
    if (next.state === SessionState.Recovering) {
      // RETRY 会立刻打开传输，必须进入 Connecting：Selecting 会吞掉打开失败的 CLOSED，重试链断掉
      next.state = SessionState.Connecting;
      next.generation += 1;
      effects.push(SessionEffectKind.OPEN_TRANSPORT);
    }
    return new ReduceResult(next, effects);
  }

  if (event.kind === SessionEventKind.DISCONNECT) {
    next.state = SessionState.Stopped;
    next.attempts = 0;
    next.reconnectAtMs = 0;
    next.generation += 1;
    effects.push(SessionEffectKind.CLOSE_TRANSPORT);
    effects.push(SessionEffectKind.STOP_DECODER);
    return new ReduceResult(next, effects);
  }

  if (event.kind === SessionEventKind.TRANSPORT_CHANGED) {
    next.state = SessionState.Selecting;
    next.attempts = 0;
    next.reconnectAtMs = 0;
    next.generation += 1;
    effects.push(SessionEffectKind.CLOSE_TRANSPORT);
    effects.push(SessionEffectKind.STOP_DECODER);
    return new ReduceResult(next, effects);
  }

  return new ReduceResult(next, effects);
}