import XCTest
@testable import MirageCore

final class PairingTests: XCTestCase {
    private let fingerprint = Data((0..<32).map(UInt8.init))
    private let deviceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    func testRoundTrip() throws {
        let payload = PairingPayload(
            host: "192.168.1.20",
            port: 7777,
            fingerprint: fingerprint,
            name: "Leo 的 Mac",
            deviceID: deviceID
        )
        let url = try XCTUnwrap(payload.encodeURL())
        XCTAssertEqual(PairingPayload(url: url), payload)
    }

    func testIPv6HostRoundTrip() throws {
        let payload = PairingPayload(host: "fe80::1", port: 7778, fingerprint: fingerprint, name: "Mac", deviceID: deviceID)
        let url = try XCTUnwrap(payload.encodeURL())
        XCTAssertEqual(PairingPayload(url: url)?.host, "fe80::1")
    }

    func testRejectsInvalidURLs() {
        func parse(_ string: String) -> PairingPayload? {
            guard let url = URL(string: string) else { return nil }
            return PairingPayload(url: url)
        }
        let validFingerprint = fingerprint.map { String(format: "%02x", $0) }.joined()
        let base = "mirage://pair?v=1&host=1.2.3.4&port=7777&fp=\(validFingerprint)&name=Mac&id=\(deviceID.uuidString)"

        XCTAssertNotNil(parse(base))
        XCTAssertNil(parse(base.replacingOccurrences(of: "v=1", with: "v=2")))
        XCTAssertNil(parse(base.replacingOccurrences(of: "fp=\(validFingerprint)", with: "fp=abcd")))
        XCTAssertNil(parse(base.replacingOccurrences(of: "port=7777", with: "port=0")))
        XCTAssertNil(parse(base.replacingOccurrences(of: "port=7777", with: "port=65536")))
        XCTAssertNil(parse(base.replacingOccurrences(of: "id=\(deviceID.uuidString)", with: "id=nope")))
        XCTAssertNil(parse("https://pair?v=1&host=1.2.3.4&port=7777&fp=\(validFingerprint)&id=\(deviceID.uuidString)"))
    }

    func testDecodeFingerprint() {
        XCTAssertEqual(PairingPayload.decodeFingerprint(fingerprint.map { String(format: "%02x", $0) }.joined()), fingerprint)
        XCTAssertNil(PairingPayload.decodeFingerprint("abc"))
        XCTAssertNil(PairingPayload.decodeFingerprint(String(repeating: "g", count: 64)))
    }
}