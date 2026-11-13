import XCTest
@testable import MirageHelper

final class AnnexBTests: XCTestCase {
    func testSplitAVCCIntoNalUnits() {
        let avcc = hexData("000000036742000000000268ce")
        let nalUnits = splitAVCC(avcc)

        XCTAssertEqual(nalUnits, [hexData("674200"), hexData("68ce")])
    }

    func testAnnexBPrefixesStartCodes() {
        let output = annexB(nalUnits: [hexData("674200"), hexData("68ce")])
        XCTAssertEqual(output, hexData("000000016742000000000168ce"))
    }

    func testSplitAVCCOutOfBoundsReturnsEmpty() {
        XCTAssertEqual(splitAVCC(hexData("00000005674200")), [])
    }
}