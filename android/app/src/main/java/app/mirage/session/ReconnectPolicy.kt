package app.mirage.session

object ReconnectPolicy {
    const val MAX_INNER_ATTEMPTS = 10
    const val OUTER_RETRY_MS = 5_000L
    const val OUTER_WINDOW_MS = 300_000L

    fun innerBackoffMs(attempt: Int): Long {
        if (attempt <= 1) return 500
        val shift = minOf(attempt - 1, 10)
        return minOf(500L shl shift, 5_000L)
    }

    fun innerExhausted(attempts: Int): Boolean = attempts > MAX_INNER_ATTEMPTS
}