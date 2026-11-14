import Foundation

public struct LogTail: Sendable {
    private var offset: UInt64 = 0

    public init() {}

    public mutating func readNew(from url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return "" }
        if size < offset {
            offset = 0
        }
        guard size > offset else { return "" }
        guard (try? handle.seek(toOffset: offset)) != nil else { return "" }
        guard let data = try? handle.readToEnd(),
              let chunk = String(data: data, encoding: .utf8) else { return "" }

        offset = size
        return chunk
    }
}