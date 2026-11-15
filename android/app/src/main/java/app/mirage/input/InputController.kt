package app.mirage.input

import app.mirage.net.Ctrl
import app.mirage.net.InputEvent
import app.mirage.net.InputMessages
import app.mirage.net.MessageType
import app.mirage.net.Messages

class InputController(
    private val send: (ByteArray) -> Unit,
    private val mapper: GestureMapper = GestureMapper()
) {
    fun onFrame(frame: TouchFrame) {
        forward(mapper.onFrame(frame))
    }

    fun forward(events: List<InputEvent>) {
        for (event in events) {
            when (event) {
                is InputEvent.Pointer -> send(InputMessages.encodePointer(event.samples))
                is InputEvent.Key -> send(InputMessages.encodeKey(event.key))
                is InputEvent.Text -> send(InputMessages.encodeText(event.text))
                is InputEvent.Scroll -> send(InputMessages.encodeScroll(event.scroll))
                InputEvent.ReleaseAll -> releaseAll()
            }
        }
    }

    fun releaseAll() {
        mapper.reset()
        send(Messages.encodeFrame(MessageType.CTRL.id, byteArrayOf(Ctrl.RELEASE_ALL.toByte())))
    }
}