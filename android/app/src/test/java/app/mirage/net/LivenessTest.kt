package app.mirage.net

import app.mirage.video.DecodeQueue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class LivenessTest {
    @Test
    fun staysAliveWhileFramesArrive() {
        val liveness = Liveness(timeoutMs = 3_000)
        liveness.noteActivity(1_000)
        assertEquals(false, liveness.timedOut(3_999))
        assertEquals(true, liveness.timedOut(4_001))
    }
}

class DecodeQueueTest {
    private fun frame(keyframe: Boolean, id: Int): VideoFrame =
        VideoFrame(
            VideoHeader(1, if (keyframe) 1 else 0, id.toLong(), 0, 0),
            ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(id).array()
        )

    @Test
    fun dropsOldestWhenFull() {
        val queue = DecodeQueue(capacity = 2)
        queue.offer(frame(false, 1))
        queue.offer(frame(false, 2))
        queue.offer(frame(false, 3))

        assertEquals(2, queue.size())
        assertEquals(2L, queue.poll(0)!!.header.frameID)
        assertEquals(3L, queue.poll(0)!!.header.frameID)
    }

    @Test
    fun keyframeClearsBacklog() {
        val queue = DecodeQueue(capacity = 2)
        queue.offer(frame(false, 1))
        queue.offer(frame(false, 2))
        queue.offer(frame(true, 3))

        assertEquals(1, queue.size())
        assertEquals(3L, queue.poll(0)!!.header.frameID)
    }

    @Test
    fun pollTimesOutWithNull() {
        val queue = DecodeQueue(capacity = 1)
        assertNull(queue.poll(10))
    }
}