package app.mirage.net

class Liveness(private val timeoutMs: Long = 3_000) {
    @Volatile
    private var lastActivityMs = Long.MIN_VALUE / 2

    fun noteActivity(nowMs: Long) {
        lastActivityMs = nowMs
    }

    fun timedOut(nowMs: Long): Boolean = nowMs - lastActivityMs > timeoutMs
}