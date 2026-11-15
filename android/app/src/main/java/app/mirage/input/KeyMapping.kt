package app.mirage.input

import app.mirage.net.InputModifiers
import app.mirage.net.KeyAction
import app.mirage.net.KeyInput

object KeyMapping {
    const val META_SHIFT = 0x1
    const val META_ALT = 0x2
    const val META_CTRL = 0x1000
    const val META_META = 0x10000
    const val META_CAPS_LOCK = 0x00100000
    const val META_FUNCTION = 0x8

    fun modifiers(metaState: Int): Int {
        var flags = 0
        if (metaState and META_SHIFT != 0) flags = flags or InputModifiers.SHIFT
        if (metaState and META_CTRL != 0) flags = flags or InputModifiers.CONTROL
        if (metaState and META_ALT != 0) flags = flags or InputModifiers.OPTION
        if (metaState and META_META != 0) flags = flags or InputModifiers.COMMAND
        if (metaState and META_CAPS_LOCK != 0) flags = flags or InputModifiers.CAPS_LOCK
        if (metaState and META_FUNCTION != 0) flags = flags or InputModifiers.FN
        return flags
    }

    fun key(keyCode: Int, modifiers: Int, unicode: Int, down: Boolean, repeat: Boolean, fromIme: Boolean, tsMicros: Long): KeyInput =
        KeyInput(
            action = if (down) KeyAction.DOWN else KeyAction.UP,
            modifiers = modifiers,
            flags = (if (repeat) 1 else 0) or (if (fromIme) 2 else 0),
            keycode = keyCode,
            unicode = unicode.toLong() and 0xffffffffL,
            tsMicros = tsMicros
        )

    fun unicodeFor(keyCode: Int, metaState: Int): Int {
        val shifted = metaState and META_SHIFT != 0
        val caps = metaState and META_CAPS_LOCK != 0
        if (keyCode in 29..54) {
            val letter = 'a' + (keyCode - 29)
            return if (shifted != caps) letter.uppercaseChar().code else letter.code
        }
        if (keyCode in 7..16) {
            val digit = keyCode - 7
            if (!shifted) return ('0' + digit).code
            return ")!@#$%^&*("[digit].code
        }
        return when (keyCode) {
            55 -> if (shifted) '<'.code else ','.code
            56 -> if (shifted) '>'.code else '.'.code
            68 -> if (shifted) '~'.code else '`'.code
            69 -> if (shifted) '_'.code else '-'.code
            70 -> if (shifted) '+'.code else '='.code
            71 -> if (shifted) '{'.code else '['.code
            72 -> if (shifted) '}'.code else ']'.code
            73 -> if (shifted) '|'.code else '\\'.code
            74 -> if (shifted) ':'.code else ';'.code
            75 -> if (shifted) '"'.code else '\''.code
            76 -> if (shifted) '?'.code else '/'.code
            62 -> ' '.code
            17 -> '*'.code
            18 -> '#'.code
            else -> 0
        }
    }
}