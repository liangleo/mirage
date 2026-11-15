package app.mirage.input

import app.mirage.net.InputEvent
import app.mirage.net.PointerKind
import app.mirage.net.PointerSample
import app.mirage.net.ScrollFlags
import app.mirage.net.ScrollInput
import app.mirage.net.ScrollPhase
import kotlin.math.abs
import kotlin.math.hypot

enum class TouchTool { FINGER, STYLUS, ERASER }

enum class TouchAction { DOWN, MOVE, UP, POINTER_DOWN, POINTER_UP, CANCEL, HOVER_ENTER, HOVER_MOVE, HOVER_EXIT }

/** Coordinates are normalized 0..1 against the video content rect. */
data class TouchSample(
    val id: Int,
    val x: Float,
    val y: Float,
    val tool: TouchTool = TouchTool.FINGER,
    val buttons: Int = 1,
    val pressure: Float = 1f,
    val tiltX: Float = 0f,
    val tiltY: Float = 0f,
    val eventTimeMs: Long = 0
)

data class TouchFrame(
    val action: TouchAction,
    val pointers: List<TouchSample>,
    val eventTimeMs: Long
)

class GestureMapper(
    private val touchSlop: Float = 0.01f,
    private val longPressMs: Long = 500
) {
    private enum class Mode { IDLE, TENTATIVE, DRAG, SCROLL, STYLUS, IGNORE }

    private var mode = Mode.IDLE
    private var down: TouchSample? = null
    private var downTime = 0L
    private var lastDrag: TouchSample? = null
    private var lastCentroid = 0f to 0f
    private var lastSpread = 0f
    private var scrollStarted = false

    fun onFrame(frame: TouchFrame): List<InputEvent> = when (frame.action) {
        TouchAction.DOWN -> onDown(frame)
        TouchAction.MOVE -> onMove(frame)
        TouchAction.POINTER_DOWN -> onPointerDown(frame)
        TouchAction.POINTER_UP -> onPointerUp(frame)
        TouchAction.UP -> onUp(frame)
        TouchAction.CANCEL -> onCancel()
        TouchAction.HOVER_ENTER, TouchAction.HOVER_MOVE -> onHover(frame)
        TouchAction.HOVER_EXIT -> emptyList()
    }

    fun reset(): List<InputEvent> = onCancel()

    private fun onDown(frame: TouchFrame): List<InputEvent> {
        val first = frame.pointers.firstOrNull() ?: return emptyList()
        down = first
        downTime = frame.eventTimeMs
        lastDrag = first
        if (first.tool != TouchTool.FINGER) {
            mode = Mode.STYLUS
            return listOf(pointer(first, PointerKind.DOWN))
        }
        mode = Mode.TENTATIVE
        return emptyList()
    }

    private fun onMove(frame: TouchFrame): List<InputEvent> {
        val first = frame.pointers.firstOrNull() ?: return emptyList()
        return when (mode) {
            Mode.TENTATIVE -> {
                val origin = down ?: return emptyList()
                if (hypot(first.x - origin.x, first.y - origin.y) <= touchSlop) return emptyList()
                mode = Mode.DRAG
                lastDrag = first
                listOf(pointer(origin, PointerKind.DOWN), pointer(first, PointerKind.MOVE))
            }
            Mode.DRAG -> {
                lastDrag = first
                listOf(pointer(first, PointerKind.MOVE))
            }
            Mode.STYLUS -> {
                lastDrag = first
                listOf(pointer(first, PointerKind.MOVE))
            }
            Mode.SCROLL -> onScrollMove(frame)
            else -> emptyList()
        }
    }

    private fun onPointerDown(frame: TouchFrame): List<InputEvent> {
        val events = mutableListOf<InputEvent>()
        if (mode == Mode.DRAG && lastDrag != null) {
            events += pointer(lastDrag!!, PointerKind.CANCEL, buttons = 0)
        }
        if (mode == Mode.STYLUS) {
            events += pointer(down ?: frame.pointers.first(), PointerKind.CANCEL, buttons = 0)
        }
        if (frame.pointers.size >= 3) {
            mode = Mode.IGNORE
            return events
        }
        mode = Mode.SCROLL
        val (centroid, spread) = metrics(frame.pointers)
        lastCentroid = centroid
        lastSpread = spread
        scrollStarted = true
        events += scroll(ScrollPhase.BEGIN, 0f, 0f, ScrollFlags.PRECISE)
        return events
    }

    private fun onPointerUp(frame: TouchFrame): List<InputEvent> {
        if (mode != Mode.SCROLL || frame.pointers.size >= 2) return emptyList()
        val (centroid, spread) = metrics(frame.pointers)
        lastCentroid = centroid
        lastSpread = spread
        scrollStarted = false
        mode = Mode.IGNORE
        return listOf(scroll(ScrollPhase.END, 0f, 0f, ScrollFlags.PRECISE))
    }

    private fun onUp(frame: TouchFrame): List<InputEvent> {
        val first = frame.pointers.firstOrNull() ?: lastDrag ?: down
        val events = when (mode) {
            Mode.TENTATIVE -> {
                val sample = down ?: first ?: return finishTap()
                val held = frame.eventTimeMs - downTime >= longPressMs
                if (held) {
                    listOf(
                        pointer(sample, PointerKind.DOWN, buttons = 2),
                        pointer(sample, PointerKind.UP, buttons = 2)
                    )
                } else {
                    listOf(
                        pointer(sample, PointerKind.DOWN),
                        pointer(sample, PointerKind.UP, buttons = 0)
                    )
                }
            }
            Mode.DRAG -> {
                val sample = first ?: lastDrag
                if (sample == null) emptyList() else listOf(pointer(sample, PointerKind.UP, buttons = 0))
            }
            Mode.STYLUS -> {
                val sample = first ?: lastDrag
                if (sample == null) emptyList() else listOf(pointer(sample, PointerKind.UP, buttons = 0))
            }
            Mode.SCROLL -> if (scrollStarted) listOf(scroll(ScrollPhase.END, 0f, 0f, ScrollFlags.PRECISE)) else emptyList()
            else -> emptyList()
        }
        resetState()
        return events
    }

    private fun finishTap(): List<InputEvent> {
        resetState()
        return emptyList()
    }

    private fun onCancel(): List<InputEvent> {
        val events = when (mode) {
            Mode.DRAG -> lastDrag?.let { listOf(pointer(it, PointerKind.CANCEL, buttons = 0)) } ?: emptyList()
            Mode.STYLUS -> (lastDrag ?: down)?.let { listOf(pointer(it, PointerKind.CANCEL, buttons = 0)) } ?: emptyList()
            Mode.SCROLL -> if (scrollStarted) listOf(scroll(ScrollPhase.END, 0f, 0f, ScrollFlags.PRECISE)) else emptyList()
            else -> emptyList()
        }
        resetState()
        return events
    }

    private fun onHover(frame: TouchFrame): List<InputEvent> {
        val first = frame.pointers.firstOrNull() ?: return emptyList()
        if (first.tool != TouchTool.STYLUS && first.tool != TouchTool.ERASER) return emptyList()
        return listOf(pointer(first, PointerKind.HOVER, buttons = 0))
    }

    private fun onScrollMove(frame: TouchFrame): List<InputEvent> {
        if (frame.pointers.size < 2) return emptyList()
        val (centroid, spread) = metrics(frame.pointers)
        val pinch = lastSpread > 0f && abs(spread - lastSpread) / lastSpread > 0.02f
        val flags = if (pinch) ScrollFlags.COMMAND or ScrollFlags.PRECISE else ScrollFlags.PRECISE
        val dx = if (pinch) 0f else (centroid.first - lastCentroid.first) * 1000f
        val dy = if (pinch) (spread - lastSpread) * 400f else (centroid.second - lastCentroid.second) * 1000f
        lastCentroid = centroid
        lastSpread = spread
        return listOf(scroll(ScrollPhase.CHANGE, dx, dy, flags))
    }

    private fun metrics(pointers: List<TouchSample>): Pair<Pair<Float, Float>, Float> {
        val first = pointers[0]
        val second = pointers.getOrElse(1) { first }
        return ((first.x + second.x) / 2f to (first.y + second.y) / 2f) to hypot(first.x - second.x, first.y - second.y)
    }

    private fun pointer(sample: TouchSample, kind: PointerKind, buttons: Int = sample.buttons): InputEvent.Pointer =
        InputEvent.Pointer(
            listOf(
                PointerSample(
                    kind = kind,
                    pointerID = sample.id,
                    buttons = buttons,
                    x = sample.x,
                    y = sample.y,
                    pressure = sample.pressure,
                    tiltX = sample.tiltX,
                    tiltY = sample.tiltY,
                    tsMicros = sample.eventTimeMs * 1000
                )
            )
        )

    private fun scroll(phase: ScrollPhase, dx: Float, dy: Float, flags: Int): InputEvent.Scroll =
        InputEvent.Scroll(ScrollInput(phase, flags, dx, dy, System.nanoTime() / 1000))

    private fun resetState() {
        mode = Mode.IDLE
        down = null
        downTime = 0
        lastDrag = null
        scrollStarted = false
    }
}