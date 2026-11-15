package app.mirage.net

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

enum class MessageType(val id: Int) {
    HELLO(1),
    SESSION_CONFIG(2),
    VIDEO(3),
    INPUT(4),
    FEEDBACK(5),
    CTRL(6),
    PING(7),
    BYE(8),
    KEY(9),
    TEXT(10),
    SCROLL(11),
    UDP_CONFIG(12)
}

object Ctrl {
    const val REQUEST_KEYFRAME = 1
    const val RELEASE_ALL = 2
    const val INPUT_ENABLED = 3
    const val INPUT_DISABLED = 4
    const val UDP_FAILED = 5
    const val UDP_READY = 6
}

data class Frame(val type: Int, val payload: ByteArray)

class ProtocolException(message: String) : Exception(message)

class FrameDecoder {
    private val buffer = ByteArrayOutputStream()

    fun append(data: ByteArray) {
        buffer.write(data)
    }

    fun next(): Frame? {
        val bytes = buffer.toByteArray()
        if (bytes.size < 4) return null

        val length = ByteBuffer.wrap(bytes, 0, 4).order(ByteOrder.BIG_ENDIAN).int
        if (length < 1) throw ProtocolException("malformed length $length")
        if (length > MAX_PAYLOAD + 1) throw ProtocolException("oversized frame $length")

        val total = 4 + length
        if (bytes.size < total) return null

        val type = bytes[4].toInt() and 0xff
        val payload = bytes.copyOfRange(5, total)

        buffer.reset()
        if (bytes.size > total) {
            buffer.write(bytes, total, bytes.size - total)
        }
        return Frame(type, payload)
    }

    companion object {
        const val MAX_PAYLOAD = 8 * 1024 * 1024
    }
}

data class Hello(
    val protoVersion: Int,
    val clientVersion: Int,
    val deviceID: ByteArray,
    val screenWidth: Int,
    val screenHeight: Int,
    val xdpi: Int,
    val ydpi: Int,
    val maxFPS: Int,
    val codecs: Int,
    val features: Int,
    val rotation: Int,
    val name: String
)

data class SessionConfig(
    val width: Int,
    val height: Int,
    val fps: Int,
    val codec: Int,
    val bitrate: Long,
    val rotation: Int,
    val inputCaps: Int = 0
)

data class VideoHeader(
    val codec: Int,
    val flags: Int,
    val frameID: Long,
    val captureTimestampMicros: Long,
    val reserved: Long
)

data class VideoFrame(val header: VideoHeader, val annexB: ByteArray)

object Messages {
    private val bigEndian: ByteOrder = ByteOrder.BIG_ENDIAN

    fun encodeFrame(type: Int, payload: ByteArray): ByteArray =
        ByteBuffer.allocate(4 + 1 + payload.size)
            .order(bigEndian)
            .putInt(1 + payload.size)
            .put(type.toByte())
            .put(payload)
            .array()

    fun encodeHello(hello: Hello): ByteArray {
        require(hello.deviceID.size == 16) { "deviceID must be 16 bytes" }
        val nameBytes = hello.name.toByteArray(Charsets.UTF_8)
        require(nameBytes.size <= 255) { "name must fit in 255 UTF-8 bytes" }

        val payload = ByteBuffer.allocate(32 + nameBytes.size)
            .order(bigEndian)
            .put(hello.protoVersion.toByte())
            .putShort(hello.clientVersion.toShort())
            .put(hello.deviceID)
            .putShort(hello.screenWidth.toShort())
            .putShort(hello.screenHeight.toShort())
            .putShort(hello.xdpi.toShort())
            .putShort(hello.ydpi.toShort())
            .put(hello.maxFPS.toByte())
            .put(hello.codecs.toByte())
            .put(hello.features.toByte())
            .put(hello.rotation.toByte())
            .put(nameBytes.size.toByte())
            .put(nameBytes)
            .array()

        return encodeFrame(MessageType.HELLO.id, payload)
    }

    fun decodeHello(payload: ByteArray): Hello {
        if (payload.size < 32) throw ProtocolException("malformed hello")
        val nameLength = payload[31].toInt() and 0xff
        if (payload.size < 32 + nameLength) throw ProtocolException("malformed hello name")

        val buffer = ByteBuffer.wrap(payload).order(bigEndian)
        return Hello(
            protoVersion = buffer.get(0).toInt() and 0xff,
            clientVersion = buffer.getShort(1).toInt() and 0xffff,
            deviceID = payload.copyOfRange(3, 19),
            screenWidth = buffer.getShort(19).toInt() and 0xffff,
            screenHeight = buffer.getShort(21).toInt() and 0xffff,
            xdpi = buffer.getShort(23).toInt() and 0xffff,
            ydpi = buffer.getShort(25).toInt() and 0xffff,
            maxFPS = buffer.get(27).toInt() and 0xff,
            codecs = buffer.get(28).toInt() and 0xff,
            features = buffer.get(29).toInt() and 0xff,
            rotation = buffer.get(30).toInt() and 0xff,
            name = String(payload, 32, nameLength, Charsets.UTF_8)
        )
    }

    fun decodeSessionConfig(payload: ByteArray): SessionConfig {
        if (payload.size < 11) throw ProtocolException("malformed session config")
        val buffer = ByteBuffer.wrap(payload).order(bigEndian)
        return SessionConfig(
            width = buffer.getShort(0).toInt() and 0xffff,
            height = buffer.getShort(2).toInt() and 0xffff,
            fps = buffer.get(4).toInt() and 0xff,
            codec = buffer.get(5).toInt() and 0xff,
            bitrate = buffer.getInt(6).toLong() and 0xffffffffL,
            rotation = buffer.get(10).toInt() and 0xff,
            inputCaps = if (payload.size >= 12) payload[11].toInt() and 0xff else 0
        )
    }

    fun encodeVideo(header: VideoHeader, annexB: ByteArray): ByteArray {
        val payload = ByteBuffer.allocate(18 + annexB.size)
            .order(bigEndian)
            .put(header.codec.toByte())
            .put(header.flags.toByte())
            .putInt(header.frameID.toInt())
            .putLong(header.captureTimestampMicros)
            .putInt(header.reserved.toInt())
            .put(annexB)
            .array()
        return encodeFrame(MessageType.VIDEO.id, payload)
    }

    fun decodeVideo(payload: ByteArray): VideoFrame {
        if (payload.size < 18) throw ProtocolException("malformed video frame")
        val buffer = ByteBuffer.wrap(payload).order(bigEndian)
        val header = VideoHeader(
            codec = buffer.get(0).toInt() and 0xff,
            flags = buffer.get(1).toInt() and 0xff,
            frameID = buffer.getInt(2).toLong() and 0xffffffffL,
            captureTimestampMicros = buffer.getLong(6),
            reserved = buffer.getInt(14).toLong() and 0xffffffffL
        )
        return VideoFrame(header, payload.copyOfRange(18, payload.size))
    }

    fun encodePing(timestamp: Long): ByteArray {
        val payload = ByteBuffer.allocate(8).order(bigEndian).putLong(timestamp).array()
        return encodeFrame(MessageType.PING.id, payload)
    }

    fun decodePing(payload: ByteArray): Long {
        if (payload.size < 8) throw ProtocolException("malformed ping")
        return ByteBuffer.wrap(payload).order(bigEndian).long
    }
}