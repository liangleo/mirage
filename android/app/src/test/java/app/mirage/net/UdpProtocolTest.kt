package app.mirage.net

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class UdpProtocolTest {
    private val vectors: JSONObject by lazy {
        var directory = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (!File(directory, "protocol/vectors.json").exists()) {
            directory = directory.parentFile
                ?: error("could not find protocol/vectors.json above ${System.getProperty("user.dir")}")
        }
        JSONObject(File(directory, "protocol/vectors.json").readText()).getJSONObject("udp")
    }

    private fun hex(text: String): ByteArray =
        text.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    @Test
    fun datagramMatchesSharedVectorAndRoundTrips() {
        val vector = vectors.getJSONObject("datagram")
        val fields = vector.getJSONObject("fields")
        val header = UdpVideoHeader(
            seq = fields.getLong("seq"),
            frameID = fields.getLong("frameID"),
            fragIndex = fields.getInt("fragIndex"),
            fragCount = fields.getInt("fragCount"),
            flags = fields.getInt("flags"),
            reserved = fields.getInt("reserved"),
            payloadLength = fields.getInt("payloadLength")
        )
        val payload = hex(fields.getString("payloadHex"))
        val encoded = UdpProtocol.encode(UdpDatagram(header, payload))
        assertArrayEquals(hex(vector.getString("hex")), encoded)

        val decoded = UdpProtocol.decode(encoded)
        assertEquals(header, decoded.header)
        assertArrayEquals(payload, decoded.payload)
    }

    @Test
    fun nackMatchesSharedVector() {
        val vector = vectors.getJSONObject("nack")
        val fields = vector.getJSONObject("fields")
        val bitmap = hex(fields.getString("bitmapHex"))
        val encoded = UdpProtocol.encodeNack(
            seq = fields.getLong("seq"),
            frameID = fields.getLong("frameID"),
            bitmapStart = fields.getInt("bitmapStart"),
            bitmap = bitmap
        )
        assertArrayEquals(hex(vector.getString("hex")), encoded)

        val decoded = UdpProtocol.decode(encoded)
        assertTrue(decoded.header.isNack)
        assertEquals(fields.getInt("bitmapStart"), decoded.header.fragIndex)
        assertEquals(bitmap.size, decoded.header.fragCount)
        assertArrayEquals(bitmap, decoded.payload)
    }

    @Test
    fun feedbackMatchesSharedVector() {
        val vector = vectors.getJSONObject("feedback")
        val fields = vector.getJSONObject("fields")
        val feedback = Feedback(
            fpsX10 = fields.getInt("fpsX10"),
            decodeMS = fields.getInt("decodeMS"),
            droppedFrames = fields.getInt("droppedFrames"),
            queueDepth = fields.getInt("queueDepth"),
            rttMS = fields.getInt("rttMS"),
            lossPermille = fields.getInt("lossPermille"),
            recvBitrateBps = fields.getLong("recvBitrateBps"),
            arrivalDelayMS = fields.getLong("arrivalDelayMS"),
            timestampMicros = fields.getLong("timestampMicros")
        )
        val frame = decodeSingle(UdpProtocol.encodeFeedback(feedback))
        assertEquals(MessageType.FEEDBACK.id, frame.type)
        assertArrayEquals(hex(vector.getString("hex")), frame.payload)
        assertEquals(feedback, UdpProtocol.decodeFeedback(frame.payload))
    }

    @Test
    fun flagsRoundTrip() {
        val flags = UdpFlags.SOF or UdpFlags.EOF or UdpFlags.KEY
        val header = UdpVideoHeader(seq = 7, frameID = 3, fragIndex = 0, fragCount = 1, flags = flags, payloadLength = 2)
        val decoded = UdpProtocol.decode(UdpProtocol.encode(UdpDatagram(header, byteArrayOf(1, 2))))
        assertTrue(decoded.header.isSOF)
        assertTrue(decoded.header.isEOF)
        assertTrue(decoded.header.isKeyFrame)
        assertFalse(decoded.header.isNack)
    }

    @Test
    fun rejectsMalformedInput() {
        assertThrows(ProtocolException::class.java) {
            UdpProtocol.decode(ByteArray(8))
        }
        assertThrows(ProtocolException::class.java) {
            UdpProtocol.decode(
                byteArrayOf(
                    0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 4, 0xAA.toByte()
                )
            )
        }
        assertThrows(ProtocolException::class.java) {
            UdpProtocol.decode(
                byteArrayOf(
                    0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0
                )
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            val header = UdpVideoHeader(seq = 1, frameID = 1, fragIndex = 0, fragCount = 1, flags = 0, payloadLength = 1217)
            UdpProtocol.encode(UdpDatagram(header, ByteArray(1217)))
        }
        val sealed = UdpVideoHeader(seq = 1, frameID = 1, fragIndex = 0, fragCount = 1, flags = 0, payloadLength = 1216)
        assertEquals(16 + 1216, UdpProtocol.encode(UdpDatagram(sealed, ByteArray(1216))).size)
    }

    @Test
    fun udpConfigRoundTrips() {
        val config = UdpConfig(
            port = 7778,
            cipher = UdpCipher.AES_256_GCM,
            key = ByteArray(32) { it.toByte() },
            noncePrefix = byteArrayOf(1, 2, 3, 4),
            flags = 1
        )
        val frame = decodeSingle(UdpProtocol.encodeUdpConfig(config))
        assertEquals(MessageType.UDP_CONFIG.id, frame.type)
        val decoded = UdpProtocol.decodeUdpConfig(frame.payload)
        assertEquals(config.port, decoded.port)
        assertEquals(config.cipher, decoded.cipher)
        assertArrayEquals(config.key, decoded.key)
        assertArrayEquals(config.noncePrefix, decoded.noncePrefix)
        assertEquals(config.flags, decoded.flags)
        assertTrue(decoded.isEnabled)
    }

    private fun decodeSingle(encoded: ByteArray): Frame {
        val decoder = FrameDecoder()
        decoder.append(encoded)
        return requireNotNull(decoder.next())
    }
}