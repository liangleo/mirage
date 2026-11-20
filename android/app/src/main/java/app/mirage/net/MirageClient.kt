package app.mirage.net

import android.os.SystemClock
import java.io.OutputStream
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.nio.ByteOrder

class MirageClient(
    private val hello: Hello,
    private val stats: StreamStats,
    private val listener: Listener,
    private val openConnection: () -> StreamConnection,
    private val serverHost: String? = null
) {
    interface Listener {
        fun onConfig(config: SessionConfig)
        fun onVideo(frame: VideoFrame)
        fun onClosed(reason: String)
        fun onUdpReady(ready: Boolean) {}
        fun onInputState(enabled: Boolean, reason: String?) {}
    }

    private val thread = Thread({ run() }, "mirage-client")
    private val sender = java.util.concurrent.Executors.newSingleThreadExecutor { task ->
        Thread(task, "mirage-ctrl").apply { isDaemon = true }
    }
    private val liveness = Liveness(timeoutMs = 3_000)

    @Volatile
    private var running = true

    @Volatile
    private var connection: StreamConnection? = null

    @Volatile
    private var output: OutputStream? = null

    @Volatile
    private var connectedOnce = false

    @Volatile
    private var closedReported = false

    private var watchdog: Thread? = null

    @Volatile
    private var udpReceiver: UdpVideoReceiver? = null

    @Volatile
    private var udpActive = false

    @Volatile
    private var feedback: FeedbackReporter? = null

    private var lastPingAtMs = 0L
    private var pendingPingMicros: Long? = null
    private var pendingPingSentNanos: Long? = null
    @Volatile
    private var clockOffsetMicros: Long? = null

    fun connect() {
        thread.start()
        watchdog = Thread({ watchLiveness() }, "mirage-watchdog").also { it.start() }
    }

    private fun watchLiveness() {
        while (running) {
            try {
                Thread.sleep(500)
            } catch (_: InterruptedException) {
                return
            }
            if (!running) return
            if (connectedOnce && liveness.timedOut(System.currentTimeMillis())) {
                reportClosed("连接无响应")
                close()
                return
            }
        }
    }

    private fun reportClosed(reason: String) {
        synchronized(this) {
            if (closedReported) return
            closedReported = true
        }
        listener.onClosed(reason)
    }

    fun requestKeyframe() {
        sendFrame(Messages.encodeFrame(MessageType.CTRL.id, byteArrayOf(Ctrl.REQUEST_KEYFRAME.toByte())))
    }

    fun sendInput(encoded: ByteArray) {
        sendFrame(encoded)
    }

    fun releaseAllInput() {
        sendFrame(Messages.encodeFrame(MessageType.CTRL.id, byteArrayOf(Ctrl.RELEASE_ALL.toByte())))
    }

    fun requestUsb() {
        sendFrame(Messages.encodeFrame(MessageType.CTRL.id, byteArrayOf(Ctrl.USB_REQUEST.toByte())))
    }

    fun updateHello(hello: Hello) {
        sendFrame(Messages.encodeHello(hello))
    }

    private fun sendFrame(encoded: ByteArray) {
        val stream = output ?: return
        sender.execute {
            try {
                synchronized(stream) {
                    stream.write(encoded)
                    stream.flush()
                }
            } catch (_: Exception) {
            }
        }
    }

    private fun handleUdpConfig(payload: ByteArray) {
        val host = serverHost ?: return
        val config = try {
            UdpProtocol.decodeUdpConfig(payload)
        } catch (_: Exception) {
            return
        }
        if (!config.isEnabled) return

        udpReceiver?.stop()
        var self: UdpVideoReceiver? = null
        val receiver = UdpVideoReceiver(
            key = config.key,
            noncePrefix = config.noncePrefix,
            cipher = config.cipher,
            onFrame = { frame ->
                feedback?.onVideo(frame.annexB.size)
                stats.onVideo(frame.annexB.size)
                noteE2e(frame.header.captureTimestampMicros)
                listener.onVideo(frame)
            },
            onReady = {
                udpActive = true
                listener.onUdpReady(true)
                sendFrame(Messages.encodeFrame(MessageType.CTRL.id, byteArrayOf(Ctrl.UDP_READY.toByte())))
                requestKeyframe()
            },
            onKeyframeNeeded = { requestKeyframe() },
            onFailure = {
                if (udpReceiver === self) {
                    udpActive = false
                    udpReceiver?.stop()
                    udpReceiver = null
                    listener.onUdpReady(false)
                    sendFrame(Messages.encodeFrame(MessageType.CTRL.id, byteArrayOf(Ctrl.UDP_FAILED.toByte())))
                }
            }
        )
        self = receiver
        udpReceiver = receiver
        try {
            receiver.start(host, config.port)
        } catch (_: Exception) {
            udpReceiver = null
        }
    }

    fun close() {
        running = false
        sender.shutdownNow()
        feedback?.stop()
        udpReceiver?.stop()
        try {
            connection?.close()
        } catch (_: Exception) {
        }
    }

    private fun noteE2e(captureTsMicros: Long) {
        val offset = clockOffsetMicros ?: return
        val value = E2e.compute(
            nowMicros = SystemClock.elapsedRealtimeNanos() / 1000,
            offsetMicros = offset,
            captureTsMicros = captureTsMicros
        )
        if (value >= 0) stats.setE2eMs(value)
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
        var active: StreamConnection? = null
        try {
            val connection = openConnection()
            active = connection
            this.connection = connection

            val output = connection.output
            output.write(Messages.encodeHello(hello))
            output.flush()
            this.output = output
            connectedOnce = true
            liveness.noteActivity(System.currentTimeMillis())

            val reporter = FeedbackReporter(
                send = { feedback -> sendFrame(UdpProtocol.encodeFeedback(feedback)) },
                lossPermille = { udpReceiver?.lossPermille ?: 0 },
                decodeMS = { stats.currentDecodeMs.toInt() },
                rttMS = { stats.currentRttMs.toInt() },
                droppedFrames = { stats.takeDroppedFrames() },
                queueDepth = { stats.currentQueueDepth },
                arrivalDelayMS = { stats.currentE2eMs.coerceAtLeast(0).toInt() }
            )
            feedback = reporter
            reporter.start()

            val input = connection.input
            val decoder = FrameDecoder()
            val buffer = ByteArray(64 * 1024)

            while (running) {
                maybeSendPing(output)
                connection.prepareRead()
                val read = try {
                    input.read(buffer)
                } catch (_: SocketTimeoutException) {
                    if (liveness.timedOut(System.currentTimeMillis())) {
                        reportClosed("连接无响应")
                        return
                    }
                    continue
                }
                if (read < 0) break

                decoder.append(buffer.copyOf(read))
                while (true) {
                    val frame = decoder.next() ?: break
                    liveness.noteActivity(System.currentTimeMillis())
                    udpReceiver?.noteSessionActive()
                    when (frame.type) {
                        MessageType.SESSION_CONFIG.id ->
                            listener.onConfig(Messages.decodeSessionConfig(frame.payload))

                        MessageType.VIDEO.id -> {
                            if (udpActive) continue
                            val video = Messages.decodeVideo(frame.payload)
                            stats.onVideo(frame.payload.size)
                            feedback?.onVideo(frame.payload.size)
                            noteE2e(video.header.captureTimestampMicros)
                            listener.onVideo(video)
                        }

                        MessageType.PING.id -> {
                            handlePing(frame.payload, output)
                        }

                        MessageType.UDP_CONFIG.id -> {
                            handleUdpConfig(frame.payload)
                        }

                        MessageType.CTRL.id -> {
                            when (frame.payload.firstOrNull()?.toInt()?.and(0xff)) {
                                Ctrl.INPUT_ENABLED -> listener.onInputState(true, null)
                                Ctrl.INPUT_DISABLED -> {
                                    val length = frame.payload.getOrNull(1)?.toInt()?.and(0xff) ?: 0
                                    val reason = if (length > 0) {
                                        String(frame.payload, 2, minOf(length, frame.payload.size - 2), Charsets.UTF_8)
                                    } else {
                                        null
                                    }
                                    listener.onInputState(false, reason)
                                }
                            }
                        }

                        MessageType.BYE.id -> {
                            reportClosed("服务端断开")
                            return
                        }
                    }
                }
            }
            reportClosed("连接已断开")
        } catch (error: Exception) {
            if (running) {
                reportClosed(error.message ?: "连接失败")
            }
        } finally {
            running = false
            udpActive = false
            feedback?.stop()
            feedback = null
            udpReceiver?.stop()
            udpReceiver = null
            try {
                active?.close()
            } catch (_: Exception) {
            }
            this.output = null
            connection = null
        }
    }
}