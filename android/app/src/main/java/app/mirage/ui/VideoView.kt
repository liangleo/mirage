package app.mirage.ui

import android.content.Context
import android.util.AttributeSet
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView

class AspectSurfaceView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null
) : SurfaceView(context, attrs) {
    var videoWidth: Int = 0
        set(value) {
            field = value
            requestLayout()
        }

    var videoHeight: Int = 0
        set(value) {
            field = value
            requestLayout()
        }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val availableWidth = MeasureSpec.getSize(widthMeasureSpec)
        val availableHeight = MeasureSpec.getSize(heightMeasureSpec)
        if (videoWidth > 0 && videoHeight > 0) {
            val scale = minOf(
                availableWidth.toFloat() / videoWidth,
                availableHeight.toFloat() / videoHeight
            )
            setMeasuredDimension(
                (videoWidth * scale).toInt(),
                (videoHeight * scale).toInt()
            )
        } else {
            setMeasuredDimension(availableWidth, availableHeight)
        }
    }
}

@Composable
fun VideoView(
    modifier: Modifier = Modifier,
    onSurfaceReady: (AspectSurfaceView, Surface) -> Unit
) {
    Box(modifier = modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        AndroidView(
            factory = { context ->
                AspectSurfaceView(context).apply {
                    val surfaceView = this
                    holder.addCallback(object : SurfaceHolder.Callback {
                        override fun surfaceCreated(holder: SurfaceHolder) {
                            onSurfaceReady(surfaceView, holder.surface)
                        }

                        override fun surfaceChanged(
                            holder: SurfaceHolder,
                            format: Int,
                            width: Int,
                            height: Int
                        ) = Unit

                        override fun surfaceDestroyed(holder: SurfaceHolder) = Unit
                    })
                }
            }
        )
    }
}