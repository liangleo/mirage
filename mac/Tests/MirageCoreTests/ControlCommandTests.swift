import XCTest
@testable import MirageHelper

final class ControlCommandTests: XCTestCase {
    func testParsesWifiOn() {
        XCTAssertEqual(ControlParser.parse("wifi on\n"), .wifiOn)
        XCTAssertEqual(ControlParser.parse("  WIFI ON  "), .wifiOn)
    }

    func testParsesWifiOff() {
        XCTAssertEqual(ControlParser.parse("wifi off"), .wifiOff)
    }

    func testParsesWifiStatus() {
        XCTAssertEqual(ControlParser.parse("wifi status"), .wifiStatus)
    }

    func testRejectsUnknown() {
        XCTAssertNil(ControlParser.parse(""))
        XCTAssertNil(ControlParser.parse("shutdown"))
        XCTAssertNil(ControlParser.parse("wifi maybe"))
    }
}