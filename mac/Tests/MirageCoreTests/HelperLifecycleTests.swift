import XCTest
@testable import MirageHelper

final class HelperLifecycleTests: XCTestCase {
    func testDisablingWifiStopsRunningHelper() {
        let action = HelperLifecycle.actionOnWifiChange(enabled: false, usbEnabled: false, running: true)
        XCTAssertEqual(action, .stop)
    }

    func testDisablingWifiKeepsHelperWhenUsbNeedsIt() {
        let action = HelperLifecycle.actionOnWifiChange(enabled: false, usbEnabled: true, running: true)
        XCTAssertEqual(action, .none)
    }

    func testEnablingWifiRestartsRunningHelper() {
        let action = HelperLifecycle.actionOnWifiChange(enabled: true, usbEnabled: false, running: true)
        XCTAssertEqual(action, .restart)
    }

    func testEnablingWifiStartsStoppedHelper() {
        let action = HelperLifecycle.actionOnWifiChange(enabled: true, usbEnabled: false, running: false)
        XCTAssertEqual(action, .start)
    }

    func testDisablingUsbStopsRunningHelper() {
        let action = HelperLifecycle.actionOnUsbChange(enabled: false, wasWifi: false, running: true)
        XCTAssertEqual(action, .stop)
    }

    func testEnablingUsbRestartsWifiHelper() {
        let action = HelperLifecycle.actionOnUsbChange(enabled: true, wasWifi: true, running: true)
        XCTAssertEqual(action, .restart)
    }

    func testEnablingUsbStartsStoppedHelper() {
        let action = HelperLifecycle.actionOnUsbChange(enabled: true, wasWifi: false, running: false)
        XCTAssertEqual(action, .start)
    }

    func testEnablingUsbWithPlainHelperDoesNotRestart() {
        let action = HelperLifecycle.actionOnUsbChange(enabled: true, wasWifi: false, running: true)
        XCTAssertEqual(action, .none)
    }
}