import XCTest
@testable import MirageCore

final class LogTailTests: XCTestCase {
    func testReadsOnlyNewBytesAfterTruncation() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirage-logtail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }

        try "one\n".write(to: url, atomically: true, encoding: .utf8)
        var tail = LogTail()
        XCTAssertEqual(tail.readNew(from: url), "one\n")
        XCTAssertEqual(tail.readNew(from: url), "")

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("two\n".utf8))
        try handle.close()
        XCTAssertEqual(tail.readNew(from: url), "two\n")

        try "reset\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(tail.readNew(from: url), "reset\n")
    }
}