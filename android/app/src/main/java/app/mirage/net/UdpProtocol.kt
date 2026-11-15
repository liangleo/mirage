package app.mirage.net

import java.nio.ByteBuffer
import java.nio.ByteOrder

object UdpFlags {
    const val SOF = 1 shl 0
    const val EOF = 1 shl 1
    const val KEY = 1 shl 2
    const val NACK = 1 shl 3
    const val HELLO = 1 shl 4
    const val PARITY = 1 shl 5
}

enum class UdpCipher(val id: Int) {
    AES_256_GCM(1),
    CHACHA20_POLY1305(2);

    companion object {
        fun fromId(id: Int): UdpCipher? = entries.firstOrNull { it.id == id }
    }
}

data class UdpVideoHeader(
    val seq: Long,
    val frameID: Long,
    val fragIndex: Int,
    val fragCount: Int,
    val flags: Int,
    val reserved: Int = 0,
    val payloadLength: Int
) {
    val isNack: Boolean get() = flags and UdpFlags.NACK != 0
    val isHello: Boolean get() = flags and UdpFlags.HELLO != 0
    val isKeyFrame: Boolean get() = flags and UdpFlags.KEY != 0
    val isSOF: Boolean get() = flags and UdpFlags.SOF != 0
    val isEOF: Boolean get() = flags and UdpFlags.EOF != 0

    companion object {
        const val SIZE = 16
        const val MAX_PAYLOAD = 1200
        const val MAX_DATAGRAM_PAYLOAD = MAX_PAYLOAD + 16
    }
}

data class UdpDatagram(val header: UdpVideoHeader, val payload: ByteArray)

data class Feedback(
    val fpsX10: Int,
    val decodeMS: Int,
    val droppedFrames: Int,
    val queueDepth: Int,
    val rttMS: Int,
    val lossPermille: Int,
    val recvBitrateBps: Long,
    val arrivalDelayMS: Long,
    val timestampMicros: Long
) {
    companion object {
        const val SIZE = 28
    }
}

data class UdpConfig(
    val port: Int,
    val cipher: UdpCipher,
    val key: ByteArray,
    val noncePrefix: ByteArray,
    val flags: Int
) {
    val isEnabled: Boolean get() = flags and 1 != 0
}

object UdpProtocol {
    private val bigEndian: ByteOrder = ByteOrder.BIG_ENDIAN

    fun encode(datagram: UdpDatagram): ByteArray {
        val payload = datagram.payload
        require(payload.size <= UdpVideoHeader.MAX_DATAGRAM_PAYLOAD) { "udp payload too large" }
        require(datagram.header.payloadLength == payload.size) { "payload length mismatch" }

        return ByteBuffer.allocate(UdpVideoHeader.SIZE + payload.size)
            .order(bigEndian)
            .putInt(datagram.header.seq.toInt())
            .putInt(datagram.header.frameID.toInt())
            .putShort(datagram.header.fragIndex.toShort())
            .putShort(datagram.header.fragCount.toShort())
            .put(datagram.header.flags.toByte())
            .put(datagram.header.reserved.toByte())
            .putShort(datagram.header.payloadLength.toShort())
            .put(payload)
            .array()
    }

    fun decode(data: ByteArray): UdpDatagram {
        if (data.size < UdpVideoHeader.SIZE) throw ProtocolException("udp header too short")
        val buffer = ByteBuffer.wrap(data).order(bigEndian)
        val payloadLength = buffer.getShort(14).toInt() and 0xffff
        if (payloadLength > UdpVideoHeader.MAX_DATAGRAM_PAYLOAD) throw ProtocolException("udp payload too large")
        if (data.size != UdpVideoHeader.SIZE + payloadLength) throw ProtocolException("udp length mismatch")

        val header = UdpVideoHeader(
            seq = buffer.getInt(0).toLong() and 0xffffffffL,
            frameID = buffer.getInt(4).toLong() and 0xffffffffL,
            fragIndex = buffer.getShort(8).toInt() and 0xffff,
            fragCount = buffer.getShort(10).toInt() and 0xffff,
            flags = buffer.get(12).toInt() and 0xff,
            reserved = buffer.get(13).toInt() and 0xff,
            payloadLength = payloadLength
        )
        if (header.fragCount == 0) throw ProtocolException("udp frag count is zero")
        if (header.isNack) {
            if (payloadLength != header.fragCount) throw ProtocolException("nack bitmap length mismatch")
        } else if (header.fragIndex >= header.fragCount) {
            throw ProtocolException("udp frag index out of range")
        }
        return UdpDatagram(header, data.copyOfRange(UdpVideoHeader.SIZE, data.size))
    }

