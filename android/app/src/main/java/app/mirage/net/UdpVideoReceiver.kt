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
    private val onKeyframeNeeded: () -> Unit = {},
    private val onLog: ((String) -> Unit)? = null,
    private val clockNanos: () -> Long = System::nanoTime
) {
    private class Partial(val fragCount: Int, val firstSeenNanos: Long) {
        val fragments = arrayOfNulls<ByteArray>(fragCount)
        var received = 0
        var keyFrame = false
        var captureTsMicros = 0L
        var eofSeen = false
        var triggerNanos: Long? = null
        var nackRounds = 0
    }

    private val lock = Any()
    private val partials = LinkedHashMap<Long, Partial>()
    private val outbox = ArrayDeque<ByteArray>()
    private var lastNackNanos = -1L

    @Volatile
    private var socket: DatagramSocket? = null

    @Volatile
    private var running = false

    @Volatile
    private var ready = false

    @Volatile
    private var failureReported = false
    private var firstActivityNanos = -1L
    private var lastDatagramNanos = -1L

    @Volatile
    private var streamStartedNanos = -1L
    private var nextDeliverId = -1L
    private var gapSinceNanos = -1L
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
    private var windowStartNanos = -1L
    private var windowReceived = 0L
    private var windowLost = 0L

    var lastCompletedFrameId: Long = -1
        private set

    fun start(host: String, port: Int) {
        stop()
        running = true
        markActivity(clockNanos())
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
            windowStartNanos = -1
            windowReceived = 0
            windowLost = 0
            failureReported = false
            firstActivityNanos = -1
            lastDatagramNanos = -1
            streamStartedNanos = -1
            nextDeliverId = -1
            gapSinceNanos = -1
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
        markActivity(nowNanos)
        lastDatagramNanos = nowNanos
        if (datagram.header.isHello) {
            onLog?.invoke("udp peer ready")
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
            if (nextDeliverId < 0) nextDeliverId = frameID
            if (frameID < nextDeliverId) return emptyList()

            val partial = partials[frameID] ?: run {
                if (partials.size >= MAX_IN_FLIGHT) {
                    val oldest = partials.entries.first()
                    dropPartial(oldest.key, oldest.value)
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
            if (partial.received == 1) partial.captureTsMicros = header.captureTsMicros
            if (header.isKeyFrame) partial.keyFrame = true
            if (header.isEOF) {
                partial.eofSeen = true
                if (partial.triggerNanos == null) partial.triggerNanos = nowNanos
            }
            fragmentsReceived++
            windowReceived++
            updateLoss()

            for (entry in partials) {
                if (entry.key >= frameID) break
                if (entry.value.received < entry.value.fragCount && entry.value.triggerNanos == null) {
                    entry.value.triggerNanos = nowNanos
                }
            }

            deliverReady(nowNanos)
        }
        return drainOutbox()
    }

    /** Emits NACKs for frames that stayed incomplete, delivers ready frames, and checks timeouts. */
    fun tick(nowNanos: Long = clockNanos()): List<ByteArray> {
        markActivity(nowNanos)
        synchronized(lock) {
            rollWindow(nowNanos)
            deliverReady(nowNanos)
            nackMissing(nowNanos)
            checkFailure(nowNanos)
        }
        return drainOutbox()
    }

    /** Control-channel activity keeps UDP alive on static screens where no frames are sent. */
    fun noteSessionActive(nowNanos: Long = clockNanos()) {
        lastDatagramNanos = nowNanos
    }

    fun drainOutbox(): List<ByteArray> = synchronized(lock) {
        if (outbox.isEmpty()) return emptyList()
        val items = ArrayList<ByteArray>(outbox.size)
        while (outbox.isNotEmpty()) items.add(outbox.removeFirst())
        items
    }

    private fun deliverReady(nowNanos: Long) {
        while (nextDeliverId >= 0) {
            val head = partials[nextDeliverId]
            if (head != null && head.received == head.fragCount) {
                deliver(nextDeliverId, head)
                partials.remove(nextDeliverId)
                nextDeliverId++
                gapSinceNanos = -1
                continue
            }
            if (head != null) {
                if (nowNanos - head.firstSeenNanos > HEAD_TIMEOUT_NANOS) {
                    dropPartial(nextDeliverId, head)
                    onLog?.invoke("drop frame $nextDeliverId (missing fragments)")
                    nextDeliverId++
                    gapSinceNanos = -1
                    onKeyframeNeeded()
                    continue
                }
                return
            }
            val next = partials.keys.firstOrNull { it > nextDeliverId } ?: return
            if (gapSinceNanos < 0) {
                gapSinceNanos = nowNanos
                return
            }
            if (nowNanos - gapSinceNanos <= HEAD_TIMEOUT_NANOS) return
            fragmentsLost += (next - nextDeliverId)
            windowLost += (next - nextDeliverId)
            updateLoss()
            onLog?.invoke("drop frames $nextDeliverId..${next - 1} (never arrived)")
            nextDeliverId = next
            gapSinceNanos = -1
            onKeyframeNeeded()
        }
    }

    private fun nackMissing(nowNanos: Long) {
        if (lastNackNanos >= 0 && nowNanos - lastNackNanos < NACK_INTERVAL_NANOS) return
        for (partial in partials.values) {
            if (partial.received == partial.fragCount) continue
            if (partial.nackRounds >= MAX_NACK_ROUNDS) continue
            val trigger = partial.triggerNanos ?: continue
            if (nowNanos - trigger < NACK_DELAY_NANOS) continue

            var firstMissing = -1
            var lastMissing = -1
            for (index in 0 until partial.fragCount) {
                if (partial.fragments[index] == null) {
                    if (firstMissing < 0) firstMissing = index
                    lastMissing = index
                }
            }
            if (firstMissing < 0) continue

            val bitmap = ByteArray((lastMissing - firstMissing + 8) / 8)
            for (index in firstMissing..lastMissing) {
                if (partial.fragments[index] != null) continue
                val bit = index - firstMissing
                bitmap[bit / 8] = (bitmap[bit / 8].toInt() or (1 shl (bit % 8))).toByte()
            }
            outbox.add(
                UdpProtocol.encodeNack(
                    seq = 0,
                    frameID = partials.entries.first { it.value === partial }.key,
                    bitmapStart = firstMissing,
                    bitmap = bitmap
                )
            )
            partial.nackRounds++
            lastNackNanos = nowNanos
            return
        }
    }

    private fun checkFailure(nowNanos: Long) {
        if (failureReported) return
        if (streamStartedNanos < 0 && nowNanos - firstActivityNanos > START_TIMEOUT_NANOS) {
            failureReported = true
            onFailure("UDP 无响应")
            return
        }
        if (streamStartedNanos >= 0 && nowNanos - lastDatagramNanos > SILENCE_TIMEOUT_NANOS) {
            failureReported = true
            onFailure("UDP 无数据")
        }
    }

    private fun dropPartial(frameID: Long, partial: Partial) {
        val missing = partial.fragments.count { it == null }
        fragmentsLost += missing
        windowLost += missing
        partials.remove(frameID)
        updateLoss()
    }

    private fun deliver(frameID: Long, partial: Partial) {
        val output = ByteArrayOutputStream()
        for (fragment in partial.fragments) {
            output.write(fragment!!)
        }
        if (streamStartedNanos < 0) streamStartedNanos = partial.firstSeenNanos
        framesDelivered++
        lastCompletedFrameId = frameID
        val frame = VideoFrame(
            header = VideoHeader(
                codec = 1,
                flags = if (partial.keyFrame) 1 else 0,
                frameID = frameID,
                captureTimestampMicros = partial.captureTsMicros,
                reserved = 0
            ),
            annexB = output.toByteArray()
        )
        if (!ready) {
            ready = true
            onReady()
        }
        onFrame(frame)
    }

    private fun markActivity(nowNanos: Long) {
        if (firstActivityNanos < 0) firstActivityNanos = nowNanos
    }

    private fun rollWindow(nowNanos: Long) {
        if (windowStartNanos < 0) {
            windowStartNanos = nowNanos
            return
        }
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
        val buffer = ByteArray(2048)

        try {
            while (running) {
                val now = clockNanos()
                if (streamStartedNanos < 0 && now - lastHello > 500_000_000L) {
                    socket.send(DatagramPacket(hello, hello.size, address, port))
                    lastHello = now
                }

                for (datagram in tick(now)) {
                    socket.send(DatagramPacket(datagram, datagram.size, address, port))
                }
                if (failureReported) return

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
            if (running && !failureReported) onFailure(error.message ?: "UDP 接收失败")
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
        const val MAX_IN_FLIGHT = 16
        const val MAX_NACK_ROUNDS = 3
        const val NACK_DELAY_NANOS = 6_000_000L
        const val NACK_INTERVAL_NANOS = 10_000_000L
        const val HEAD_TIMEOUT_NANOS = 200_000_000L
        const val START_TIMEOUT_NANOS = 30_000_000_000L
        const val SILENCE_TIMEOUT_NANOS = 10_000_000_000L
        const val WINDOW_NANOS = 1_000_000_000L
    }
}