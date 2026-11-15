package app.mirage.input

import app.mirage.net.InputEvent
import app.mirage.net.InputModifiers
import app.mirage.net.KeyAction
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyMappingTest {
    private val events = mutableListOf<InputEvent>()
    private val dispatcher = ImeDispatcher { events += it }

    private fun keys() = events.filterIsInstance<InputEvent.Key>().map { it.key }

    @Test
    fun hardwareLetterSendsKeyWithUnicode() {
        dispatcher.keyEvent(ImeDispatcher.ACTION_DOWN, 29, 0)
        dispatcher.keyEvent(ImeDispatcher.ACTION_UP, 29, 0)

        val keys = keys()
        assertEquals(listOf(KeyAction.DOWN, KeyAction.UP), keys.map { it.action })
        assertTrue(keys.all { it.unicode == 'a'.code.toLong() })
        assertEquals(listOf(29, 29), keys.map { it.keycode })
    }

    @Test
    fun shiftLetterUppercasesAndSetsModifier() {
        dispatcher.keyEvent(ImeDispatcher.ACTION_DOWN, 29, KeyMapping.META_SHIFT)

        val key = keys().single()
        assertEquals('A'.code.toLong(), key.unicode)
        assertEquals(InputModifiers.SHIFT, key.modifiers)
    }

    @Test
    fun commandShortcutSendsKeyWithoutText() {
        dispatcher.keyEvent(ImeDispatcher.ACTION_DOWN, 31, KeyMapping.META_META)

        val key = keys().single()
        assertEquals(31, key.keycode)
        assertEquals(InputModifiers.COMMAND, key.modifiers)
        assertTrue(events.none { it is InputEvent.Text })
    }

    @Test
    fun commitSendsSingleTextWithoutKeys() {
        dispatcher.commit("你好")

        assertEquals(1, events.count { it is InputEvent.Text })
        assertEquals("你好", (events.single() as InputEvent.Text).text.text)
        assertTrue(keys().isEmpty())
    }

    @Test
    fun deleteSendsBackspaceDownAndUpPerCharacter() {
        dispatcher.delete(3)

        val keys = keys()
        assertEquals(6, keys.size)
        assertTrue(keys.all { it.keycode == ImeDispatcher.KEYCODE_DEL })
        assertEquals(3, keys.count { it.action == KeyAction.DOWN })
        assertEquals(3, keys.count { it.action == KeyAction.UP })
    }

    @Test
    fun releaseAllEmitsReleaseEvent() {
        dispatcher.releaseAll()
        assertEquals(listOf<InputEvent>(InputEvent.ReleaseAll), events)
    }

    @Test
    fun unicodeMappingCoversDigitsPunctuationAndNonPrintingKeys() {
        assertEquals('1'.code, KeyMapping.unicodeFor(8, 0))
        assertEquals('!'.code, KeyMapping.unicodeFor(8, KeyMapping.META_SHIFT))
        assertEquals(','.code, KeyMapping.unicodeFor(55, 0))
        assertEquals('<'.code, KeyMapping.unicodeFor(55, KeyMapping.META_SHIFT))
        assertEquals(' '.code, KeyMapping.unicodeFor(62, 0))
        assertEquals(0, KeyMapping.unicodeFor(19, 0))
        assertEquals(0, KeyMapping.unicodeFor(66, 0))
    }

    @Test
    fun disabledDispatcherDropsEverything() {
        dispatcher.enabled = false
        dispatcher.keyEvent(ImeDispatcher.ACTION_DOWN, 29, 0)
        dispatcher.commit("hello")
        dispatcher.delete(2)
        assertTrue(events.isEmpty())
    }
}