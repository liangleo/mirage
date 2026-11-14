package app.mirage.video

import app.mirage.net.VideoFrame
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

class DecodeQueue(capacity: Int = 4) {
    private val queue = ArrayBlockingQueue<VideoFrame>(capacity)

    /** Returns true when at least one queued frame was dropped to make room. */
    fun offer(frame: VideoFrame): Boolean {
        if (queue.offer(frame)) return false

        if (frame.header.flags and 1 != 0) {
            val dropped = queue.size
            queue.clear()
            queue.offer(frame)
            return dropped > 0
        }

        queue.poll()
        queue.offer(frame)
        return true
    }

    fun poll(timeoutMs: Long): VideoFrame? = queue.poll(timeoutMs, TimeUnit.MILLISECONDS)

    fun clear() {
        queue.clear()
    }

    fun size(): Int = queue.size
}