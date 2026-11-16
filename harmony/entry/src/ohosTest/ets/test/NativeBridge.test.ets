import { describe, it, expect } from '@ohos/hypium';
import { closeDecoder, onEvent, openDecoder, setSurface, submitVideo } from 'libmirage.so';
import { DecoderEvent } from 'libmirage.so';

export default function nativeBridgeTest() {
  describe('nativeBridge', () => {
    it('registers event callback and reports failure without surface', 0, async () => {
      let lastKind = '';
      onEvent((event: DecoderEvent) => {
        lastKind = event.kind;
      });
      const opened = openDecoder(320, 240, 30, '');
      expect(opened).assertFalse();
      // 回调经 threadsafe function 投递，需让出事件循环一次
      await new Promise<void>((resolve) => setTimeout(resolve, 50));
      expect(lastKind).assertEqual('decoderError');
    });

    it('rejects submit before open', 0, () => {
      expect(submitVideo(new ArrayBuffer(16), 1, 1, 0)).assertEqual(-1);
      expect(setSurface('')).assertFalse();
    });

    it('closes idempotently', 0, () => {
      closeDecoder();
      closeDecoder();
      expect(submitVideo(new ArrayBuffer(0), 0, 0, 0)).assertEqual(-1);
    });
  });
}