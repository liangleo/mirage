import Foundation
import Security
import CryptoKit

public enum TLSIdentityError: Error {
    case keyGeneration(OSStatus)
    case certificateCreation
    case identityCreation(OSStatus)
    case keychain(OSStatus)
}

public struct TLSIdentity {
    public let identity: SecIdentity
    public let certificateDER: Data

    public var fingerprint: Data {
        Data(SHA256.hash(data: certificateDER))
    }

    private static let label = "Mirage TLS"
    private static let tag = Data("app.mirage.tls.v4".utf8)

    public static func loadOrCreate() throws -> TLSIdentity {
        if let key = loadPrivateKey(),
           let certificateData = try? Data(contentsOf: certificateURL),
           let certificate = SecCertificateCreateWithData(nil, certificateData as CFData),
           let identity = SecIdentityCreate(nil, certificate, key) {
            return TLSIdentity(identity: identity, certificateDER: certificateData)
        }
        return try create()
    }

    private static var certificateURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mirage", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("tls-cert-v4.der")
    }

    // The private key lives in a 0600 file rather than the keychain: a
    // keychain key's default ACL only trusts the binary that created it, so
    // every rebuilt helper (and the menu app) would block on an invisible
    // authorization prompt whenever the TLS handshake signs.
    private static var privateKeyURL: URL {
        certificateURL.deletingLastPathComponent().appendingPathComponent("tls-key-v4.bin")
    }

    private static func loadPrivateKey() -> SecKey? {
        guard let data = try? Data(contentsOf: privateKeyURL) else { return nil }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256,
        ]
        return SecKeyCreateWithData(data as CFData, attributes as CFDictionary, nil)
    }

    private static func create() throws -> TLSIdentity {
        SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag] as CFDictionary)
        SecItemDelete([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label] as CFDictionary)

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw TLSIdentityError.keyGeneration(errSecParam)
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?,
              let privateData = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else {
            throw TLSIdentityError.keyGeneration(errSecParam)
        }

        let tbs = makeTBS(publicKeyPoint: publicData)
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            tbs as CFData,
            &error
        ) as Data? else {
            throw TLSIdentityError.keyGeneration(errSecParam)
        }

        let algorithm = derSequence(derOID([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]))
        let certificateDER = derSequence(tbs, algorithm, derBitString(signature))
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
            throw TLSIdentityError.certificateCreation
        }

        let addCertificate: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
        ]
        SecItemAdd(addCertificate as CFDictionary, nil)
        try privateData.write(to: privateKeyURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: privateKeyURL.path
        )
        try certificateDER.write(to: certificateURL, options: .atomic)
        guard let identity = SecIdentityCreate(nil, certificate, privateKey) else {
            throw TLSIdentityError.identityCreation(errSecParam)
        }
        return TLSIdentity(identity: identity, certificateDER: certificateDER)
    }

    private static func makeTBS(publicKeyPoint: Data) -> Data {
        let name = derSequence(derSet(derSequence(derOID([0x55, 0x04, 0x03]), derUTF8("Mirage"))))
        let algorithm = derSequence(derOID([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]))
        let spki = derSequence(
            derSequence(derOID([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]), derOID([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])),
            derBitString(publicKeyPoint)
        )
        var serial = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
        serial[0] &= 0x7f
        if serial == Data(repeating: 0, count: 8) { serial[7] = 1 }
        let validity = derSequence(
            derUTCTime(Date().addingTimeInterval(-86_400)),
            derUTCTime(Date().addingTimeInterval(10 * 365 * 86_400))
        )
        let basicConstraints = derSequence(
            derOID([0x55, 0x1D, 0x13]),
            derBoolean(true),
            derOctetString(derSequence(derBoolean(false)))
        )
        let keyUsage = derSequence(
            derOID([0x55, 0x1D, 0x0F]),
            derBoolean(true),
            derOctetString(derItem(0x03, Data([7, 0x80])))
        )
        let extendedKeyUsage = derSequence(
            derOID([0x55, 0x1D, 0x25]),
            derOctetString(derSequence(derOID([0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01])))
        )
        let subjectAltName = derSequence(
            derOID([0x55, 0x1D, 0x11]),
            derOctetString(derSequence(derItem(0x82, Data("mirage.local".utf8))))
        )
        let extensions = derItem(0xA3, derSequence(basicConstraints, keyUsage, extendedKeyUsage, subjectAltName))
        return derSequence(
            derItem(0xA0, derInteger([2])),
            derInteger([UInt8](serial)),
            algorithm,
            name,
            validity,
            name,
            spki,
            extensions
        )
    }
}

private func derLength(_ count: Int) -> Data {
    if count < 0x80 { return Data([UInt8(count)]) }
    var bytes: [UInt8] = []
    var value = count
    while value > 0 {
        bytes.insert(UInt8(value & 0xff), at: 0)
        value >>= 8
    }
    return Data([0x80 | UInt8(bytes.count)] + bytes)
}

private func derItem(_ tag: UInt8, _ content: Data) -> Data {
    Data([tag]) + derLength(content.count) + content
}

private func derSequence(_ items: Data...) -> Data {
    derItem(0x30, items.reduce(Data(), +))
}

private func derSet(_ items: Data...) -> Data {
    derItem(0x31, items.reduce(Data(), +))
}

private func derInteger(_ bytes: [UInt8]) -> Data {
    var value = bytes
    while value.count > 1 && value[0] == 0 { value.removeFirst() }
    if let first = value.first, first & 0x80 != 0 {
        value.insert(0, at: 0)
    }
    return derItem(0x02, Data(value))
}

private func derOID(_ bytes: [UInt8]) -> Data {
    derItem(0x06, Data(bytes))
}

private func derUTF8(_ string: String) -> Data {
    derItem(0x0C, Data(string.utf8))
}

private func derUTCTime(_ date: Date) -> Data {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyMMddHHmmss'Z'"
    return derItem(0x17, Data(formatter.string(from: date).utf8))
}

private func derBitString(_ data: Data) -> Data {
    derItem(0x03, Data([0]) + data)
}

private func derBoolean(_ value: Bool) -> Data {
    derItem(0x01, Data([value ? 0xFF : 0x00]))
}

private func derOctetString(_ data: Data) -> Data {
    derItem(0x04, data)
}