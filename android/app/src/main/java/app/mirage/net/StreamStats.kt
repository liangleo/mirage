package app.mirage.net

data class StatsSnapshot(
    val fps: Int = 0,
    val decodeMs: Long = 0,
    val bitrateMbps: Double = 0.0,
    val dropped: Int = 0,
    val e2eMs: Long = -1,
    val rttMs: Long = -1,
    val codec: String = "",
    val e2eP95Ms: Long = -1
)

class StreamStats {
    private var frames = 0
    private var bytes = 0L
    private var lastTickMs = 0L

    @Volatile
    private var decodeMs = 0L

    @Volatile
    private var dropped = 0

    @Volatile
    private var e2eMs = -1L

    @Volatile
    private var queueDepth = 0

    private var reportedDropped = 0

    private val e2eSamples = ArrayDeque<Long>()

    @Volatile
    private var rttMs = -1L

    @Volatile
    private var codecLabel = ""

    @Synchronized
    fun onVideo(byteCount: Int, nowMs: Long = System.currentTimeMillis()) {
        if (lastTickMs == 0L) {
            lastTickMs = nowMs
        }
        frames++
        bytes += byteCount
    }

    @Synchronized
    fun onDropped() {
        dropped++
    }

    fun setDecodeMs(value: Long) {
        decodeMs = value
    }

    @Synchronized
    fun setE2eMs(value: Long) {
        e2eMs = value
        if (value < 0) return
        if (e2eSamples.size == MAX_E2E_SAMPLES) e2eSamples.removeFirst()
        e2eSamples.addLast(value)
    }

    fun setRttMs(value: Long) {
        rttMs = value
    }

    fun setCodecLabel(value: String) {
        codecLabel = value
    }

    val currentDecodeMs: Long get() = decodeMs
    val currentRttMs: Long get() = rttMs
    val currentE2eMs: Long get() = e2eMs
    val currentQueueDepth: Int get() = queueDepth

    fun setQueueDepth(value: Int) {
        queueDepth = value
    }

    @Synchronized
    fun takeDroppedFrames(): Int {
        val delta = dropped - reportedDropped
        reportedDropped = dropped
        return delta
    }

    @Synchronized
    fun snapshot(nowMs: Long = System.currentTimeMillis()): StatsSnapshot {
        if (lastTickMs == 0L) {
            lastTickMs = nowMs
        }
        val elapsed = (nowMs - lastTickMs).coerceAtLeast(1)
        val fps = (frames * 1000 / elapsed).toInt()
        val bitrateMbps = bytes * 8.0 / elapsed / 1000.0
        frames = 0
        bytes = 0
        lastTickMs = nowMs
        return StatsSnapshot(fps, decodeMs, bitrateMbps, dropped, e2eMs, rttMs, codecLabel, p95())
    }

    private fun p95(): Long {
        if (e2eSamples.isEmpty()) return -1
        val sorted = e2eSamples.sorted()
        val rank = (sorted.size * 95 + 99) / 100 - 1
        return sorted[rank.coerceIn(0, sorted.lastIndex)]
    }

    private companion object {
        const val MAX_E2E_SAMPLES = 300
    }
}