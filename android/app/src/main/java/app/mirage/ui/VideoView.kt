package app.mirage.ui

import android.content.Context
import android.graphics.SurfaceTexture
import android.util.AttributeSet
import android.view.Surface
import android.view.TextureView
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView

class AspectTextureView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null
) : TextureView(context, attrs) {
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

    fun applyVideoSize(width: Int, height: Int) {
        videoWidth = width
        videoHeight = height
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
    onSurfaceReady: (AspectTextureView, Surface) -> Unit,
    onSurfaceDestroyed: () -> Unit = {}
) {
    Box(modifier = modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        AndroidView(
            factory = { context ->
                AspectTextureView(context).apply {
                    val view = this
                    var surface: Surface? = null
                    surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                        override fun onSurfaceTextureAvailable(
                            texture: SurfaceTexture,
                            width: Int,
                            height: Int
                        ) {
                            val newSurface = Surface(texture)
                            surface = newSurface
                            onSurfaceReady(view, newSurface)
                        }

                        override fun onSurfaceTextureSizeChanged(
                            texture: SurfaceTexture,
                            width: Int,
                            height: Int
                        ) = Unit

                        override fun onSurfaceTextureDestroyed(texture: SurfaceTexture): Boolean {
                            onSurfaceDestroyed()
                            surface?.release()
                            surface = null
                            return true
                        }

                        override fun onSurfaceTextureUpdated(texture: SurfaceTexture) = Unit
                    }
                }
            }
        )
    }
}