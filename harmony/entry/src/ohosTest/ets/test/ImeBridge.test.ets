import { describe, it, expect } from '@ohos/hypium';
import { ImeBridge, ImeCommand, ImeCommandKind } from '../../../main/ets/input/ImeBridge';

export default function imeBridgeTest() {
  describe('imeBridge', () => {
    it('turns committed text into a text command', 0, () => {
      const bridge = new ImeBridge();
      const commands: ImeCommand[] = bridge.insertCommands('你好');
      expect(commands.length).assertEqual(1);
      expect(commands[0].kind).assertEqual(ImeCommandKind.TEXT);
      expect(commands[0].text).assertEqual('你好');
      expect(bridge.insertCommands('').length).assertEqual(0);
    });

    it('turns deletions into one delete command with a count', 0, () => {
      const bridge = new ImeBridge();
      const commands: ImeCommand[] = bridge.deleteCommands(2);
      expect(commands.length).assertEqual(1);
      expect(commands[0].kind).assertEqual(ImeCommandKind.DELETE);
      expect(commands[0].count).assertEqual(2);
      expect(bridge.deleteCommands(0).length).assertEqual(0);
      expect(bridge.deleteCommands(-1).length).assertEqual(0);
    });
  });
}