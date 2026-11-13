package app.mirage.net

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

class ProtocolTest {
    private val vectors: JSONObject by lazy {
        var directory = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (!File(directory, "protocol/vectors.json").exists()) {
            directory = directory.parentFile
                ?: error("could not find protocol/vectors.json above ${System.getProperty("user.dir")}")
        }
        JSONObject(File(directory, "protocol/vectors.json").readText())
    }

    private fun hex(text: String): ByteArray =
        text.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    private fun decodeSingle(encoded: ByteArray): Frame {
        val decoder = FrameDecoder()
        decoder.append(encoded)
        return requireNotNull(decoder.next())
    }

    @Test
    fun helloMatchesSharedVector() {
        val vector = vectors.getJSONObject("hello")
        val expected = vector.getJSONObject("fields")

        val frame = decodeSingle(hex(vector.getString("hex")))
        assertEquals(MessageType.HELLO.id, frame.type)

        val hello = Messages.decodeHello(frame.payload)
        assertEquals(expected.getInt("protoVersion"), hello.protoVersion)
        assertEquals(expected.getInt("clientVersion"), hello.clientVersion)
        assertArrayEquals(hex(expected.getString("deviceID")), hello.deviceID)
        assertEquals(expected.getInt("screenWidth"), hello.screenWidth)
        assertEquals(expected.getInt("screenHeight"), hello.screenHeight)
        assertEquals(expected.getInt("xdpi"), hello.xdpi)
        assertEquals(expected.getInt("ydpi"), hello.ydpi)
        assertEquals(expected.getInt("maxFPS"), hello.maxFPS)
        assertEquals(expected.getInt("codecs"), hello.codecs)
        assertEquals(expected.getInt("features"), hello.features)
        assertEquals(expected.getInt("rotation"), hello.rotation)
        assertEquals(expected.getString("name"), hello.name)

        assertArrayEquals(hex(vector.getString("hex")), Messages.encodeHello(hello))
    }

    @Test
    fun sessionConfigDecodes() {
        val payload = ByteBuffer.allocate(11).order(ByteOrder.BIG_ENDIAN)
            .putShort(2560)
            .putShort(1600)
            .put(60)
            .put(1)
            .putInt(20_000_000)
            .put(0)
            .array()

        val config = Messages.decodeSessionConfig(payload)
        assertEquals(2560, config.width)
        assertEquals(1600, config.height)
        assertEquals(60, config.fps)
        assertEquals(1, config.codec)
        assertEquals(20_000_000L, config.bitrate)
        assertEquals(0, config.rotation)
    }

    @Test
    fun videoMatchesSharedVectorAndRoundTrips() {
        val vector = vectors.getJSONObject("video")
        val fields = vector.getJSONObject("fields")
        val header = VideoHeader(
            codec = fields.getInt("codec"),
            flags = fields.getInt("flags"),
            frameID = fields.getLong("frameID"),
            captureTimestampMicros = fields.getLong("captureTimestampMicros"),
            reserved = fields.getLong("reserved")
        )
        val payload = hex(vector.getString("payloadHex"))

        val encoded = Messages.encodeVideo(header, payload)
        val expectedPrefix = hex(vector.getString("headerHex"))
        assertArrayEquals(expectedPrefix, encoded.copyOfRange(4, 4 + expectedPrefix.size))

        val frame = decodeSingle(encoded)
        assertEquals(MessageType.VIDEO.id, frame.type)
        val decoded = Messages.decodeVideo(frame.payload)
        assertEquals(header, decoded.header)
        assertArrayEquals(payload, decoded.annexB)
    }

    @Test
    fun pingRoundTrips() {
        val encoded = Messages.encodePing(123_456_789L)
        val frame = decodeSingle(encoded)
        assertEquals(MessageType.PING.id, frame.type)
        assertEquals(123_456_789L, Messages.decodePing(frame.payload))
    }

    @Test
    fun frameSplitAcrossChunks() {
        val frame = Frame(type = 3, payload = byteArrayOf(1, 2, 3, 4, 5))
        val encoded = Messages.encodeFrame(frame.type, frame.payload)
        val decoder = FrameDecoder()

        decoder.append(encoded.copyOfRange(0, 2))
        assertNull(decoder.next())

        decoder.append(encoded.copyOfRange(2, encoded.size - 1))
        assertNull(decoder.next())

        decoder.append(encoded.copyOfRange(encoded.size - 1, encoded.size))
        val decoded = decoder.next()!!
        assertEquals(frame.type, decoded.type)
        assertArrayEquals(frame.payload, decoded.payload)
        assertNull(decoder.next())
    }

    @Test
    fun twoFramesInOneChunk() {
        val first = Messages.encodeFrame(1, byteArrayOf(0xAA.toByte()))
        val second = Messages.encodeFrame(3, byteArrayOf(0xBB.toByte(), 0xCC.toByte()))
        val decoder = FrameDecoder()
        decoder.append(first + second)

        val a = decoder.next()!!
        val b = decoder.next()!!
        assertEquals(1, a.type)
        assertEquals(3, b.type)
        assertArrayEquals(byteArrayOf(0xBB.toByte(), 0xCC.toByte()), b.payload)
        assertNull(decoder.next())
    }

    @Test
    fun oversizedFrameThrows() {
        val header = ByteBuffer.allocate(5).order(ByteOrder.BIG_ENDIAN)
            .putInt(8 * 1024 * 1024 + 2)
            .put(3)
            .array()
        val decoder = FrameDecoder()
        decoder.append(header)

        assertThrows(ProtocolException::class.java) { decoder.next() }
    }

    @Test
    fun truncatedHeaderReturnsNull() {
        val decoder = FrameDecoder()
        decoder.append(byteArrayOf(0, 0, 0))
        assertNull(decoder.next())
    }

    @Test
    fun unknownTypeIsAcceptedByDecoder() {
        val encoded = Messages.encodeFrame(99, byteArrayOf(1))
        val frame = decodeSingle(encoded)
        assertEquals(99, frame.type)
    }
}