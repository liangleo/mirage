import Foundation

public func splitAVCC(_ data: Data) -> [Data] {
    var nalUnits: [Data] = []
    var offset = data.startIndex

    while offset + 4 <= data.endIndex {
        let length = Int(readUInt32BE(data, at: offset))
        guard length > 0, offset + 4 + length <= data.endIndex else { return [] }
        nalUnits.append(data.subdata(in: (offset + 4)..<(offset + 4 + length)))
        offset += 4 + length
    }

    guard offset == data.endIndex else { return [] }
    return nalUnits
}

public func annexB(nalUnits: [Data]) -> Data {
    var output = Data()
    for nalUnit in nalUnits {
        output.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        output.append(nalUnit)
    }
    return output
}

private func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
    (UInt32(data[offset]) << 24)
        | (UInt32(data[offset + 1]) << 16)
        | (UInt32(data[offset + 2]) << 8)
        | UInt32(data[offset + 3])
}