package app.mirage.net

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

class UdpVideoReceiverTest {
    private val key = ByteArray(32) { it.toByte() }
    private val noncePrefix = byteArrayOf(1, 2, 3, 4)
    private val frames = mutableListOf<VideoFrame>()
    private var seq = 1L

    private fun receiver(
        onKeyframeNeeded: () -> Unit = {},
        onFailure: (String) -> Unit = {}
    ) = UdpVideoReceiver(
        key = key,
        noncePrefix = noncePrefix,
        cipher = UdpCipher.AES_256_GCM,
        onFrame = { frames.add(it) },
        onKeyframeNeeded = onKeyframeNeeded,
        onFailure = onFailure
    )

    private fun headerBytes(
        frameID: Long,
        index: Int,
        count: Int,
        flags: Int,
        payloadLength: Int,
        seq: Long,
        captureTsMicros: Long = 0
    ): ByteArray = ByteBuffer.allocate(UdpVideoHeader.SIZE)
        .order(ByteOrder.BIG_ENDIAN)
        .putInt(seq.toInt())
        .putInt(frameID.toInt())
        .putShort(index.toShort())
        .putShort(count.toShort())
        .put(flags.toByte())
        .put(0)
        .putShort(payloadLength.toShort())
        .putLong(captureTsMicros)
        .array()

    private fun datagram(
        frameID: Long,
        index: Int,
        count: Int,
        payload: ByteArray,
        keyFrame: Boolean = false,
        captureTsMicros: Long = 0
    ): ByteArray {
        var flags = 0
        if (index == 0) flags = flags or UdpFlags.SOF
        if (index == count - 1) flags = flags or UdpFlags.EOF
        if (keyFrame) flags = flags or UdpFlags.KEY
        val sequence = seq++
        val header = headerBytes(frameID, index, count, flags, payload.size + 16, sequence, captureTsMicros)

        val nonce = ByteArray(12)
        System.arraycopy(noncePrefix, 0, nonce, 0, 4)
        var value = sequence
        for (i in 11 downTo 4) {
            nonce[i] = (value and 0xff).toByte()
            value = value ushr 8
        }
        val encrypt = Cipher.getInstance("AES/GCM/NoPadding")
        encrypt.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        encrypt.updateAAD(header)
        return header + encrypt.doFinal(payload)
    }

    @Test
    fun reassemblesOutOfOrderFragments() {
        val receiver = receiver()
        val parts = listOf(ByteArray(5) { 1 }, ByteArray(5) { 2 }, ByteArray(5) { 3 })

        receiver.feed(datagram(7, 2, 3, parts[2], keyFrame = true), nowNanos = 0)
        receiver.feed(datagram(7, 0, 3, parts[0], keyFrame = true), nowNanos = 0)
        assertTrue(frames.isEmpty())

        receiver.feed(datagram(7, 1, 3, parts[1], keyFrame = true), nowNanos = 0)
        assertEquals(1, frames.size)
        assertEquals(7L, frames[0].header.frameID)
        assertEquals(1, frames[0].header.flags and 1)
        assertArrayEquals(parts[0] + parts[1] + parts[2], frames[0].annexB)
        assertEquals(3L, receiver.fragmentsReceived)
        assertEquals(0, receiver.lossPermille)
    }

    @Test
    fun duplicateFragmentDoesNotDuplicateData() {
        val receiver = receiver()
        receiver.feed(datagram(3, 0, 2, ByteArray(4) { 1 }), nowNanos = 0)
        receiver.feed(datagram(3, 0, 2, ByteArray(4) { 1 }), nowNanos = 0)
        receiver.feed(datagram(3, 1, 2, ByteArray(4) { 2 }), nowNanos = 0)

        assertEquals(1, frames.size)
        assertEquals(8, frames[0].annexB.size)
        assertEquals(2L, receiver.fragmentsReceived)
    }

