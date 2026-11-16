import { describe, it, expect } from '@ohos/hypium';
import {
  backoffMs,
  reduce,
  SessionEvent,
  SessionEventKind,
  SessionModel,
  SessionState
} from '../../../main/ets/core/SessionMachine';

function model(state: SessionState, attempts: number): SessionModel {
  const m = new SessionModel();
  m.state = state;
  m.attempts = attempts;
  m.generation = 1;
  return m;
}

export default function sessionMachineTest() {
  describe('sessionMachine', () => {
    it('config moves to streaming and resets attempts', 0, () => {
      const result = reduce(model(SessionState.Connecting, 3),
        new SessionEvent(SessionEventKind.CONFIG), 1000);
      expect(result.model.state).assertEqual(SessionState.Streaming);
      expect(result.model.attempts).assertEqual(0);
    });

    it('closed schedules retry with capped backoff', 0, () => {
      const result = reduce(model(SessionState.Streaming, 0),
        new SessionEvent(SessionEventKind.CLOSED, 'x'), 0);
      expect(result.model.state).assertEqual(SessionState.Recovering);
      expect(result.model.attempts).assertEqual(1);
      expect(result.model.reconnectAtMs).assertEqual(500);
      expect(backoffMs(1)).assertEqual(500);
      expect(backoffMs(2)).assertEqual(1000);
      expect(backoffMs(4)).assertEqual(4000);
      expect(backoffMs(9)).assertEqual(5000);
    });

    it('gives up after ten attempts', 0, () => {
      const result = reduce(model(SessionState.Recovering, 10),
        new SessionEvent(SessionEventKind.CLOSED, 'x'), 0);
      expect(result.model.state).assertEqual(SessionState.Stopped);
    });

    it('manual disconnect stops retrying', 0, () => {
      const result = reduce(model(SessionState.Recovering, 2),
        new SessionEvent(SessionEventKind.DISCONNECT), 0);
      expect(result.model.state).assertEqual(SessionState.Stopped);
      expect(result.model.attempts).assertEqual(0);
    });

    it('retry only from recovering', 0, () => {
      const result = reduce(model(SessionState.Recovering, 1),
        new SessionEvent(SessionEventKind.RETRY), 0);
      expect(result.model.state).assertEqual(SessionState.Connecting);
      expect(result.model.generation).assertEqual(2);
      expect(reduce(model(SessionState.Streaming, 0),
        new SessionEvent(SessionEventKind.RETRY), 0).model.state).assertEqual(SessionState.Streaming);
    });

    it('transport change resets and bumps generation', 0, () => {
      const result = reduce(model(SessionState.Streaming, 4),
        new SessionEvent(SessionEventKind.TRANSPORT_CHANGED), 0);
      expect(result.model.state).assertEqual(SessionState.Selecting);
      expect(result.model.generation).assertEqual(2);
      expect(result.model.attempts).assertEqual(0);
    });

    it('wait usb returns to idle and polls', 0, () => {
      const result = reduce(model(SessionState.Selecting, 0),
        new SessionEvent(SessionEventKind.SELECT, '', 'WAIT_USB'), 0);
      expect(result.model.state).assertEqual(SessionState.Idle);
    });

    it('pausing keeps streaming', 0, () => {
      const result = reduce(model(SessionState.Streaming, 0),
        new SessionEvent(SessionEventKind.PAUSED), 0);
      expect(result.model.state).assertEqual(SessionState.Streaming);
    });
  });
}