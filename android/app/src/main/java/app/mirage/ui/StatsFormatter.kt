package app.mirage.ui

import app.mirage.net.StatsSnapshot
import java.util.Locale

data class StatsLines(val first: String, val second: String, val transport: String, val p95: String)

object StatsFormatter {
    fun format(
        snapshot: StatsSnapshot,
        transportName: String,
        width: Int,
        height: Int
    ): StatsLines {
        val first = String.format(
            Locale.US,
            "%d fps · %.1f Mbps · drop %d",
            snapshot.fps,
            snapshot.bitrateMbps,
            snapshot.dropped
        )
        val e2e = if (snapshot.e2eMs >= 0) "e2e ${snapshot.e2eMs}" else "e2e --"
        val rtt = if (snapshot.rttMs >= 0) "RTT ${snapshot.rttMs}" else "RTT --"
        val codec = if (snapshot.codec.isNotBlank()) " · ${snapshot.codec}" else ""
        val second = String.format(
            Locale.US,
            "decode %.1fms · %s · %s%s",
            snapshot.decodeMs.toDouble(),
            e2e,
            rtt,
            codec
        )
        val resolution = if (width > 0 && height > 0) " $width×$height" else ""
        val p95 = if (snapshot.e2eP95Ms >= 0) "p95 ${snapshot.e2eP95Ms}ms" else "p95 --"
        return StatsLines(first, second, transportName + resolution, p95)
    }
}