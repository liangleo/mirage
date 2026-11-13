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

    @Volatile
    private var running = true

    @Volatile
    private var socket: Socket? = null

    fun connect() {
        thread.start()
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
            output.write(Messages.encodeHello(hello))
            output.flush()

            val input = connection.getInputStream()
            val decoder = FrameDecoder()
            val buffer = ByteArray(64 * 1024)
            var lastFrameAt = System.currentTimeMillis()

            while (running) {
                connection.soTimeout = 1_000
                val read = try {
                    input.read(buffer)
                } catch (_: SocketTimeoutException) {
                    if (System.currentTimeMillis() - lastFrameAt > 3_000) {
                        listener.onClosed("连接无响应")
                        return
                    }
                    continue
                }
                if (read < 0) break

                decoder.append(buffer.copyOf(read))
                while (true) {
                    val frame = decoder.next() ?: break
                    when (frame.type) {
                        MessageType.SESSION_CONFIG.id ->
                            listener.onConfig(Messages.decodeSessionConfig(frame.payload))

                        MessageType.VIDEO.id -> {
                            listener.onVideo(Messages.decodeVideo(frame.payload))
                            lastFrameAt = System.currentTimeMillis()
                        }

                        MessageType.PING.id -> {
                            output.write(Messages.encodePing(Messages.decodePing(frame.payload)))
                            output.flush()
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
            try {
                socket?.close()
            } catch (_: Exception) {
            }
            socket = null
        }
    }
}