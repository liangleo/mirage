package app.mirage.net

import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

object UdpCrypto {
    const val TAG_BYTES = 16

    fun open(
        payload: ByteArray,
        headerBytes: ByteArray,
        header: UdpVideoHeader,
        key: ByteArray,
        noncePrefix: ByteArray,
        cipher: UdpCipher
    ): ByteArray {
        require(cipher == UdpCipher.AES_256_GCM) { "unsupported udp cipher $cipher" }
        require(key.size == 32) { "udp key must be 32 bytes" }
        require(noncePrefix.size == 4) { "nonce prefix must be 4 bytes" }
        require(payload.size > TAG_BYTES) { "udp payload too short" }

        val nonce = ByteArray(12)
        System.arraycopy(noncePrefix, 0, nonce, 0, 4)
        var seq = header.seq
        for (i in 11 downTo 4) {
            nonce[i] = (seq and 0xff).toByte()
            seq = seq ushr 8
        }

        val decrypt = Cipher.getInstance("AES/GCM/NoPadding")
        decrypt.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BYTES * 8, nonce))
        decrypt.updateAAD(headerBytes)
        return decrypt.doFinal(payload)
    }
}