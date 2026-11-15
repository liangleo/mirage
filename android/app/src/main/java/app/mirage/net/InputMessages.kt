package app.mirage.net

import java.nio.ByteBuffer
import java.nio.ByteOrder

enum class PointerKind(val id: Int) {
    DOWN(1),
    MOVE(2),
    UP(3),
    CANCEL(4),
    HOVER(5);

    companion object {
        fun from(id: Int): PointerKind? = entries.firstOrNull { it.id == id }
    }
}

object InputModifiers {
    const val SHIFT = 1 shl 0
    const val CONTROL = 1 shl 1
    const val OPTION = 1 shl 2
    const val COMMAND = 1 shl 3
    const val CAPS_LOCK = 1 shl 4
    const val FN = 1 shl 5
}

enum class KeyAction(val id: Int) {
    DOWN(1),
    UP(2);

    companion object {
        fun from(id: Int): KeyAction? = entries.firstOrNull { it.id == id }
    }
}

enum class ScrollPhase(val id: Int) {
    BEGIN(1),
    CHANGE(2),
    END(3);

    companion object {
        fun from(id: Int): ScrollPhase? = entries.firstOrNull { it.id == id }
    }
}

object ScrollFlags {
    const val COMMAND = 1 shl 0
    const val PRECISE = 1 shl 1
}

data class PointerSample(
    val kind: PointerKind,
    val pointerID: Int,
    val buttons: Int,
    val x: Float,
    val y: Float,
    val pressure: Float,
    val tiltX: Float,
    val tiltY: Float,
    val tsMicros: Long
) {
    companion object {
        const val SIZE = 32
    }
}

data class KeyInput(
    val action: KeyAction,
    val modifiers: Int,
    val flags: Int,
    val keycode: Int,
    val unicode: Long,
    val tsMicros: Long
)

data class TextInput(val text: String, val tsMicros: Long)

data class ScrollInput(
    val phase: ScrollPhase,
    val flags: Int,
    val dx: Float,
    val dy: Float,
    val tsMicros: Long
)

sealed interface InputEvent {
    data class Pointer(val samples: List<PointerSample>) : InputEvent
    data class Key(val key: KeyInput) : InputEvent
    data class Text(val text: TextInput) : InputEvent
    data class Scroll(val scroll: ScrollInput) : InputEvent
    data object ReleaseAll : InputEvent
}

object InputMessages {
    const val MAX_SAMPLES = 32
    const val MAX_TEXT = 4096

    private val bigEndian: ByteOrder = ByteOrder.BIG_ENDIAN

    fun encodePointer(samples: List<PointerSample>): ByteArray {
        require(samples.isNotEmpty()) { "empty pointer samples" }
        require(samples.size <= MAX_SAMPLES) { "too many pointer samples" }
        require(samples.all { it.x.isFinite() && it.y.isFinite() && it.pressure.isFinite() && it.tiltX.isFinite() && it.tiltY.isFinite() }) {
            "non-finite pointer"
        }
        val buffer = ByteBuffer.allocate(2 + samples.size * PointerSample.SIZE).order(bigEndian)
        buffer.putShort(samples.size.toShort())
        for (sample in samples) {
            buffer.put(sample.kind.id.toByte())
            buffer.put(sample.pointerID.toByte())
            buffer.putShort(sample.buttons.toShort())
            buffer.putFloat(sample.x)
            buffer.putFloat(sample.y)
            buffer.putFloat(sample.pressure)
            buffer.putFloat(sample.tiltX)
            buffer.putFloat(sample.tiltY)
            buffer.putLong(sample.tsMicros)
        }
        return Messages.encodeFrame(MessageType.INPUT.id, buffer.array())
    }

    fun decodePointer(payload: ByteArray): List<PointerSample> {
        if (payload.size < 2) throw ProtocolException("malformed input")
        val buffer = ByteBuffer.wrap(payload).order(bigEndian)
        val count = buffer.getShort(0).toInt() and 0xffff
        if (count == 0 || count > MAX_SAMPLES) throw ProtocolException("bad input count $count")
        if (payload.size != 2 + count * PointerSample.SIZE) throw ProtocolException("malformed input")

        return (0 until count).map { index ->
            val base = 2 + index * PointerSample.SIZE
            val kind = PointerKind.from(buffer.get(base).toInt() and 0xff)
                ?: throw ProtocolException("bad pointer kind")
            val sample = PointerSample(
                kind = kind,
                pointerID = buffer.get(base + 1).toInt() and 0xff,
                buttons = buffer.getShort(base + 2).toInt() and 0xffff,
                x = buffer.getFloat(base + 4),
                y = buffer.getFloat(base + 8),
                pressure = buffer.getFloat(base + 12),
                tiltX = buffer.getFloat(base + 16),
                tiltY = buffer.getFloat(base + 20),
                tsMicros = buffer.getLong(base + 24)
            )
            if (!sample.x.isFinite() || !sample.y.isFinite() || !sample.pressure.isFinite() ||
                !sample.tiltX.isFinite() || !sample.tiltY.isFinite()
            ) {
                throw ProtocolException("non-finite pointer")
            }
            sample
        }
    }

