package app.mirage.input

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View
import kotlin.math.cos
import kotlin.math.sin

class InputView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null
) : View(context, attrs) {
    var surfaceView: View? = null
    var onFrame: ((TouchFrame) -> Unit)? = null
    var excludeRightPx: Float = 24f * resources.displayMetrics.density

    var inputEnabled: Boolean = false
        set(value) {
            if (field && !value) onFrame?.invoke(TouchFrame(TouchAction.CANCEL, emptyList(), 0))
            field = value
            active.clear()
            invalidate()
        }

    private val active = mutableMapOf<Int, Pair<Float, Float>>()
    private val dotPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(90, 255, 255, 255)
        style = Paint.Style.FILL
    }

    private val contentRect = RectF()

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!inputEnabled) return false
        if (surfaceView == null || !updateContentRect()) return false
        if (event.actionMasked == MotionEvent.ACTION_DOWN && event.x >= width - excludeRightPx) {
            return false
        }

        val action = when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> TouchAction.DOWN
            MotionEvent.ACTION_MOVE -> TouchAction.MOVE
            MotionEvent.ACTION_UP -> TouchAction.UP
            MotionEvent.ACTION_POINTER_DOWN -> TouchAction.POINTER_DOWN
            MotionEvent.ACTION_POINTER_UP -> TouchAction.POINTER_UP
            MotionEvent.ACTION_CANCEL -> TouchAction.CANCEL
            MotionEvent.ACTION_HOVER_ENTER -> TouchAction.HOVER_ENTER
            MotionEvent.ACTION_HOVER_MOVE -> TouchAction.HOVER_MOVE
            MotionEvent.ACTION_HOVER_EXIT -> TouchAction.HOVER_EXIT
            else -> return true
        }

        val pointers = if (action == TouchAction.UP || action == TouchAction.CANCEL) {
            emptyList()
        } else {
            val skip = if (action == TouchAction.POINTER_UP) event.actionIndex else -1
            (0 until event.pointerCount)
                .filter { it != skip }
                .mapNotNull { sample(event, it) }
        }

        if (action == TouchAction.DOWN || action == TouchAction.MOVE) {
            pointers.forEach { active[it.id] = dotPoint(it) }
        }
        if (action == TouchAction.UP || action == TouchAction.CANCEL) active.clear()
        if (action == TouchAction.POINTER_UP) {
            val skip = if (event.actionIndex in 0 until event.pointerCount) event.getPointerId(event.actionIndex) else -1
            active.remove(skip)
        }
        invalidate()

        onFrame?.invoke(TouchFrame(action, pointers, event.eventTime))
        return true
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val radius = 14f * resources.displayMetrics.density
        for ((_, point) in active) {
            canvas.drawCircle(point.first, point.second, radius, dotPaint)
        }
    }

    private fun dotPoint(sample: TouchSample): Pair<Float, Float> =
        (contentRect.left + sample.x * contentRect.width()) to
            (contentRect.top + sample.y * contentRect.height())

    private fun updateContentRect(): Boolean {
        val surface = surfaceView ?: return false
        if (surface.width == 0 || surface.height == 0) return false
        val surfaceLocation = IntArray(2)
        val ownLocation = IntArray(2)
        surface.getLocationInWindow(surfaceLocation)
        getLocationInWindow(ownLocation)
        contentRect.set(
            (surfaceLocation[0] - ownLocation[0]).toFloat(),
            (surfaceLocation[1] - ownLocation[1]).toFloat(),
            (surfaceLocation[0] - ownLocation[0] + surface.width).toFloat(),
            (surfaceLocation[1] - ownLocation[1] + surface.height).toFloat()
        )
        return true
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun sample(event: MotionEvent, index: Int): TouchSample? {
        val x = event.getX(index)
        val y = event.getY(index)
        if (contentRect.width() <= 0f || contentRect.height() <= 0f) return null
        val nx = ((x - contentRect.left) / contentRect.width()).coerceIn(0f, 1f)
        val ny = ((y - contentRect.top) / contentRect.height()).coerceIn(0f, 1f)

        val tool = when (event.getToolType(index)) {
            MotionEvent.TOOL_TYPE_STYLUS -> TouchTool.STYLUS
            MotionEvent.TOOL_TYPE_ERASER -> TouchTool.ERASER
            else -> TouchTool.FINGER
        }
        val buttons = when {
            tool == TouchTool.ERASER -> 8
            tool == TouchTool.STYLUS && event.buttonState and MotionEvent.BUTTON_STYLUS_PRIMARY != 0 -> 4
            tool == TouchTool.STYLUS -> 1
            else -> 1
        }
        val pressure = event.getPressure(index).coerceIn(0f, 1f)
        val tilt = Math.toDegrees(event.getAxisValue(MotionEvent.AXIS_TILT, index).toDouble()).toFloat()
        val orientation = event.getAxisValue(MotionEvent.AXIS_ORIENTATION, index)

        return TouchSample(
            id = event.getPointerId(index),
            x = nx,
            y = ny,
            tool = tool,
            buttons = buttons,
            pressure = pressure,
            tiltX = tilt * cos(orientation),
            tiltY = tilt * sin(orientation),
            eventTimeMs = event.eventTime
        )
    }
}