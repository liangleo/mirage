package app.mirage.input

import app.mirage.net.InputEvent
import app.mirage.net.PointerKind
import app.mirage.net.ScrollFlags
import app.mirage.net.ScrollPhase
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class GestureMapperTest {
    private val mapper = GestureMapper(touchSlop = 0.02f, longPressMs = 500)

    private fun finger(id: Int = 0, x: Float = 0.5f, y: Float = 0.5f, time: Long = 0, tool: TouchTool = TouchTool.FINGER, pressure: Float = 1f, tiltX: Float = 0f, tiltY: Float = 0f) =
        TouchSample(id, x, y, tool, 1, pressure, tiltX, tiltY, time)

    private fun samples(events: List<InputEvent>): List<app.mirage.net.PointerSample> =
        events.filterIsInstance<InputEvent.Pointer>().flatMap { it.samples }

    @Test
    fun tapSendsDownAndUpLeft() {
        val down = mapper.onFrame(TouchFrame(TouchAction.DOWN, listOf(finger(time = 100)), 100))
        val up = mapper.onFrame(TouchFrame(TouchAction.UP, emptyList(), 180))

        assertTrue(down.isEmpty())
        assertEquals(listOf(PointerKind.DOWN, PointerKind.UP), samples(up).map { it.kind })
        assertEquals(1, samples(up)[0].buttons)
        assertEquals(0, samples(up)[1].buttons)
    }

    @Test
    fun dragSendsDownThenMovesAndUp() {
        mapper.onFrame(TouchFrame(TouchAction.DOWN, listOf(finger(time = 0)), 0))
        val drag = mapper.onFrame(TouchFrame(TouchAction.MOVE, listOf(finger(x = 0.6f, y = 0.5f, time = 20)), 20))
        val more = mapper.onFrame(TouchFrame(TouchAction.MOVE, listOf(finger(x = 0.7f, y = 0.5f, time = 40)), 40))
        val up = mapper.onFrame(TouchFrame(TouchAction.UP, listOf(finger(x = 0.7f, time = 60)), 60))

        assertEquals(listOf(PointerKind.DOWN, PointerKind.MOVE), samples(drag).map { it.kind })
        assertEquals(0.5f, samples(drag)[0].x, 0.001f)
        assertEquals(listOf(PointerKind.MOVE), samples(more).map { it.kind })
        assertEquals(listOf(PointerKind.UP), samples(up).map { it.kind })
        assertEquals(0, samples(up)[0].buttons)
    }

    @Test
    fun longPressWithoutMovementSendsRightClick() {
        mapper.onFrame(TouchFrame(TouchAction.DOWN, listOf(finger(time = 0)), 0))
        val up = mapper.onFrame(TouchFrame(TouchAction.UP, emptyList(), 600))

        assertEquals(listOf(PointerKind.DOWN, PointerKind.UP), samples(up).map { it.kind })
        assertEquals(listOf(2, 2), samples(up).map { it.buttons })
    }

    @Test
    fun secondFingerBeforeSlopEntersScrollWithoutClick() {
        val first = mapper.onFrame(TouchFrame(TouchAction.DOWN, listOf(finger(time = 0)), 0))
        val second = mapper.onFrame(
            TouchFrame(
                TouchAction.POINTER_DOWN,
                listOf(finger(x = 0.4f, time = 10), finger(id = 1, x = 0.6f, time = 10)),
                10
            )
        )
        val scroll = mapper.onFrame(
            TouchFrame(
                TouchAction.MOVE,
                listOf(finger(x = 0.4f, y = 0.45f, time = 20), finger(id = 1, x = 0.6f, y = 0.45f, time = 20)),
                20
            )
        )

        assertTrue(first.isEmpty())
        assertEquals(1, second.size)
        assertTrue(second[0] is InputEvent.Scroll)
        assertEquals(ScrollPhase.BEGIN, (second[0] as InputEvent.Scroll).scroll.phase)
        assertTrue(samples(second).isEmpty())
        val change = scroll[0] as InputEvent.Scroll
        assertEquals(ScrollPhase.CHANGE, change.scroll.phase)
        assertEquals(-50f, change.scroll.dy, 1f)
    }

    @Test
    fun secondFingerDuringDragCancelsThenScrolls() {
        mapper.onFrame(TouchFrame(TouchAction.DOWN, listOf(finger(time = 0)), 0))
        mapper.onFrame(TouchFrame(TouchAction.MOVE, listOf(finger(x = 0.8f, time = 20)), 20))
        val second = mapper.onFrame(
            TouchFrame(
                TouchAction.POINTER_DOWN,
                listOf(finger(x = 0.8f, time = 30), finger(id = 1, x = 0.2f, time = 30)),
                30
            )
        )

        assertEquals(PointerKind.CANCEL, samples(second)[0].kind)
        assertTrue(second.last() is InputEvent.Scroll)
    }

    @Test
    fun pinchSendsCommandFlagAndPhases() {
        mapper.onFrame(TouchFrame(TouchAction.DOWN, listOf(finger(x = 0.4f), finger(id = 1, x = 0.6f)), 0).copy(action = TouchAction.DOWN))
        mapper.onFrame(TouchFrame(TouchAction.POINTER_DOWN, listOf(finger(x = 0.4f), finger(id = 1, x = 0.6f)), 10))
        val pinch = mapper.onFrame(
            TouchFrame(TouchAction.MOVE, listOf(finger(x = 0.3f, time = 20), finger(id = 1, x = 0.7f, time = 20)), 20)
        )
        val end = mapper.onFrame(TouchFrame(TouchAction.POINTER_UP, listOf(finger(x = 0.3f)), 30))

        val change = pinch[0] as InputEvent.Scroll
        assertEquals(ScrollPhase.CHANGE, change.scroll.phase)
        assertTrue(change.scroll.flags and ScrollFlags.COMMAND != 0)
        assertEquals(0f, change.scroll.dx, 0.001f)
        assertEquals(ScrollPhase.END, (end[0] as InputEvent.Scroll).scroll.phase)
    }

    @Test
    fun stylusSendsImmediateDownWithPressureAndTilt() {
        val events = mapper.onFrame(
            TouchFrame(
                TouchAction.DOWN,
                listOf(finger(x = 0.2f, y = 0.3f, tool = TouchTool.STYLUS, pressure = 0.6f, tiltX = 12f, tiltY = -8f, time = 5)),
                5
            )
        )
        val up = mapper.onFrame(
            TouchFrame(TouchAction.UP, listOf(finger(x = 0.2f, y = 0.3f, tool = TouchTool.STYLUS, time = 40)), 40)
        )

        assertEquals(listOf(PointerKind.DOWN), samples(events).map { it.kind })
        assertEquals(0.6f, samples(events)[0].pressure, 0.001f)
        assertEquals(12f, samples(events)[0].tiltX, 0.001f)
        assertEquals(-8f, samples(events)[0].tiltY, 0.001f)
        assertEquals(listOf(PointerKind.UP), samples(up).map { it.kind })
    }

    @Test
    fun cancelClearsStateWithoutResidualUp() {
        mapper.onFrame(TouchFrame(TouchAction.DOWN, listOf(finger(x = 0.5f)), 0))
        mapper.onFrame(TouchFrame(TouchAction.MOVE, listOf(finger(x = 0.9f)), 20))
        val cancel = mapper.onFrame(TouchFrame(TouchAction.CANCEL, emptyList(), 30))
        val after = mapper.onFrame(TouchFrame(TouchAction.UP, emptyList(), 40))

        assertEquals(PointerKind.CANCEL, samples(cancel)[0].kind)
        assertTrue(after.isEmpty())
    }

    @Test
    fun threeFingersAreIgnoredAfterCleanup() {
        mapper.onFrame(TouchFrame(TouchAction.DOWN, listOf(finger()), 0))
        mapper.onFrame(TouchFrame(TouchAction.MOVE, listOf(finger(x = 0.8f)), 10))
        val third = mapper.onFrame(
            TouchFrame(
                TouchAction.POINTER_DOWN,
                listOf(finger(x = 0.8f), finger(id = 1, x = 0.5f), finger(id = 2, x = 0.2f)),
                20
            )
        )

        assertEquals(PointerKind.CANCEL, samples(third)[0].kind)
        assertTrue(third.none { it is InputEvent.Scroll })
    }
}