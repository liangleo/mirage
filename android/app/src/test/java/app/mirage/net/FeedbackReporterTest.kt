package app.mirage.net

import org.junit.Assert.assertEquals
import org.junit.Test

class FeedbackReporterTest {
    @Test
    fun buildCarriesDroppedQueueAndArrival() {
        val reporter = FeedbackReporter(
            send = {},
            droppedFrames = { 3 },
            queueDepth = { 2 },
            arrivalDelayMS = { 150 },
            rttMS = { 12 },
            decodeMS = { 8 },
            clockMillis = { 1_000 },
            clockNanos = { 0 }
        )

        val feedback = reporter.build(nowMillis = 1_000)
        assertEquals(3, feedback.droppedFrames)
        assertEquals(2, feedback.queueDepth)
        assertEquals(150, feedback.arrivalDelayMS)
    }
}