    @Test
    fun missingFragmentTriggersSingleNackAndRecovers() {
        val receiver = receiver()
        receiver.feed(datagram(9, 0, 3, ByteArray(4) { 1 }), nowNanos = 0)
        receiver.feed(datagram(9, 2, 3, ByteArray(4) { 3 }), nowNanos = 0)

        assertTrue(receiver.tick(nowNanos = 5_000_000L).isEmpty())
        val nacks = receiver.tick(nowNanos = 25_000_000L)
        assertEquals(1, nacks.size)
        val nack = UdpProtocol.decode(nacks[0])
        assertTrue(nack.header.isNack)
        assertEquals(9L, nack.header.frameID)
        assertEquals(1, nack.header.fragIndex)
        assertArrayEquals(byteArrayOf(0b1), nack.payload)

        assertTrue(receiver.tick(nowNanos = 30_000_000L).isEmpty())
        receiver.feed(datagram(9, 1, 3, ByteArray(4) { 2 }), nowNanos = 35_000_000L)
        assertEquals(1, frames.size)
        assertEquals(12, frames[0].annexB.size)
    }

    @Test
    fun deadlineDropsFrameWithoutBlockingNextOne() {
        val receiver = receiver()
        receiver.feed(datagram(1, 0, 2, ByteArray(4) { 1 }), nowNanos = 0)

        receiver.tick(nowNanos = 500_000_000L)
        receiver.feed(datagram(2, 0, 1, ByteArray(4) { 9 }), nowNanos = 510_000_000L)

        assertEquals(1, frames.size)
        assertEquals(2L, frames[0].header.frameID)
        assertTrue(receiver.fragmentsLost >= 1)
        assertTrue(receiver.lossPermille > 0)
    }

    @Test
    fun lossPermilleDecaysAfterCleanWindow() {
        val receiver = receiver()
        receiver.feed(datagram(1, 0, 2, ByteArray(4) { 1 }), nowNanos = 0)
        receiver.tick(nowNanos = 500_000_000L)
        assertTrue(receiver.lossPermille > 0)

        receiver.feed(datagram(2, 0, 1, ByteArray(4) { 2 }), nowNanos = 1_600_000_000L)
        assertEquals(0, receiver.lossPermille)
    }

    @Test
    fun lateFragmentOfCompletedFrameIsIgnored() {
        val receiver = receiver()
        receiver.feed(datagram(5, 0, 1, ByteArray(4) { 5 }), nowNanos = 0)
        assertEquals(1, frames.size)

        receiver.feed(datagram(5, 0, 1, ByteArray(4) { 6 }), nowNanos = 10)
        receiver.feed(datagram(6, 0, 1, ByteArray(4) { 7 }), nowNanos = 20)

        assertEquals(2, frames.size)
        assertEquals(6L, frames[1].header.frameID)
        assertArrayEquals(ByteArray(4) { 7 }, frames[1].annexB)
    }

    @Test
    fun rejectsMalformedAndTamperedDatagrams() {
        val receiver = receiver()
        assertTrue(receiver.feed(ByteArray(8), nowNanos = 0).isEmpty())

        val valid = datagram(4, 0, 1, ByteArray(6) { 1 })
        valid[valid.size - 1] = (valid[valid.size - 1].toInt() xor 0xFF).toByte()
        assertTrue(receiver.feed(valid, nowNanos = 0).isEmpty())
        assertTrue(frames.isEmpty())

        val oversized = ByteBuffer.allocate(UdpVideoHeader.SIZE + 1217)
            .order(ByteOrder.BIG_ENDIAN)
            .putInt(1).putInt(1).putShort(0).putShort(1)
            .put(0).put(0).putShort(1217).putLong(0)
            .put(ByteArray(1217))
            .array()
        assertTrue(receiver.feed(oversized, nowNanos = 0).isEmpty())
        assertTrue(frames.isEmpty())
    }

    @Test
    fun captureTimestampReachesVideoFrame() {
        val receiver = receiver()
        receiver.feed(datagram(11, 0, 1, ByteArray(4) { 1 }, captureTsMicros = 123_456), nowNanos = 0)

        assertEquals(1, frames.size)
        assertEquals(123_456L, frames[0].header.captureTimestampMicros)
    }

    @Test
    fun helloAckDoesNotBecomeReady() {
        var ready = false
        val receiver = UdpVideoReceiver(
            key = key,
            noncePrefix = noncePrefix,
            cipher = UdpCipher.AES_256_GCM,
            onFrame = { frames.add(it) },
            onReady = { ready = true }
        )
        val hello = UdpProtocol.encode(
            UdpDatagram(
                UdpVideoHeader(1, 0, 0, 1, UdpFlags.HELLO, payloadLength = 0),
                ByteArray(0)
            )
        )
        receiver.feed(hello, nowNanos = 0)
        assertTrue(!ready)
        assertNotNull(receiver)
    }

