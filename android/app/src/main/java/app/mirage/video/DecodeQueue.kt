package app.mirage.video

import app.mirage.net.VideoFrame
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

class DecodeQueue(capacity: Int = 4) {
    private val queue = ArrayBlockingQueue<VideoFrame>(capacity)

    fun offer(frame: VideoFrame) {
        if (queue.offer(frame)) return

        if (frame.header.flags and 1 != 0) {
            queue.clear()
            queue.offer(frame)
        } else {
            queue.poll()
            queue.offer(frame)
        }
    }

    fun poll(timeoutMs: Long): VideoFrame? = queue.poll(timeoutMs, TimeUnit.MILLISECONDS)

    fun clear() {
        queue.clear()
    }

    fun size(): Int = queue.size
}