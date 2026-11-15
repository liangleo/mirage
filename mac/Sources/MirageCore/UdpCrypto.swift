import Foundation
import CryptoKit

public enum UdpCryptoError: Error, Equatable {
    case badKey
    case badPayload
    case authenticationFailed
}

public func udpNonce(prefix: Data, seq: UInt32) -> Data {
    var nonce = prefix
    nonce.appendUInt64BE(UInt64(seq))
    return nonce
}

public func udpSeal(
    _ plaintext: Data,
    header: UdpVideoHeader,
    key: Data,
    noncePrefix: Data
) throws -> Data {
    guard key.count == 32, noncePrefix.count == 4 else { throw UdpCryptoError.badKey }
    let nonce = try AES.GCM.Nonce(data: udpNonce(prefix: noncePrefix, seq: header.seq))
    let sealed = try AES.GCM.seal(
        plaintext,
        using: SymmetricKey(data: key),
        nonce: nonce,
        authenticating: encodeUdpHeader(header)
    )
    return sealed.ciphertext + sealed.tag
}

public func udpOpen(
    _ sealedData: Data,
    header: UdpVideoHeader,
    key: Data,
    noncePrefix: Data
) throws -> Data {
    guard key.count == 32, noncePrefix.count == 4 else { throw UdpCryptoError.badKey }
    guard sealedData.count >= 16 else { throw UdpCryptoError.badPayload }
    let ciphertext = sealedData.prefix(sealedData.count - 16)
    let tag = sealedData.suffix(16)
    let nonce = try AES.GCM.Nonce(data: udpNonce(prefix: noncePrefix, seq: header.seq))
    do {
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(
            box,
            using: SymmetricKey(data: key),
            authenticating: encodeUdpHeader(header)
        )
    } catch {
        throw UdpCryptoError.authenticationFailed
    }
}