package app.mirage.video

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import app.mirage.net.SessionConfig
import app.mirage.net.VideoFrame
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

class VideoDecoder(
    private val surface: Surface,
    private val config: SessionConfig,
    private val onError: (String) -> Unit
) {
    private val thread = HandlerThread("mirage-decoder").apply { start() }
    private val handler = Handler(thread.looper)
    private val queue = LinkedBlockingQueue<VideoFrame>()

    @Volatile
    private var running = true

    private var codec: MediaCodec? = null

    fun start() {
        handler.post { loop() }
    }

    fun submit(frame: VideoFrame) {
        if (running) {
            queue.offer(frame)
        }
    }

    fun release() {
        running = false
        handler.post {
            try {
                codec?.stop()
            } catch (_: Exception) {
            }
            try {
                codec?.release()
            } catch (_: Exception) {
            }
            codec = null
            thread.quitSafely()
        }
    }

    private fun loop() {
        var firstKeyframe: VideoFrame? = null
        while (running && firstKeyframe == null) {
            val frame = queue.poll(100, TimeUnit.MILLISECONDS) ?: continue
            if (frame.header.flags and 1 != 0) {
                firstKeyframe = frame
            }
        }
        if (!running || firstKeyframe == null) return

        try {
            configureDecoder(firstKeyframe.annexB)
        } catch (error: Exception) {
            onError("decoder init failed: ${error.message}")
            return
        }

        var pending: VideoFrame? = firstKeyframe
        while (running) {
            val frame = pending ?: queue.poll(50, TimeUnit.MILLISECONDS)
            if (frame == null) {
                drainOutput()
                continue
            }
            try {
                val decoder = codec ?: return
                val inputIndex = decoder.dequeueInputBuffer(10_000)
                if (inputIndex < 0) {
                    pending = frame
                    drainOutput()
                    continue
                }
                val buffer = decoder.getInputBuffer(inputIndex) ?: continue
                buffer.clear()
                buffer.put(frame.annexB)
                decoder.queueInputBuffer(
                    inputIndex,
                    0,
                    frame.annexB.size,
                    frame.header.captureTimestampMicros,
                    0
                )
                pending = null
            } catch (error: Exception) {
                onError("decode failed: ${error.message}")
                running = false
            }
            drainOutput()
        }
    }

    private fun configureDecoder(firstKeyframe: ByteArray) {
        val format = MediaFormat.createVideoFormat(
            MediaFormat.MIMETYPE_VIDEO_AVC,
            config.width,
            config.height
        )
        if (Build.VERSION.SDK_INT >= 30) {
            try {
                format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            } catch (_: Exception) {
            }
        }
        if (Build.VERSION.SDK_INT >= 28) {
            try {
                format.setInteger(MediaFormat.KEY_PRIORITY, 0)
            } catch (_: Exception) {
            }
        }
        try {
            format.setInteger(MediaFormat.KEY_OPERATING_RATE, config.fps)
        } catch (_: Exception) {
        }

        val (sps, pps) = AnnexB.parameterSets(firstKeyframe)
        if (sps != null) format.setByteBuffer("csd-0", ByteBuffer.wrap(sps))
        if (pps != null) format.setByteBuffer("csd-1", ByteBuffer.wrap(pps))

        val decoder = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        decoder.configure(format, surface, null, 0)
        decoder.start()
        codec = decoder
    }

    private fun drainOutput() {
        val info = MediaCodec.BufferInfo()
        while (true) {
            val decoder = codec ?: return
            val index = decoder.dequeueOutputBuffer(info, 0)
            when {
                index >= 0 -> decoder.releaseOutputBuffer(index, true)
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> return
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> Unit
                else -> return
            }
        }
    }
}