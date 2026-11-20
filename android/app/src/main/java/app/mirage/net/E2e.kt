package app.mirage.net

object E2e {
    fun compute(
        nowMicros: Long,
        offsetMicros: Long,
        captureTsMicros: Long,
        maxMicros: Long = 10_000_000
    ): Long {
        if (captureTsMicros <= 0) return -1
        val value = nowMicros - offsetMicros - captureTsMicros
        if (value < 0 || value > maxMicros) return -1
        return value / 1000
    }
}