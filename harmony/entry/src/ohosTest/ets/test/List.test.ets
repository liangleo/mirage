import harnessTest from './Harness.test';
import protocolTest from './Protocol.test';
import inputProtocolTest from './InputProtocol.test';
import inputGateTest from './InputGate.test';
import gestureMapperTest from './GestureMapper.test';
import keyMappingTest from './KeyMapping.test';
import inputGeometryTest from './InputGeometry.test';
import imeBridgeTest from './ImeBridge.test';
import edgeGestureTest from './EdgeGesture.test';
import clientSessionTest from './ClientSession.test';
import pairingTest from './Pairing.test';
import selectorTest from './Selector.test';
import fingerprintTest from './Fingerprint.test';
import discoveryPolicyTest from './Discovery.test';
import sessionMachineTest from './SessionMachine.test';
import nativeBridgeTest from './NativeBridge.test';

export default function testsuite() {
  harnessTest();
  protocolTest();
  inputProtocolTest();
  inputGateTest();
  gestureMapperTest();
  keyMappingTest();
  inputGeometryTest();
  imeBridgeTest();
  edgeGestureTest();
  clientSessionTest();
  pairingTest();
  selectorTest();
  fingerprintTest();
  discoveryPolicyTest();
  sessionMachineTest();
  nativeBridgeTest();
}