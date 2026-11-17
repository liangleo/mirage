import { describe, it, expect } from '@ohos/hypium';
import { closeDecoder, onEvent, openDecoder, startUsb, stopUsb, submitVideo, usbWrite } from 'libmirage.so';
import { DecoderEvent } from 'libmirage.so';

export default function nativeBridgeTest() {
  describe('nativeBridge', () => {
    it('registers event callback and reports failure without surface', 0, async () => {
      let lastKind = '';
      onEvent((event: DecoderEvent) => {
        lastKind = event.kind;
      });
      let opened = true;
      openDecoder(320, 240, 30, '', (result: boolean) => {
        opened = result;
      });
      // 打开在 codec 工作线程上执行，回调经 threadsafe function 投递，需让出事件循环
      await new Promise<void>((resolve) => setTimeout(resolve, 300));
      expect(lastKind).assertEqual('decoderError');
      expect(opened).assertFalse();
    });

    it('rejects submit before open', 0, () => {
      expect(submitVideo(new ArrayBuffer(16), 1, 1, 0)).assertEqual(-1);
    });

    it('closes idempotently', 0, () => {
      closeDecoder();
      closeDecoder();
      expect(submitVideo(new ArrayBuffer(0), 0, 0, 0)).assertEqual(-1);
    });

    it('exports usb bridge functions', 0, () => {
      expect(typeof startUsb).assertEqual('function');
      expect(typeof stopUsb).assertEqual('function');
      expect(typeof usbWrite).assertEqual('function');
    });

    it('rejects usb write before start', 0, () => {
      stopUsb();
      expect(usbWrite(new Uint8Array([1, 2, 3]))).assertEqual(-1);
    });
  });
}