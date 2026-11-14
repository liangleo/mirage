package app.mirage.net

data class StatsSnapshot(
    val fps: Int = 0,
    val decodeMs: Long = 0,
    val bitrateMbps: Double = 0.0,
    val dropped: Int = 0,
    val e2eMs: Long = -1,
    val codec: String = ""
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

    fun setE2eMs(value: Long) {
        e2eMs = value
    }

    fun setCodecLabel(value: String) {
        codecLabel = value
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
        return StatsSnapshot(fps, decodeMs, bitrateMbps, dropped, e2eMs, codecLabel)
    }
}