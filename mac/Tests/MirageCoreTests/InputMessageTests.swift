import XCTest
@testable import MirageCore

final class InputMessageTests: XCTestCase {
    private struct Vectors: Decodable {
        struct SampleFields: Decodable {
            let kind: UInt8
            let pointerID: UInt8
            let buttons: UInt16
            let x: Float
            let y: Float
            let pressure: Float
            let tiltX: Float
            let tiltY: Float
            let tsMicros: UInt64
        }
        struct InputVector: Decodable {
            let hex: String
            let fields: InputFields
        }
        struct InputFields: Decodable {
            let count: Int
            let samples: [SampleFields]
        }
        struct KeyVector: Decodable {
            let hex: String
            let fields: KeyFields
        }
        struct KeyFields: Decodable {
            let action: UInt8
            let modifiers: UInt8
            let flags: UInt8
            let keycode: UInt16
            let unicode: UInt32
            let tsMicros: UInt64
        }
        struct TextVector: Decodable {
            let hex: String
            let fields: TextFields
        }
        struct TextFields: Decodable {
            let text: String
            let tsMicros: UInt64
        }
        struct ScrollVector: Decodable {
            let hex: String
            let fields: ScrollFields
        }
        struct ScrollFields: Decodable {
            let phase: UInt8
            let flags: UInt8
            let dx: Float
            let dy: Float
            let tsMicros: UInt64
        }

        let input: InputVector
        let key: KeyVector
        let text: TextVector
        let scroll: ScrollVector
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

    private func singleFrame(_ encoded: Data) throws -> Frame {
        var decoder = FrameDecoder()
        decoder.append(encoded)
        return try XCTUnwrap(try decoder.next())
    }

    private var vectorSamples: [PointerSample] {
        vectors.input.fields.samples.map {
            PointerSample(
                kind: PointerKind(rawValue: $0.kind)!,
                pointerID: $0.pointerID,
                buttons: $0.buttons,
                x: $0.x,
                y: $0.y,
                pressure: $0.pressure,
                tiltX: $0.tiltX,
                tiltY: $0.tiltY,
                tsMicros: $0.tsMicros
            )
        }
    }

    func testPointerMatchesSharedVectorAndRoundTrips() throws {
        let frame = try singleFrame(encodeFrame(try encodeInput(vectorSamples)))
        XCTAssertEqual(frame.type, MessageType.input.rawValue)
        XCTAssertEqual(encodeFrame(frame), hexData(vectors.input.hex))
        XCTAssertEqual(try decodeInput(frame.payload), vectorSamples)
    }

    func testPointerRejectsBadCountAndTruncation() throws {
        XCTAssertThrowsError(try encodeInput([]))
        XCTAssertThrowsError(try encodeInput(Array(repeating: vectorSamples[0], count: 33)))

        XCTAssertThrowsError(try decodeInput(Data([0, 0])))
        XCTAssertThrowsError(try decodeInput(Data([0, 33])))
        var short = Data([0, 1, 1, 0])
        short.append(contentsOf: Array(repeating: 0, count: 29))
        XCTAssertThrowsError(try decodeInput(short))

        var nan = Data([0, 1, 1, 0, 0, 0])
        nan.append(Data([0x7f, 0xc0, 0, 0]))
        nan.append(Data(repeating: 0, count: 24))
        XCTAssertThrowsError(try decodeInput(nan))

        var badKind = Data([0, 1, 99])
        badKind.append(contentsOf: Array(repeating: 0, count: 31))
        XCTAssertThrowsError(try decodeInput(badKind))
    }

    func testKeyMatchesSharedVectorAndRoundTrips() throws {
        let expected = vectors.key.fields
        let key = KeyInput(
            action: KeyAction(rawValue: expected.action)!,
            modifiers: expected.modifiers,
            flags: expected.flags,
            keycode: expected.keycode,
            unicode: expected.unicode,
            tsMicros: expected.tsMicros
        )
        let frame = try singleFrame(encodeFrame(encodeKey(key)))
        XCTAssertEqual(frame.type, MessageType.key.rawValue)
        XCTAssertEqual(encodeFrame(frame), hexData(vectors.key.hex))
        XCTAssertEqual(try decodeKey(frame.payload), key)
        XCTAssertThrowsError(try decodeKey(Data([9] + Array(repeating: 0, count: 17))))
    }

    func testTextMatchesSharedVectorAndRoundTrips() throws {
        let expected = vectors.text.fields
        let text = TextInput(text: expected.text, tsMicros: expected.tsMicros)
        let frame = try singleFrame(encodeFrame(try encodeText(text)))
        XCTAssertEqual(frame.type, MessageType.text.rawValue)
        XCTAssertEqual(encodeFrame(frame), hexData(vectors.text.hex))
        XCTAssertEqual(try decodeText(frame.payload), text)

        XCTAssertThrowsError(try encodeText(TextInput(text: "", tsMicros: 1)))
        XCTAssertThrowsError(try encodeText(TextInput(text: String(repeating: "a", count: 4097), tsMicros: 1)))
        XCTAssertThrowsError(try decodeText(Data([0, 0]) + Data(repeating: 0, count: 8)))
        XCTAssertThrowsError(
            try decodeText(Data([0, 1, 0xff, 0, 0, 0, 0, 0, 0, 0, 0]))
        )
    }

    func testScrollMatchesSharedVectorAndRoundTrips() throws {
        let expected = vectors.scroll.fields
        let scroll = ScrollInput(
            phase: ScrollPhase(rawValue: expected.phase)!,
            flags: expected.flags,
            dx: expected.dx,
            dy: expected.dy,
            tsMicros: expected.tsMicros
        )
        let frame = try singleFrame(encodeFrame(try encodeScroll(scroll)))
        XCTAssertEqual(frame.type, MessageType.scroll.rawValue)
        XCTAssertEqual(encodeFrame(frame), hexData(vectors.scroll.hex))
        XCTAssertEqual(try decodeScroll(frame.payload), scroll)

        let nan = ScrollInput(phase: .change, flags: 0, dx: .nan, dy: 0, tsMicros: 1)
        XCTAssertThrowsError(try encodeScroll(nan))
        var nanPayload = Data(encodeFrame(try encodeScroll(scroll)).dropFirst(5))
        nanPayload.replaceSubrange(4..<8, with: Data([0x7f, 0xc0, 0, 0]))
        XCTAssertThrowsError(try decodeScroll(nanPayload))
    }

    func testSessionConfigInputCapsIsOptionalTrailingByte() throws {
        let legacy = Data([0x0a, 0x00, 0x06, 0x40, 60, 1, 0x01, 0x31, 0x2d, 0x00, 0])
        XCTAssertEqual(try decodeSessionConfig(legacy).inputCaps, 0)

        let config = SessionConfig(
            width: 2560,
            height: 1600,
            fps: 60,
            codec: 1,
            bitrate: 20_000_000,
            rotation: 0,
            inputCaps: 0b111111
        )
        let frame = try singleFrame(encodeSessionConfig(config))
        XCTAssertEqual(frame.payload.count, 12)
        XCTAssertEqual(try decodeSessionConfig(frame.payload), config)
    }
}