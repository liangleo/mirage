import XCTest
@testable import MirageCore

final class MessageTests: XCTestCase {
    private struct Vectors: Decodable {
        struct HelloVector: Decodable {
            let hex: String
            let fields: HelloFields
        }
        struct HelloFields: Decodable {
            let protoVersion: UInt8
            let clientVersion: UInt16
            let deviceID: String
            let screenWidth: UInt16
            let screenHeight: UInt16
            let xdpi: UInt16
            let ydpi: UInt16
            let maxFPS: UInt8
            let codecs: UInt8
            let features: UInt8
            let rotation: UInt8
            let name: String
        }
        struct VideoVector: Decodable {
            let headerHex: String
            let payloadHex: String
            let fields: VideoFields
        }
        struct VideoFields: Decodable {
            let codec: UInt8
            let flags: UInt8
            let frameID: UInt32
            let captureTimestampMicros: UInt64
            let reserved: UInt32
        }
        let hello: HelloVector
        let video: VideoVector
    }

    private let vectors: Vectors = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("protocol/vectors.json")
        let data = try! Data(contentsOf: url)
        return try! JSONDecoder().decode(Vectors.self, from: data)
    }()

    private func singleFrame(_ encoded: Data) throws -> Frame {
        var decoder = FrameDecoder()
        decoder.append(encoded)
        return try XCTUnwrap(try decoder.next())
    }

    func testHelloMatchesSharedVector() throws {
        let expected = vectors.hello.fields
        let hello = Hello(
            protoVersion: expected.protoVersion,
            clientVersion: expected.clientVersion,
            deviceID: hexData(expected.deviceID),
            screenWidth: expected.screenWidth,
            screenHeight: expected.screenHeight,
            xdpi: expected.xdpi,
            ydpi: expected.ydpi,
            maxFPS: expected.maxFPS,
            codecs: expected.codecs,
            features: expected.features,
            rotation: expected.rotation,
            name: expected.name
        )

        XCTAssertEqual(encodeHello(hello), hexData(vectors.hello.hex))

        var decoder = FrameDecoder()
        decoder.append(hexData(vectors.hello.hex))
        let frame = try XCTUnwrap(try decoder.next())
        XCTAssertEqual(frame.type, MessageType.hello.rawValue)
        XCTAssertEqual(try decodeHello(frame.payload), hello)
    }

    func testSessionConfigRoundTrip() throws {
        let config = SessionConfig(width: 2560, height: 1600, fps: 60, codec: 1, bitrate: 20_000_000, rotation: 0)
        let frame = try singleFrame(encodeSessionConfig(config))
        XCTAssertEqual(frame.type, MessageType.sessionConfig.rawValue)
        XCTAssertEqual(try decodeSessionConfig(frame.payload), config)
    }

    func testVideoMatchesSharedVectorAndRoundTrips() throws {
        let expected = vectors.video.fields
        let header = VideoHeader(
            codec: expected.codec,
            flags: expected.flags,
            frameID: expected.frameID,
            captureTimestampMicros: expected.captureTimestampMicros,
            reserved: expected.reserved
        )
        let payload = hexData(vectors.video.payloadHex)
        let frame = try singleFrame(encodeVideo(header, annexB: payload))

        XCTAssertEqual(frame.type, MessageType.video.rawValue)
        XCTAssertEqual(frame.type, 3)
        XCTAssertEqual(frame.payload.prefix(18), hexData(vectors.video.headerHex).dropFirst())

        let decoded = try decodeVideo(frame.payload)
        XCTAssertEqual(decoded.0, header)
        XCTAssertEqual(decoded.1, payload)
    }

    func testPingRoundTrip() throws {
        let frame = try singleFrame(encodePing(timestamp: 123_456_789))
        XCTAssertEqual(frame.type, MessageType.ping.rawValue)
        XCTAssertEqual(try decodePing(frame.payload), 123_456_789)
    }
}