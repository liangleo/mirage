import XCTest
import Security
@testable import MirageHelper

final class TLSIdentityTests: XCTestCase {
    func testLoadOrCreateIsStableAndValid() throws {
        let first = try TLSIdentity.loadOrCreate()
        XCTAssertEqual(first.fingerprint.count, 32)
        XCTAssertFalse(first.certificateDER.isEmpty)
        XCTAssertNotNil(SecCertificateCreateWithData(nil, first.certificateDER as CFData))

        let second = try TLSIdentity.loadOrCreate()
        XCTAssertEqual(first.fingerprint, second.fingerprint)
    }
}