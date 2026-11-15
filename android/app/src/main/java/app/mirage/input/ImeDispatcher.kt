package app.mirage.input

import app.mirage.net.InputEvent
import app.mirage.net.TextInput

/** Pure keyboard/IME event dispatch, testable without the Android framework. */
class ImeDispatcher(private val forward: (List<InputEvent>) -> Unit) {
    var enabled: Boolean = true

    fun commit(text: CharSequence) {
        if (!enabled) return
        val value = text.toString()
        if (value.isEmpty()) return
        forward(listOf(InputEvent.Text(TextInput(value, nowMicros()))))
    }

    fun delete(beforeLength: Int) {
        if (!enabled || beforeLength <= 0) return
        repeat(beforeLength) { keyDownUp(KEYCODE_DEL, 0, unicode = 0) }
    }

    fun keyEvent(action: Int, keyCode: Int, metaState: Int, repeat: Boolean = false, fromIme: Boolean = false) {
        if (!enabled) return
        val unicode = KeyMapping.unicodeFor(keyCode, metaState)
        val key = KeyMapping.key(
            keyCode = keyCode,
            modifiers = KeyMapping.modifiers(metaState),
            unicode = unicode,
            down = action == ACTION_DOWN,
            repeat = repeat,
            fromIme = fromIme,
            tsMicros = nowMicros()
        )
        forward(listOf(InputEvent.Key(key)))
    }

    fun keyDownUp(keyCode: Int, metaState: Int, unicode: Int = -1) {
        if (!enabled) return
        val resolved = if (unicode >= 0) unicode else KeyMapping.unicodeFor(keyCode, metaState)
        val modifiers = KeyMapping.modifiers(metaState)
        val now = nowMicros()
        forward(
            listOf(
                InputEvent.Key(KeyMapping.key(keyCode, modifiers, resolved, true, false, false, now)),
                InputEvent.Key(KeyMapping.key(keyCode, modifiers, resolved, false, false, false, now))
            )
        )
    }

    fun releaseAll() {
        forward(listOf(InputEvent.ReleaseAll))
    }

    private fun nowMicros(): Long = System.nanoTime() / 1000

    companion object {
        const val ACTION_DOWN = 0
        const val ACTION_UP = 1
        const val KEYCODE_DEL = 67
        const val KEYCODE_ENTER = 66
    }
}