    fun encodeKey(key: KeyInput): ByteArray {
        val payload = ByteBuffer.allocate(18)
            .order(bigEndian)
            .put(key.action.id.toByte())
            .put(key.modifiers.toByte())
            .put(key.flags.toByte())
            .put(0)
            .putShort(key.keycode.toShort())
            .putInt(key.unicode.toInt())
            .putLong(key.tsMicros)
            .array()
        return Messages.encodeFrame(MessageType.KEY.id, payload)
    }

    fun decodeKey(payload: ByteArray): KeyInput {
        if (payload.size != 18) throw ProtocolException("malformed key")
        val buffer = ByteBuffer.wrap(payload).order(bigEndian)
        val action = KeyAction.from(buffer.get(0).toInt() and 0xff)
            ?: throw ProtocolException("bad key action")
        return KeyInput(
            action = action,
            modifiers = buffer.get(1).toInt() and 0xff,
            flags = buffer.get(2).toInt() and 0xff,
            keycode = buffer.getShort(4).toInt() and 0xffff,
            unicode = buffer.getInt(6).toLong() and 0xffffffffL,
            tsMicros = buffer.getLong(10)
        )
    }

    fun encodeText(text: TextInput): ByteArray {
        val bytes = text.text.toByteArray(Charsets.UTF_8)
        if (bytes.isEmpty() || bytes.size > MAX_TEXT) throw ProtocolException("bad text length ${bytes.size}")
        val payload = ByteBuffer.allocate(2 + bytes.size + 8)
            .order(bigEndian)
            .putShort(bytes.size.toShort())
            .put(bytes)
            .putLong(text.tsMicros)
            .array()
        return Messages.encodeFrame(MessageType.TEXT.id, payload)
    }

    fun decodeText(payload: ByteArray): TextInput {
        if (payload.size < 10) throw ProtocolException("malformed text")
        val buffer = ByteBuffer.wrap(payload).order(bigEndian)
        val length = buffer.getShort(0).toInt() and 0xffff
        if (length !in 1..MAX_TEXT || payload.size != 2 + length + 8) {
            throw ProtocolException("malformed text")
        }
        val bytes = payload.copyOfRange(2, 2 + length)
        val text = try {
            Charsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(bytes)).toString()
        } catch (e: Exception) {
            throw ProtocolException("invalid utf-8 text")
        }
        return TextInput(text, buffer.getLong(2 + length))
    }

    fun encodeScroll(scroll: ScrollInput): ByteArray {
        if (!scroll.dx.isFinite() || !scroll.dy.isFinite()) throw ProtocolException("non-finite scroll")
        val payload = ByteBuffer.allocate(20)
            .order(bigEndian)
            .put(scroll.phase.id.toByte())
            .put(scroll.flags.toByte())
            .putShort(0)
            .putFloat(scroll.dx)
            .putFloat(scroll.dy)
            .putLong(scroll.tsMicros)
            .array()
        return Messages.encodeFrame(MessageType.SCROLL.id, payload)
    }

    fun decodeScroll(payload: ByteArray): ScrollInput {
        if (payload.size != 20) throw ProtocolException("malformed scroll")
        val buffer = ByteBuffer.wrap(payload).order(bigEndian)
        val phase = ScrollPhase.from(buffer.get(0).toInt() and 0xff)
            ?: throw ProtocolException("bad scroll phase")
        val dx = buffer.getFloat(4)
        val dy = buffer.getFloat(8)
        if (!dx.isFinite() || !dy.isFinite()) throw ProtocolException("non-finite scroll")
        return ScrollInput(
            phase = phase,
            flags = buffer.get(1).toInt() and 0xff,
            dx = dx,
            dy = dy,
            tsMicros = buffer.getLong(12)
        )
    }
}