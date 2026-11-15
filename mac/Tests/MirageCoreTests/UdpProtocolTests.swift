import XCTest
@testable import MirageCore

final class UdpProtocolTests: XCTestCase {
    private struct Vectors: Decodable {
        struct DatagramVector: Decodable {
            struct Fields: Decodable {
                let seq: UInt32
                let frameID: UInt32
                let fragIndex: UInt16
                let fragCount: UInt16
                let flags: UInt8
                let reserved: UInt8
                let payloadLength: UInt16
                let payloadHex: String
            }
            let hex: String
            let fields: Fields
        }
        struct NackVector: Decodable {
            struct Fields: Decodable {
                let seq: UInt32
                let frameID: UInt32
                let bitmapStart: UInt16
                let bitmapHex: String
            }
            let hex: String
            let fields: Fields
        }
        struct FeedbackVector: Decodable {
            struct Fields: Decodable {
                let fpsX10: UInt16
                let decodeMS: UInt16
                let droppedFrames: UInt16
                let queueDepth: UInt16
                let rttMS: UInt16
                let lossPermille: UInt16
                let recvBitrateBps: UInt32
                let arrivalDelayMS: UInt32
                let timestampMicros: UInt64
            }
            let hex: String
            let fields: Fields
        }
        let udp: UdpVectors
        struct UdpVectors: Decodable {
            let datagram: DatagramVector
            let nack: NackVector
            let feedback: FeedbackVector
        }
    }

    private let vectors: Vectors = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try! Data(contentsOf: root.appendingPathComponent("protocol/vectors.json"))
        return try! JSONDecoder().decode(Vectors.self, from: data)
    }()

    private func header(_ fields: Vectors.DatagramVector.Fields) -> UdpVideoHeader {
        UdpVideoHeader(
            seq: fields.seq,
            frameID: fields.frameID,
            fragIndex: fields.fragIndex,
            fragCount: fields.fragCount,
            flags: fields.flags,
            reserved: fields.reserved,
            payloadLength: fields.payloadLength
        )
    }

    func testDatagramMatchesSharedVectorAndRoundTrips() throws {
        let expected = vectors.udp.datagram
        let payload = hexData(expected.fields.payloadHex)
        let encoded = try encodeUdpDatagram(UdpDatagram(header: header(expected.fields), payload: payload))
        XCTAssertEqual(encoded, hexData(expected.hex))

        let decoded = try decodeUdpDatagram(encoded)
        XCTAssertEqual(decoded.header, header(expected.fields))
        XCTAssertEqual(decoded.payload, payload)
    }

    func testNackMatchesSharedVector() throws {
        let expected = vectors.udp.nack
        let bitmap = hexData(expected.fields.bitmapHex)
        let encoded = try encodeUdpNack(
            seq: expected.fields.seq,
            frameID: expected.fields.frameID,
            bitmapStart: expected.fields.bitmapStart,
            bitmap: bitmap
        )
        XCTAssertEqual(encoded, hexData(expected.hex))

        let decoded = try decodeUdpDatagram(encoded)
        XCTAssertTrue(decoded.header.isNack)
        XCTAssertEqual(decoded.header.fragIndex, expected.fields.bitmapStart)
        XCTAssertEqual(decoded.header.fragCount, UInt16(bitmap.count))
        XCTAssertEqual(decoded.payload, bitmap)
    }

    func testFeedbackMatchesSharedVector() throws {
        let expected = vectors.udp.feedback.fields
        let feedback = Feedback(
            fpsX10: expected.fpsX10,
            decodeMS: expected.decodeMS,
            droppedFrames: expected.droppedFrames,
            queueDepth: expected.queueDepth,
            rttMS: expected.rttMS,
            lossPermille: expected.lossPermille,
            recvBitrateBps: expected.recvBitrateBps,
            arrivalDelayMS: expected.arrivalDelayMS,
            timestampMicros: expected.timestampMicros
        )
        let frame = encodeFeedback(feedback)
        XCTAssertEqual(frame.type, MessageType.feedback.rawValue)
        XCTAssertEqual(frame.payload, hexData(vectors.udp.feedback.hex))
        XCTAssertEqual(try decodeFeedback(frame.payload), feedback)
    }

    func testFlagsRoundTrip() throws {
        let flags = UdpFlags.sof | UdpFlags.eof | UdpFlags.key
        let header = UdpVideoHeader(seq: 7, frameID: 3, fragIndex: 0, fragCount: 1, flags: flags, payloadLength: 2)
        let decoded = try decodeUdpDatagram(try encodeUdpDatagram(UdpDatagram(header: header, payload: Data([1, 2]))))
        XCTAssertTrue(decoded.header.isSOF)
        XCTAssertTrue(decoded.header.isEOF)
        XCTAssertTrue(decoded.header.isKeyFrame)
        XCTAssertFalse(decoded.header.isNack)
    }

    func testRejectsMalformedInput() throws {
        let tooLarge = Data(repeating: 0, count: UdpVideoHeader.size)
        XCTAssertThrowsError(try decodeUdpDatagram(Data(tooLarge.prefix(8))))

        let payloadLengthMismatch = Data([0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 4, 0xAA])
        XCTAssertThrowsError(try decodeUdpDatagram(payloadLengthMismatch))

        let zeroFrags = Data([0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertThrowsError(try decodeUdpDatagram(zeroFrags))

        let oversized = UdpVideoHeader.maxDatagramPayload + 1
        let validHeader = UdpVideoHeader(seq: 1, frameID: 1, fragIndex: 0, fragCount: 1, flags: 0, payloadLength: UInt16(oversized))
        XCTAssertThrowsError(try encodeUdpDatagram(UdpDatagram(header: validHeader, payload: Data(repeating: 0, count: oversized)))) { error in
            XCTAssertEqual(error as? UdpError, .payloadTooLarge)
        }
    }

    func testUdpConfigRoundTrip() throws {
        let config = UdpConfig(
            port: 7778,
            cipher: .aes256GCM,
            key: Data((0..<32).map(UInt8.init)),
            noncePrefix: Data([1, 2, 3, 4]),
            flags: 1
        )
        let frame = encodeUdpConfig(config)
        XCTAssertEqual(frame.type, MessageType.udpConfig.rawValue)
        XCTAssertEqual(try decodeUdpConfig(frame.payload), config)
        XCTAssertTrue(config.isEnabled)
    }
}