    @Test
    fun firstCompleteFrameTriggersReadyOnce() {
        var readyCount = 0
        val receiver = UdpVideoReceiver(
            key = key,
            noncePrefix = noncePrefix,
            cipher = UdpCipher.AES_256_GCM,
            onFrame = { frames.add(it) },
            onReady = { readyCount++ }
        )
        receiver.feed(datagram(1, 0, 1, ByteArray(4) { 1 }), nowNanos = 0)
        receiver.feed(datagram(2, 0, 1, ByteArray(4) { 2 }), nowNanos = 10)

        assertEquals(1, readyCount)
        assertEquals(2, frames.size)
    }

    @Test
    fun framesAreDeliveredInFrameIdOrder() {
        val receiver = receiver()
        receiver.feed(datagram(1, 0, 2, ByteArray(4) { 1 }), nowNanos = 0)
        receiver.feed(datagram(2, 0, 1, ByteArray(4) { 2 }), nowNanos = 5)
        assertTrue(frames.isEmpty())

        receiver.feed(datagram(1, 1, 2, ByteArray(4) { 1 }), nowNanos = 10)
        assertEquals(listOf(1L, 2L), frames.map { it.header.frameID })
    }

    @Test
    fun missingHeadAbandonedAfter200msAndRequestsKeyframe() {
        var keyframes = 0
        val receiver = receiver(onKeyframeNeeded = { keyframes++ })
        receiver.feed(datagram(1, 0, 2, ByteArray(4) { 1 }), nowNanos = 0)
        receiver.feed(datagram(2, 0, 1, ByteArray(4) { 2 }), nowNanos = 5)

        receiver.tick(nowNanos = 100_000_000L)
        assertTrue(frames.isEmpty())

        receiver.tick(nowNanos = 250_000_000L)
        assertEquals(1, frames.size)
        assertEquals(2L, frames[0].header.frameID)
        assertTrue(keyframes >= 1)
    }

    @Test
    fun nackIsSentAtMostThreeRounds() {
        val receiver = receiver()
        receiver.feed(datagram(1, 0, 2, ByteArray(4) { 1 }), nowNanos = 0)
        receiver.feed(datagram(2, 0, 1, ByteArray(4) { 2 }), nowNanos = 0)

        assertEquals(1, receiver.tick(nowNanos = 7_000_000L).size)
        assertEquals(1, receiver.tick(nowNanos = 20_000_000L).size)
        assertEquals(1, receiver.tick(nowNanos = 33_000_000L).size)
        assertTrue(receiver.tick(nowNanos = 60_000_000L).isEmpty())
    }

    @Test
    fun failsAfter30sWithoutAnyFrame() {
        var failure: String? = null
        val receiver = receiver(onFailure = { failure = it })
        receiver.feed(datagram(1, 0, 2, ByteArray(4) { 1 }), nowNanos = 0)
        receiver.tick(nowNanos = 29_000_000_000L)
        assertTrue(failure == null)

        receiver.tick(nowNanos = 31_000_000_000L)
        assertEquals("UDP 无响应", failure)
    }

    @Test
    fun failsAfter10sSilenceOnceStreaming() {
        var failure: String? = null
        val receiver = receiver(onFailure = { failure = it })
        receiver.feed(datagram(1, 0, 1, ByteArray(4) { 1 }), nowNanos = 0)
        receiver.tick(nowNanos = 9_000_000_000L)
        assertTrue(failure == null)

        receiver.tick(nowNanos = 11_000_000_000L)
        assertEquals("UDP 无数据", failure)
    }

    @Test
    fun lateDuplicateAfterDeliveryIsIgnored() {
        val receiver = receiver()
        receiver.feed(datagram(1, 0, 1, ByteArray(4) { 1 }), nowNanos = 0)
        receiver.feed(datagram(1, 0, 1, ByteArray(4) { 9 }), nowNanos = 5)
        receiver.feed(datagram(2, 0, 1, ByteArray(4) { 2 }), nowNanos = 10)

        assertEquals(listOf(1L, 2L), frames.map { it.header.frameID })
    }
}