    fun encodeNack(seq: Long, frameID: Long, bitmapStart: Int, bitmap: ByteArray): ByteArray {
        require(bitmap.isNotEmpty()) { "empty nack bitmap" }
        val header = UdpVideoHeader(
            seq = seq,
            frameID = frameID,
            fragIndex = bitmapStart,
            fragCount = bitmap.size,
            flags = UdpFlags.NACK,
            payloadLength = bitmap.size
        )
        return encode(UdpDatagram(header, bitmap))
    }

    fun encodeFeedback(feedback: Feedback): ByteArray {
        val payload = ByteBuffer.allocate(Feedback.SIZE)
            .order(bigEndian)
            .putShort(feedback.fpsX10.toShort())
            .putShort(feedback.decodeMS.toShort())
            .putShort(feedback.droppedFrames.toShort())
            .putShort(feedback.queueDepth.toShort())
            .putShort(feedback.rttMS.toShort())
            .putShort(feedback.lossPermille.toShort())
            .putInt(feedback.recvBitrateBps.toInt())
            .putInt(feedback.arrivalDelayMS.toInt())
            .putLong(feedback.timestampMicros)
            .array()
        return Messages.encodeFrame(MessageType.FEEDBACK.id, payload)
    }

    fun decodeFeedback(payload: ByteArray): Feedback {
        if (payload.size < Feedback.SIZE) throw ProtocolException("malformed feedback")
        val buffer = ByteBuffer.wrap(payload).order(bigEndian)
        return Feedback(
            fpsX10 = buffer.getShort(0).toInt() and 0xffff,
            decodeMS = buffer.getShort(2).toInt() and 0xffff,
            droppedFrames = buffer.getShort(4).toInt() and 0xffff,
            queueDepth = buffer.getShort(6).toInt() and 0xffff,
            rttMS = buffer.getShort(8).toInt() and 0xffff,
            lossPermille = buffer.getShort(10).toInt() and 0xffff,
            recvBitrateBps = buffer.getInt(12).toLong() and 0xffffffffL,
            arrivalDelayMS = buffer.getInt(16).toLong() and 0xffffffffL,
            timestampMicros = buffer.getLong(20)
        )
    }

    fun encodeUdpConfig(config: UdpConfig): ByteArray {
        require(config.key.size == 32) { "udp key must be 32 bytes" }
        require(config.noncePrefix.size == 4) { "nonce prefix must be 4 bytes" }
        val payload = ByteBuffer.allocate(40)
            .order(bigEndian)
            .putShort(config.port.toShort())
            .put(config.cipher.id.toByte())
            .put(config.key)
            .put(config.noncePrefix)
            .put(config.flags.toByte())
            .array()
        return Messages.encodeFrame(MessageType.UDP_CONFIG.id, payload)
    }

    fun decodeUdpConfig(payload: ByteArray): UdpConfig {
        if (payload.size < 40) throw ProtocolException("malformed udp config")
        val cipher = UdpCipher.fromId(payload[2].toInt() and 0xff)
            ?: throw ProtocolException("unknown udp cipher")
        return UdpConfig(
            port = ByteBuffer.wrap(payload, 0, 2).order(bigEndian).short.toInt() and 0xffff,
            cipher = cipher,
            key = payload.copyOfRange(3, 35),
            noncePrefix = payload.copyOfRange(35, 39),
            flags = payload[39].toInt() and 0xff
        )
    }
}