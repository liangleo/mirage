package app.mirage.session

data class ScreenSnapshot(val width: Int, val height: Int, val rotation: Int)

object ScreenChange {
    fun shouldResendHello(previous: ScreenSnapshot?, next: ScreenSnapshot): Boolean {
        if (next.width <= 0 || next.height <= 0) return false
        if (previous == null) return true
        return previous.width != next.width ||
            previous.height != next.height ||
            previous.rotation != next.rotation
    }
}