import XCTest
@testable import MirageCore
@testable import MirageHelper

final class UdpVideoSenderTests: XCTestCase {
    private let key = Data((0..<32).map(UInt8.init))
    private let noncePrefix = Data([1, 2, 3, 4])
    private var sent: [Data] = []

    private func makeSender() -> UdpVideoSender {
        let sender = UdpVideoSender(port: 0, key: key, noncePrefix: noncePrefix) { [weak self] data in
            self?.sent.append(data)
        }
        return sender
    }

    private func frame(id: UInt32, size: Int, key: Bool) -> EncodedFrame {
        EncodedFrame(
            header: VideoHeader(
                codec: 1,
                flags: key ? 1 : 0,
                frameID: id,
                captureTimestampMicros: 1,
                reserved: 0
            ),
            data: Data(repeating: 0xAB, count: size)
        )
    }

    func testFragmentsIntoSofEofAndKey() throws {
        let sender = makeSender()
        sender.send(frame: frame(id: 7, size: 2500, key: true))
        XCTAssertEqual(sent.count, 3)

        let datagrams = try sent.map(decodeUdpDatagram)
        XCTAssertEqual(datagrams.map(\.header.fragIndex), [0, 1, 2])
        XCTAssertEqual(Set(datagrams.map(\.header.fragCount)), [3])
        XCTAssertTrue(datagrams[0].header.isSOF)
        XCTAssertFalse(datagrams[1].header.isSOF)
        XCTAssertTrue(datagrams[2].header.isEOF)
        XCTAssertTrue(datagrams.allSatisfy(\.header.isKeyFrame))
        XCTAssertEqual(datagrams[1].header.payloadLength, 1200 + 16)
    }

    func testNackRetransmitsOnlyRequestedFragmentOnce() throws {
        let sender = makeSender()
        sender.send(frame: frame(id: 9, size: 2500, key: false))
        sent.removeAll()

        let nackHeader = UdpVideoHeader(
            seq: 100,
            frameID: 9,
            fragIndex: 0,
            fragCount: 1,
            flags: UdpFlags.nack,
            payloadLength: 1
        )
        sender.handleNack(UdpDatagram(header: nackHeader, payload: Data([0x02])))
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(try decodeUdpDatagram(sent[0]).header.fragIndex, 1)

        sender.handleNack(UdpDatagram(header: nackHeader, payload: Data([0x02])))
        XCTAssertEqual(sent.count, 1)
    }

    func testEmptyFrameIsIgnored() {
        let sender = makeSender()
        sender.send(frame: frame(id: 1, size: 0, key: false))
        XCTAssertTrue(sent.isEmpty)
    }

    func testCryptoRoundTripAndTamperDetection() throws {
        let chunk = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let header = UdpVideoHeader(
            seq: 42,
            frameID: 1,
            fragIndex: 0,
            fragCount: 1,
            flags: UdpFlags.sof | UdpFlags.eof,
            payloadLength: UInt16(chunk.count + 16)
        )
        let sealed = try udpSeal(chunk, header: header, key: key, noncePrefix: noncePrefix)
        XCTAssertEqual(sealed.count, chunk.count + 16)
        XCTAssertEqual(try udpOpen(sealed, header: header, key: key, noncePrefix: noncePrefix), chunk)

        var bytes = [UInt8](sealed)
        bytes[0] ^= 0xFF
        let tampered = Data(bytes)
        XCTAssertThrowsError(try udpOpen(tampered, header: header, key: key, noncePrefix: noncePrefix))

        XCTAssertThrowsError(try udpSeal(chunk, header: header, key: Data(count: 4), noncePrefix: noncePrefix))
    }
}