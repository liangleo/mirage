package app.mirage.video

import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import app.mirage.net.SessionConfig
import app.mirage.net.StreamStats
import app.mirage.net.VideoFrame
import java.nio.ByteBuffer

class VideoDecoder(
    private val surface: Surface,
    private val config: SessionConfig,
    private val stats: StreamStats,
    private val onError: (String) -> Unit,
    private val onNeedKeyframe: () -> Unit = {}
) {
    private val thread = HandlerThread("mirage-decoder").apply { start() }
    private val handler = Handler(thread.looper)
    private val queue = DecodeQueue(capacity = 4)
    private val submittedAtNanos = HashMap<Long, Long>()

    @Volatile
    private var running = true

    private var codec: MediaCodec? = null
    private var initFailures = 0
    private var outputs = 0

    fun start() {
        Log.i("Mirage", "decoder.start")
        handler.post { loop() }
    }

    fun submit(frame: VideoFrame) {
        if (running && queue.offer(frame)) {
            stats.onDropped()
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
            val frame = queue.poll(100) ?: continue
            if (frame.header.flags and 1 != 0) {
                firstKeyframe = frame
            }
        }
        if (!running || firstKeyframe == null) return
        Log.i("Mirage", "first keyframe bytes=${firstKeyframe.annexB.size}")

        try {
            configureDecoder(firstKeyframe.annexB)
        } catch (error: Exception) {
            onError("decoder init failed: ${error.message}")
            queue.clear()
            if (initFailures < MAX_INIT_FAILURES) {
                initFailures++
                handler.postDelayed({ loop() }, 500)
            }
            return
        }
        initFailures = 0

        var pending: VideoFrame? = firstKeyframe
        while (running) {
            val frame = pending ?: queue.poll(50)
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
                submittedAtNanos[frame.header.captureTimestampMicros] = SystemClock.elapsedRealtimeNanos()
                pending = null
            } catch (error: Exception) {
                onError("decode failed: ${error.message}")
                restartDecoder()
                return
            }
            drainOutput()
        }
    }

    private fun restartDecoder() {
        try {
            codec?.stop()
        } catch (_: Exception) {
        }
        try {
            codec?.release()
        } catch (_: Exception) {
        }
        codec = null
        queue.clear()
        submittedAtNanos.clear()
        onNeedKeyframe()
        if (running) {
            handler.post { loop() }
        }
    }

    private fun configureDecoder(firstKeyframe: ByteArray) {
        val (sps, pps) = AnnexB.parameterSets(firstKeyframe)
        Log.i("Mirage", "configure ${config.width}x${config.height} sps=${sps?.size ?: -1} pps=${pps?.size ?: -1}")

        try {
            startDecoder(buildFormat(sps, pps))
        } catch (firstError: Exception) {
            Log.w("Mirage", "configure with csd failed: ${firstError.message}; retrying in-band")
            startDecoder(buildFormat(null, null))
        }
    }

    private fun buildFormat(sps: ByteArray?, pps: ByteArray?): MediaFormat {
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
        try {
            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 4 * 1024 * 1024)
        } catch (_: Exception) {
        }

        if (sps != null) format.setByteBuffer("csd-0", ByteBuffer.wrap(sps))
        if (pps != null) format.setByteBuffer("csd-1", ByteBuffer.wrap(pps))
        return format
    }

    private fun startDecoder(format: MediaFormat) {
        val decoder = createDecoder()
        try {
            decoder.configure(format, surface, null, 0)
            decoder.start()
        } catch (error: Exception) {
            try {
                decoder.release()
            } catch (_: Exception) {
            }
            throw error
        }
        codec = decoder
    }

    private fun createDecoder(): MediaCodec {
        return try {
            MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        } catch (error: Exception) {
            val name = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
                .firstOrNull { info ->
                    !info.isEncoder && info.supportedTypes.any {
                        it.equals(MediaFormat.MIMETYPE_VIDEO_AVC, true)
                    }
                }
                ?.name
            if (name != null) MediaCodec.createByCodecName(name) else throw error
        }
    }

    private fun drainOutput() {
        val info = MediaCodec.BufferInfo()
        while (true) {
            val decoder = codec ?: return
            val index = decoder.dequeueOutputBuffer(info, 0)
            when {
                index >= 0 -> {
                    if (outputs == 0) {
                        Log.i("Mirage", "first output pts=${info.presentationTimeUs} size=${info.size}")
                    }
                    outputs++
                    submittedAtNanos.remove(info.presentationTimeUs)?.let { startedAt ->
                        stats.setDecodeMs((SystemClock.elapsedRealtimeNanos() - startedAt) / 1_000_000)
                    }
                    decoder.releaseOutputBuffer(index, true)
                }
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> return
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> Unit
                else -> return
            }
        }
    }

    companion object {
        private const val MAX_INIT_FAILURES = 3
    }
}