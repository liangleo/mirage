import XCTest
@testable import MirageCore

final class ProtocolTests: XCTestCase {
    func testFrameSplitAcrossThreeChunks() throws {
        let frame = Frame(type: 3, payload: Data([1, 2, 3, 4, 5]))
        let encoded = encodeFrame(frame)
        var decoder = FrameDecoder()

        decoder.append(encoded.prefix(2))
        XCTAssertNil(try decoder.next())

        decoder.append(encoded.subdata(in: 2..<(encoded.count - 1)))
        XCTAssertNil(try decoder.next())

        decoder.append(encoded.suffix(1))
        XCTAssertEqual(try decoder.next(), frame)
        XCTAssertNil(try decoder.next())
    }

    func testTwoFramesInOneChunk() throws {
        let a = Frame(type: 1, payload: Data([0xaa]))
        let b = Frame(type: 3, payload: Data([0xbb, 0xcc]))
        var decoder = FrameDecoder()
        decoder.append(encodeFrame(a) + encodeFrame(b))

        XCTAssertEqual(try decoder.next(), a)
        XCTAssertEqual(try decoder.next(), b)
        XCTAssertNil(try decoder.next())
    }

    func testOversizedFrameThrows() throws {
        var header = Data()
        appendUInt32BE(8 * 1024 * 1024 + 2, to: &header)
        header.append(0x03)

        var decoder = FrameDecoder()
        decoder.append(header)

        XCTAssertThrowsError(try decoder.next()) { error in
            XCTAssertEqual(error as? FrameError, .oversized)
        }
    }

    func testTruncatedHeaderReturnsNil() throws {
        var decoder = FrameDecoder()
        decoder.append(Data([0x00, 0x00, 0x00]))
        XCTAssertNil(try decoder.next())
    }

    func testUnknownTypeIsAcceptedByDecoder() throws {
        let frame = Frame(type: 99, payload: Data([0x01]))
        var decoder = FrameDecoder()
        decoder.append(encodeFrame(frame))
        XCTAssertEqual(try decoder.next(), frame)
    }
}

func appendUInt32BE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}

func hexData(_ hex: String) -> Data {
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        data.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return data
}