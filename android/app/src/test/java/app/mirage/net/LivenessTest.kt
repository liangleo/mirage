package app.mirage.net

import app.mirage.video.DecodeQueue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StreamStatsTest {
    @Test
    fun computesFpsAndBitrateOverInterval() {
        val stats = StreamStats()
        stats.onVideo(byteCount = 125_000, nowMs = 1_000)

        val snapshot = stats.snapshot(nowMs = 2_000)
        assertEquals(1, snapshot.fps)
        assertEquals(1.0, snapshot.bitrateMbps, 0.001)

        val idle = stats.snapshot(nowMs = 3_000)
        assertEquals(0, idle.fps)
    }

    @Test
    fun tracksDecodeTimeAndDrops() {
        val stats = StreamStats()
        stats.setDecodeMs(7)
        stats.onDropped()

        val snapshot = stats.snapshot(nowMs = 1_000)
        assertEquals(7, snapshot.decodeMs)
        assertEquals(1, snapshot.dropped)
    }
}

class DecodeQueueTest {
    private fun frame(keyframe: Boolean, id: Int): VideoFrame =
        VideoFrame(
            VideoHeader(1, if (keyframe) 1 else 0, id.toLong(), 0, 0),
            ByteArray(1) { id.toByte() }
        )

    @Test
    fun dropsOldestWhenFull() {
        val queue = DecodeQueue(capacity = 2)
        assertFalse(queue.offer(frame(false, 1)))
        assertFalse(queue.offer(frame(false, 2)))
        assertTrue(queue.offer(frame(false, 3)))

        assertEquals(2, queue.size())
        assertEquals(2L, queue.poll(0)!!.header.frameID)
        assertEquals(3L, queue.poll(0)!!.header.frameID)
    }

    @Test
    fun keyframeClearsBacklog() {
        val queue = DecodeQueue(capacity = 2)
        queue.offer(frame(false, 1))
        queue.offer(frame(false, 2))
        assertTrue(queue.offer(frame(true, 3)))

        assertEquals(1, queue.size())
        assertEquals(3L, queue.poll(0)!!.header.frameID)
    }

    @Test
    fun pollTimesOutWithNull() {
        val queue = DecodeQueue(capacity = 1)
        assertNull(queue.poll(10))
    }
}