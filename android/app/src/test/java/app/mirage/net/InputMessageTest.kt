package app.mirage.net

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.File

class InputMessageTest {
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

    private fun framePayload(encoded: ByteArray): ByteArray =
        encoded.copyOfRange(5, encoded.size)

    private fun vectorSamples(): List<PointerSample> {
        val samples = vectors.getJSONObject("input").getJSONObject("fields").getJSONArray("samples")
        return (0 until samples.length()).map { index ->
            val item = samples.getJSONObject(index)
            PointerSample(
                kind = PointerKind.from(item.getInt("kind"))!!,
                pointerID = item.getInt("pointerID"),
                buttons = item.getInt("buttons"),
                x = item.getDouble("x").toFloat(),
                y = item.getDouble("y").toFloat(),
                pressure = item.getDouble("pressure").toFloat(),
                tiltX = item.getDouble("tiltX").toFloat(),
                tiltY = item.getDouble("tiltY").toFloat(),
                tsMicros = item.getLong("tsMicros")
            )
        }
    }

    @Test
    fun pointerMatchesSharedVectorAndRoundTrips() {
        val samples = vectorSamples()
        val encoded = InputMessages.encodePointer(samples)
        assertArrayEquals(hex(vectors.getJSONObject("input").getString("hex")), encoded)
        assertEquals(MessageType.INPUT.id, encoded[4].toInt() and 0xff)
        assertEquals(samples, InputMessages.decodePointer(framePayload(encoded)))
    }

    @Test
    fun pointerRejectsBadCountAndTruncation() {
        val sample = vectorSamples().first()
        assertThrows(IllegalArgumentException::class.java) {
            InputMessages.encodePointer(List(33) { sample })
        }
        assertThrows(ProtocolException::class.java) {
            InputMessages.decodePointer(byteArrayOf(0, 0))
        }
        assertThrows(ProtocolException::class.java) {
            InputMessages.decodePointer(byteArrayOf(0, 33))
        }
        assertThrows(ProtocolException::class.java) {
            InputMessages.decodePointer(byteArrayOf(0, 1, 1, 0))
        }
        val nan = byteArrayOf(0, 1, 1, 0, 0, 0, 0x7f, 0xc0.toByte(), 0, 0) + ByteArray(24)
        assertThrows(ProtocolException::class.java) {
            InputMessages.decodePointer(nan)
        }
        assertThrows(IllegalArgumentException::class.java) {
            InputMessages.encodePointer(listOf(sample.copy(x = Float.NaN)))
        }
        val badKind = byteArrayOf(0, 1, 99) + ByteArray(31)
        assertThrows(ProtocolException::class.java) {
            InputMessages.decodePointer(badKind)
        }
    }

    @Test
    fun keyMatchesSharedVectorAndRoundTrips() {
        val expected = vectors.getJSONObject("key").getJSONObject("fields")
        val key = KeyInput(
            action = KeyAction.from(expected.getInt("action"))!!,
            modifiers = expected.getInt("modifiers"),
            flags = expected.getInt("flags"),
            keycode = expected.getInt("keycode"),
            unicode = expected.getLong("unicode"),
            tsMicros = expected.getLong("tsMicros")
        )
        val encoded = InputMessages.encodeKey(key)
        assertArrayEquals(hex(vectors.getJSONObject("key").getString("hex")), encoded)
        assertEquals(key, InputMessages.decodeKey(framePayload(encoded)))
        assertThrows(ProtocolException::class.java) {
            InputMessages.decodeKey(byteArrayOf(9) + ByteArray(17))
        }
    }

    @Test
    fun textMatchesSharedVectorAndRoundTrips() {
        val expected = vectors.getJSONObject("text").getJSONObject("fields")
        val text = TextInput(expected.getString("text"), expected.getLong("tsMicros"))
        val encoded = InputMessages.encodeText(text)
        assertArrayEquals(hex(vectors.getJSONObject("text").getString("hex")), encoded)
        assertEquals(text, InputMessages.decodeText(framePayload(encoded)))

        assertThrows(ProtocolException::class.java) {
            InputMessages.encodeText(TextInput("", 1))
        }
        assertThrows(ProtocolException::class.java) {
            InputMessages.encodeText(TextInput("a".repeat(4097), 1))
        }
        assertThrows(ProtocolException::class.java) {
            InputMessages.decodeText(byteArrayOf(0, 0) + ByteArray(8))
        }
        assertThrows(ProtocolException::class.java) {
            InputMessages.decodeText(byteArrayOf(0, 1, 0xff.toByte(), 0, 0, 0, 0, 0, 0, 0, 0))
        }
    }

    @Test
    fun scrollMatchesSharedVectorAndRoundTrips() {
        val expected = vectors.getJSONObject("scroll").getJSONObject("fields")
        val scroll = ScrollInput(
            phase = ScrollPhase.from(expected.getInt("phase"))!!,
            flags = expected.getInt("flags"),
            dx = expected.getDouble("dx").toFloat(),
            dy = expected.getDouble("dy").toFloat(),
            tsMicros = expected.getLong("tsMicros")
        )
        val encoded = InputMessages.encodeScroll(scroll)
        assertArrayEquals(hex(vectors.getJSONObject("scroll").getString("hex")), encoded)
        assertEquals(scroll, InputMessages.decodeScroll(framePayload(encoded)))

        assertThrows(ProtocolException::class.java) {
            InputMessages.encodeScroll(scroll.copy(dx = Float.NaN))
        }
        assertThrows(ProtocolException::class.java) {
            InputMessages.encodeScroll(scroll.copy(dy = Float.POSITIVE_INFINITY))
        }
        val nanPayload = byteArrayOf(2, 0, 0, 0, 0x7f, 0xc0.toByte(), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        assertThrows(ProtocolException::class.java) {
            InputMessages.decodeScroll(nanPayload)
        }
    }

    @Test
    fun sessionConfigInputCapsIsOptionalTrailingByte() {
        val legacy = byteArrayOf(0x0a, 0x00, 0x06, 0x40, 60, 1, 0x01, 0x31, 0x2d, 0x00, 0)
        assertEquals(0, Messages.decodeSessionConfig(legacy).inputCaps)

        val config = SessionConfig(2560, 1600, 60, 1, 20_000_000, 0, 0b111111)
        val withCaps = byteArrayOf(0x0a, 0x00, 0x06, 0x40, 60, 1, 0x01, 0x31, 0x2d, 0x00, 0x00, 0b111111)
        assertEquals(config, Messages.decodeSessionConfig(withCaps))
    }
}