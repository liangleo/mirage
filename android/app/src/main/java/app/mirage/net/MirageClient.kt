package app.mirage.net

import android.os.SystemClock
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.nio.ByteOrder

class MirageClient(
    private val host: String,
    private val port: Int,
    private val hello: Hello,
    private val stats: StreamStats,
    private val listener: Listener
) {
    interface Listener {
        fun onConfig(config: SessionConfig)
        fun onVideo(frame: VideoFrame)
        fun onClosed(reason: String)
    }

    private val thread = Thread({ run() }, "mirage-client")
    private val liveness = Liveness(timeoutMs = 3_000)

    @Volatile
    private var running = true

    @Volatile
    private var socket: Socket? = null

    @Volatile
    private var output: OutputStream? = null

    private var lastPingAtMs = 0L
    private var pendingPingMicros: Long? = null
    private var pendingPingSentNanos: Long? = null
    private var clockOffsetMicros: Long? = null

    fun connect() {
        thread.start()
    }

    fun requestKeyframe() {
        val stream = output ?: return
        try {
            synchronized(stream) {
                stream.write(Messages.encodeFrame(MessageType.CTRL.id, byteArrayOf(1)))
                stream.flush()
            }
        } catch (_: Exception) {
        }
    }

    fun close() {
        running = false
        try {
            socket?.close()
        } catch (_: Exception) {
        }
    }

    private fun maybeSendPing(stream: OutputStream) {
        val now = System.currentTimeMillis()
        if (now - lastPingAtMs < 1_000) return
        lastPingAtMs = now

        val micros = SystemClock.elapsedRealtimeNanos() / 1000
        pendingPingMicros = micros
        pendingPingSentNanos = SystemClock.elapsedRealtimeNanos()

        val payload = ByteBuffer.allocate(8).order(ByteOrder.BIG_ENDIAN).putLong(micros).array()
        try {
            synchronized(stream) {
                stream.write(Messages.encodeFrame(MessageType.PING.id, payload))
                stream.flush()
            }
        } catch (_: Exception) {
        }
    }

    private fun handlePing(payload: ByteArray, stream: OutputStream) {
        if (payload.size < 8) return
        val echoed = ByteBuffer.wrap(payload).order(ByteOrder.BIG_ENDIAN).long
        val pending = pendingPingMicros

        if (pending != null && echoed == pending) {
            val nowNanos = SystemClock.elapsedRealtimeNanos()
            val sentNanos = pendingPingSentNanos
            if (sentNanos != null) {
                val rttMicros = (nowNanos - sentNanos) / 1000
                stats.setRttMs(rttMicros / 1000)
                if (payload.size >= 16) {
                    val macMicros = ByteBuffer.wrap(payload, 8, 8).order(ByteOrder.BIG_ENDIAN).long
                    clockOffsetMicros = nowNanos / 1000 - rttMicros / 2 - macMicros
                }
            }
            pendingPingMicros = null
            pendingPingSentNanos = null
            return
        }

        try {
            synchronized(stream) {
                stream.write(Messages.encodePing(echoed))
                stream.flush()
            }
        } catch (_: Exception) {
        }
    }

    private fun run() {
        var output: OutputStream? = null
        try {
            val connection = Socket()
            connection.connect(InetSocketAddress(host, port), 5_000)
            connection.tcpNoDelay = true
            socket = connection

            output = connection.getOutputStream()
            this.output = output
            output.write(Messages.encodeHello(hello))
            output.flush()
            liveness.noteActivity(System.currentTimeMillis())

            val input = connection.getInputStream()
            val decoder = FrameDecoder()
            val buffer = ByteArray(64 * 1024)

            while (running) {
                maybeSendPing(output)
                connection.soTimeout = 1_000
                val read = try {
                    input.read(buffer)
                } catch (_: SocketTimeoutException) {
                    if (liveness.timedOut(System.currentTimeMillis())) {
                        listener.onClosed("连接无响应")
                        return
                    }
                    continue
                }
                if (read < 0) break

                decoder.append(buffer.copyOf(read))
                while (true) {
                    val frame = decoder.next() ?: break
                    liveness.noteActivity(System.currentTimeMillis())
                    when (frame.type) {
                        MessageType.SESSION_CONFIG.id ->
                            listener.onConfig(Messages.decodeSessionConfig(frame.payload))

                        MessageType.VIDEO.id -> {
                            val video = Messages.decodeVideo(frame.payload)
                            stats.onVideo(frame.payload.size)
                            clockOffsetMicros?.let { offset ->
                                val nowMicros = SystemClock.elapsedRealtimeNanos() / 1000
                                val e2eMicros = nowMicros - offset - video.header.captureTimestampMicros
                                if (e2eMicros in 0..10_000_000) {
                                    stats.setE2eMs(e2eMicros / 1000)
                                }
                            }
                            listener.onVideo(video)
                        }

                        MessageType.PING.id -> {
                            handlePing(frame.payload, output)
                        }

                        MessageType.BYE.id -> {
                            listener.onClosed("服务端断开")
                            return
                        }
                    }
                }
            }
            listener.onClosed("连接已断开")
        } catch (error: Exception) {
            if (running) {
                listener.onClosed(error.message ?: "连接失败")
            }
        } finally {
            try {
                output?.close()
            } catch (_: Exception) {
            }
            this.output = null
            try {
                socket?.close()
            } catch (_: Exception) {
            }
            socket = null
        }
    }
}