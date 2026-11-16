import { describe, it, expect } from '@ohos/hypium';
import { decideDiscovery } from '../../../main/ets/net/MdnsDiscovery';

export default function discoveryPolicyTest() {
  describe('discoveryPolicy', () => {
    it('auto-connects only when fingerprints match', 0, () => {
      const fp = 'ab'.repeat(32);
      expect(decideDiscovery(fp, fp)).assertEqual('auto');
      expect(decideDiscovery(fp.toUpperCase(), fp)).assertEqual('auto');
      expect(decideDiscovery('cd'.repeat(32), fp)).assertEqual('needs-pairing');
      expect(decideDiscovery('', fp)).assertEqual('needs-pairing');
      expect(decideDiscovery(fp, '')).assertEqual('needs-pairing');
      expect(decideDiscovery('ab', fp)).assertEqual('needs-pairing');
    });
  });
}