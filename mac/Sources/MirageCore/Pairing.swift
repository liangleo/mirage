import Foundation

public struct PairingPayload: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let fingerprint: Data
    public let name: String
    public let deviceID: UUID

    public init(host: String, port: UInt16, fingerprint: Data, name: String, deviceID: UUID) {
        self.host = host
        self.port = port
        self.fingerprint = fingerprint
        self.name = name
        self.deviceID = deviceID
    }

    public var fingerprintHex: String {
        fingerprint.map { String(format: "%02x", $0) }.joined()
    }

    public func encodeURL() -> URL? {
        guard fingerprint.count == 32, port != 0 else { return nil }
        var components = URLComponents()
        components.scheme = "mirage"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "fp", value: fingerprintHex),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "id", value: deviceID.uuidString),
        ]
        return components.url
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "mirage",
              url.host?.lowercased() == "pair",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems
        else { return nil }

        let values = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        guard values["v"] == "1",
              let host = values["host"], !host.isEmpty,
              let portText = values["port"], let port = UInt16(portText), port != 0,
              let fingerprint = Self.decodeFingerprint(values["fp"]),
              let deviceID = values["id"].flatMap(UUID.init(uuidString:))
        else { return nil }

        self.init(
            host: host,
            port: port,
            fingerprint: fingerprint,
            name: values["name"] ?? host,
            deviceID: deviceID
        )
    }

    public static func decodeFingerprint(_ hex: String?) -> Data? {
        guard let hex, hex.count == 64 else { return nil }
        var data = Data(capacity: 32)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}