package app.mirage.ui

import android.view.KeyEvent

object KeyFilter {
    fun shouldHandle(keyCode: Int): Boolean = keyCode != KeyEvent.KEYCODE_BACK &&
        keyCode != KeyEvent.KEYCODE_VOLUME_UP &&
        keyCode != KeyEvent.KEYCODE_VOLUME_DOWN &&
        keyCode != KeyEvent.KEYCODE_VOLUME_MUTE
}