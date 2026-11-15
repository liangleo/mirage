package app.mirage.net

import java.io.ByteArrayOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.SocketTimeoutException
import java.util.ArrayDeque
import java.util.LinkedHashMap

class UdpVideoReceiver(
    private val key: ByteArray,
    private val noncePrefix: ByteArray,
    private val cipher: UdpCipher,
    private val onFrame: (VideoFrame) -> Unit,
    private val onReady: () -> Unit = {},
    private val onFailure: (String) -> Unit = {},
    private val onLog: ((String) -> Unit)? = null,
    private val clockNanos: () -> Long = System::nanoTime,
    private val rttNanos: () -> Long = { 30_000_000L }
) {
    private class Partial(val fragCount: Int, val firstSeenNanos: Long) {
        val fragments = arrayOfNulls<ByteArray>(fragCount)
        val nacked = BooleanArray(fragCount)
        var received = 0
        var keyFrame = false
    }

    private val lock = Any()
    private val partials = LinkedHashMap<Long, Partial>()
    private val outbox = ArrayDeque<ByteArray>()
    private var lastNackNanos = 0L

    @Volatile
    private var socket: DatagramSocket? = null

    @Volatile
    private var running = false

    @Volatile
    private var ready = false

    private var thread: Thread? = null

    var framesDelivered = 0L
        private set

    var fragmentsReceived = 0L
        private set

    var fragmentsLost = 0L
        private set

    var lossPermille: Int = 0
        private set

    // Lifetime totals never decay, so a single early burst would pin the
    // server's adaptive bitrate at the floor forever. lossPermille is the
    // ratio over the current ~1s window instead.
    private var windowStartNanos = 0L
    private var windowReceived = 0L
    private var windowLost = 0L

    var lastCompletedFrameId: Long = -1
        private set

    fun start(host: String, port: Int) {
        stop()
        running = true
        val address = InetAddress.getByName(host)
        val datagramSocket = DatagramSocket()
        datagramSocket.soTimeout = 50
        datagramSocket.receiveBufferSize = 4 * 1024 * 1024
        socket = datagramSocket
        thread = Thread({ loop(datagramSocket, address, port) }, "mirage-udp").also { it.start() }
    }

    fun stop() {
        running = false
        try {
            socket?.close()
        } catch (_: Exception) {
        }
        socket = null
        thread = null
        synchronized(lock) {
            partials.clear()
            outbox.clear()
            windowStartNanos = 0
            windowReceived = 0
            windowLost = 0
        }
        ready = false
    }

    /** Feeds one raw datagram; returns any control datagrams that must be sent back. */
    fun feed(data: ByteArray, nowNanos: Long = clockNanos()): List<ByteArray> {
        val datagram = try {
            UdpProtocol.decode(data)
        } catch (_: Exception) {
            return emptyList()
        }
        if (datagram.header.isHello) {
            if (!ready) {
                ready = true
                onLog?.invoke("udp ready")
                onReady()
            }
            return emptyList()
        }
        if (datagram.header.isNack) return emptyList()

        val header = datagram.header
        val plain = try {
            UdpCrypto.open(
                payload = datagram.payload,
                headerBytes = data.copyOfRange(0, UdpVideoHeader.SIZE),
                header = header,
                key = key,
                noncePrefix = noncePrefix,
                cipher = cipher
            )
        } catch (error: Exception) {
            onLog?.invoke("udp decrypt failed: ${error.message}")
            return emptyList()
        }

        synchronized(lock) {
            rollWindow(nowNanos)
            val frameID = header.frameID
            if (frameID <= lastCompletedFrameId) return emptyList()
            val partial = partials[frameID] ?: run {
                if (partials.size >= MAX_IN_FLIGHT) {
                    val oldest = partials.entries.first()
                    val missing = oldest.value.fragments.count { it == null }
                    fragmentsLost += missing
                    windowLost += missing
                    partials.remove(oldest.key)
                    updateLoss()
                    onLog?.invoke("drop frame ${oldest.key} (too many in flight)")
                }
                Partial(header.fragCount, nowNanos).also { partials[frameID] = it }
            }
            if (partial.fragCount != header.fragCount) {
                partials.remove(frameID)
                return emptyList()
            }
            if (partial.fragments[header.fragIndex] != null) return emptyList()

            partial.fragments[header.fragIndex] = plain
            partial.received++
            if (header.isKeyFrame) partial.keyFrame = true
            fragmentsReceived++
            windowReceived++
            updateLoss()

            if (partial.received == partial.fragCount) {
                assemble(frameID, partial)
            }
        }
        return drainOutbox()
    }

    /** Emits NACKs for frames that stayed incomplete, and drops frames past their deadline. */
    fun tick(nowNanos: Long = clockNanos()): List<ByteArray> {
        synchronized(lock) {
            rollWindow(nowNanos)
            val deadline = maxOf(rttNanos() * 3, 150_000_000L)
            val nackAfter = maxOf(rttNanos(), 20_000_000L)

            partials.entries.removeAll { (frameID, partial) ->
                if (nowNanos - partial.firstSeenNanos <= deadline) return@removeAll false
                val missing = partial.fragments.count { it == null }
                fragmentsLost += missing
                windowLost += missing
                updateLoss()
                onLog?.invoke("drop frame $frameID (deadline)")
                true
            }

            val iterator = partials.iterator()
            while (iterator.hasNext()) {
                val (frameID, partial) = iterator.next()
                val waited = nowNanos - partial.firstSeenNanos
                if (waited < nackAfter || nowNanos - lastNackNanos < NACK_INTERVAL_NANOS) continue

                var firstMissing = -1
                var lastMissing = -1
                for (index in 0 until partial.fragCount) {
                    if (partial.fragments[index] == null && !partial.nacked[index]) {
                        if (firstMissing < 0) firstMissing = index
                        lastMissing = index
                    }
                }
                if (firstMissing < 0) continue

                val length = lastMissing - firstMissing + 1
                val bitmap = ByteArray((length + 7) / 8)
                for (index in firstMissing..lastMissing) {
                    if (partial.fragments[index] != null) continue
                    partial.nacked[index] = true
                    val bit = index - firstMissing
                    bitmap[bit / 8] = (bitmap[bit / 8].toInt() or (1 shl (bit % 8))).toByte()
                }

                outbox.add(
                    UdpProtocol.encodeNack(
                        seq = 0,
                        frameID = frameID,
                        bitmapStart = firstMissing,
                        bitmap = bitmap
                    )
                )
                lastNackNanos = nowNanos
                break
            }
        }
        return drainOutbox()
    }

    fun drainOutbox(): List<ByteArray> = synchronized(lock) {
        if (outbox.isEmpty()) return emptyList()
        val items = ArrayList<ByteArray>(outbox.size)
        while (outbox.isNotEmpty()) items.add(outbox.removeFirst())
        items
    }

    private fun assemble(frameID: Long, partial: Partial) {
        val output = ByteArrayOutputStream()
        for (fragment in partial.fragments) {
            output.write(fragment!!)
        }
        partials.remove(frameID)
        framesDelivered++
        lastCompletedFrameId = frameID
        val frame = VideoFrame(
            header = VideoHeader(
                codec = 1,
                flags = if (partial.keyFrame) 1 else 0,
                frameID = frameID,
                captureTimestampMicros = 0,
                reserved = 0
            ),
            annexB = output.toByteArray()
        )
        onFrame(frame)
    }

    private fun rollWindow(nowNanos: Long) {
        if (nowNanos - windowStartNanos < WINDOW_NANOS) return
        windowStartNanos = nowNanos
        windowReceived = 0
        windowLost = 0
    }

    private fun updateLoss() {
        val total = windowReceived + windowLost
        lossPermille = if (total == 0L) 0 else (windowLost * 1000 / total).toInt()
    }

    private fun loop(socket: DatagramSocket, address: InetAddress, port: Int) {
        val hello = helloDatagram()
        var lastHello = 0L
        val startedAt = clockNanos()
        val buffer = ByteArray(2048)

        try {
            while (running) {
                val now = clockNanos()
                if (!ready && now - lastHello > 500_000_000L) {
                    socket.send(DatagramPacket(hello, hello.size, address, port))
                    lastHello = now
                }
                if (!ready && now - startedAt > 5_000_000_000L) {
                    onFailure("UDP 无响应")
                    return
                }

                for (datagram in tick(now)) {
                    socket.send(DatagramPacket(datagram, datagram.size, address, port))
                }

                val packet = DatagramPacket(buffer, buffer.size)
                try {
                    socket.receive(packet)
                } catch (_: SocketTimeoutException) {
                    continue
                }
                if (!packet.address.equals(address) || packet.port != port) continue
                val data = packet.data.copyOfRange(packet.offset, packet.offset + packet.length)
                for (datagram in feed(data, clockNanos())) {
                    socket.send(DatagramPacket(datagram, datagram.size, address, port))
                }
            }
        } catch (error: Exception) {
            if (running) onFailure(error.message ?: "UDP 接收失败")
        } finally {
            running = false
        }
    }

    private fun helloDatagram(): ByteArray = UdpProtocol.encode(
        UdpDatagram(
            header = UdpVideoHeader(
                seq = 1,
                frameID = 0,
                fragIndex = 0,
                fragCount = 1,
                flags = UdpFlags.HELLO,
                payloadLength = 0
            ),
            payload = ByteArray(0)
        )
    )

    private companion object {
        const val MAX_IN_FLIGHT = 3
        const val NACK_INTERVAL_NANOS = 10_000_000L
        const val WINDOW_NANOS = 1_000_000_000L
    }
}