package app.mirage.session

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ScreenChangeTest {
    @Test
    fun sameSizeAndRotationDoesNotResend() {
        val prev = ScreenSnapshot(2880, 1920, 0)
        assertFalse(ScreenChange.shouldResendHello(prev, prev))
    }

    @Test
    fun sizeChangeResends() {
        assertTrue(
            ScreenChange.shouldResendHello(
                ScreenSnapshot(2880, 1920, 0),
                ScreenSnapshot(1920, 2880, 0)
            )
        )
    }

    @Test
    fun rotationChangeResends() {
        assertTrue(
            ScreenChange.shouldResendHello(
                ScreenSnapshot(2880, 1920, 0),
                ScreenSnapshot(2880, 1920, 1)
            )
        )
    }

    @Test
    fun zeroSizeIsIgnored() {
        assertFalse(
            ScreenChange.shouldResendHello(
                ScreenSnapshot(2880, 1920, 0),
                ScreenSnapshot(0, 0, 1)
            )
        )
    }
}