package app.mirage.net

import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException

class MirageClient(
    private val host: String,
    private val port: Int,
    private val hello: Hello,
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
                            listener.onVideo(Messages.decodeVideo(frame.payload))
                        }

                        MessageType.PING.id -> {
                            synchronized(output) {
                                output.write(Messages.encodePing(Messages.decodePing(frame.payload)))
                                output.flush()
                            }
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