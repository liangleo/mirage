import harnessTest from './Harness.test';
import protocolTest from './Protocol.test';
import pairingTest from './Pairing.test';
import selectorTest from './Selector.test';
import fingerprintTest from './Fingerprint.test';
import discoveryPolicyTest from './Discovery.test';
import sessionMachineTest from './SessionMachine.test';
import nativeBridgeTest from './NativeBridge.test';

export default function testsuite() {
  harnessTest();
  protocolTest();
  pairingTest();
  selectorTest();
  fingerprintTest();
  discoveryPolicyTest();
  sessionMachineTest();
  nativeBridgeTest();
}