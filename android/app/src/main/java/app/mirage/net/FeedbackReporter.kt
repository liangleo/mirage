package app.mirage.net

class FeedbackReporter(
    private val send: (Feedback) -> Unit,
    private val lossPermille: () -> Int = { 0 },
    private val decodeMS: () -> Int = { 0 },
    private val rttMS: () -> Int = { 0 },
    private val intervalMillis: Long = 100,
    private val clockMillis: () -> Long = System::currentTimeMillis,
    private val clockNanos: () -> Long = System::nanoTime
) {
    private var frames = 0
    private var bytes = 0L
    private var lastTickMillis = 0L

    @Volatile
    private var running = false

    private var thread: Thread? = null

    @Synchronized
    fun onVideo(byteCount: Int) {
        frames++
        bytes += byteCount
    }

    fun start() {
        if (running) return
        running = true
        lastTickMillis = clockMillis()
        thread = Thread({
            while (running) {
                try {
                    Thread.sleep(intervalMillis)
                } catch (_: InterruptedException) {
                    return@Thread
                }
                if (!running) return@Thread
                send(build(clockMillis()))
            }
        }, "mirage-feedback").also { it.start() }
    }

    fun stop() {
        running = false
        thread = null
    }

    fun build(nowMillis: Long): Feedback {
        val (fps, bitrate) = synchronized(this) {
            if (lastTickMillis == 0L) lastTickMillis = nowMillis
            val elapsed = (nowMillis - lastTickMillis).coerceAtLeast(1)
            val fps = (frames * 1000 / elapsed).toInt()
            val bitrate = bytes * 8 * 1000 / elapsed
            frames = 0
            bytes = 0
            lastTickMillis = nowMillis
            fps to bitrate
        }
        return Feedback(
            fpsX10 = (fps * 10).coerceIn(0, 0xffff),
            decodeMS = decodeMS().coerceIn(0, 0xffff),
            droppedFrames = 0,
            queueDepth = 0,
            rttMS = rttMS().coerceIn(0, 0xffff),
            lossPermille = lossPermille().coerceIn(0, 0xffff),
            recvBitrateBps = bitrate.coerceIn(0, 0xffffffffL),
            arrivalDelayMS = 0,
            timestampMicros = clockNanos() / 1000
        )
    }
}