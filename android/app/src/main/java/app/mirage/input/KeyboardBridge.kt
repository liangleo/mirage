package app.mirage.input

import android.content.Context
import android.graphics.Color
import android.text.InputType
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputConnectionWrapper
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import androidx.activity.ComponentActivity
import app.mirage.net.InputEvent
import app.mirage.ui.KeyFilter

/** Bridges the soft IME and hardware keyboard to wire input events. */
class KeyboardBridge(
    private val activity: ComponentActivity,
    private val forward: (List<InputEvent>) -> Unit,
    private val onVisible: (Boolean) -> Unit = {}
) {
    private val dispatcher = ImeDispatcher(forward)
    private val editText = ImeEditText(activity)
    private var visible = false

    var enabled: Boolean = false
        set(value) {
            field = value
            dispatcher.enabled = value
            if (!value) hide()
        }

    init {
        editText.setBackgroundColor(Color.TRANSPARENT)
        editText.isCursorVisible = false
        editText.alpha = 0.01f
        editText.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        editText.bridge = this
        (activity.window.decorView as ViewGroup).addView(
            editText,
            ViewGroup.LayoutParams(1, 1)
        )
    }

    fun toggle() {
        if (visible) hide() else show()
    }

    fun show() {
        if (!enabled || visible) return
        visible = true
        editText.requestFocus()
        editText.post {
            val imm = activity.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
            imm.showSoftInput(editText, InputMethodManager.SHOW_IMPLICIT)
        }
        onVisible(true)
    }

    fun hide() {
        val imm = activity.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        imm.hideSoftInputFromWindow(editText.windowToken, 0)
        editText.clearFocus()
        if (!visible) return
        visible = false
        onVisible(false)
        dispatcher.releaseAll()
    }

    fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (!enabled) return false
        if (!KeyFilter.shouldHandle(event.keyCode)) return false
        val action = when (event.action) {
            KeyEvent.ACTION_DOWN -> ImeDispatcher.ACTION_DOWN
            KeyEvent.ACTION_UP -> ImeDispatcher.ACTION_UP
            else -> return false
        }
        dispatcher.keyEvent(action, event.keyCode, event.metaState, event.repeatCount > 0)
        return true
    }

    fun commitText(text: CharSequence) = dispatcher.commit(text)

    fun delete(beforeLength: Int) = dispatcher.delete(beforeLength)

    fun releaseAll() = dispatcher.releaseAll()

    fun destroy() {
        hide()
        (editText.parent as? ViewGroup)?.removeView(editText)
    }

    private class ImeEditText(context: Context) : EditText(context) {
        var bridge: KeyboardBridge? = null

        override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
            outAttrs.imeOptions = outAttrs.imeOptions or EditorInfo.IME_FLAG_NO_EXTRACT_UI
            val bridge = bridge ?: return super.onCreateInputConnection(outAttrs)
            val base = BaseInputConnection(this, false)
            return object : InputConnectionWrapper(base, true) {
                override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean {
                    bridge.commitText(text ?: "")
                    return true
                }

                override fun setComposingText(text: CharSequence?, newCursorPosition: Int): Boolean = true

                override fun finishComposingText(): Boolean = true

                override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
                    bridge.delete(beforeLength)
                    return true
                }

                override fun sendKeyEvent(event: KeyEvent?): Boolean {
                    if (event == null) return false
                    val target = bridge
                    return if (event.action == KeyEvent.ACTION_DOWN &&
                        event.keyCode == ImeDispatcher.KEYCODE_ENTER
                    ) {
                        target.commitText("\n")
                        true
                    } else {
                        target.dispatchKeyEvent(event)
                    }
                }

                override fun performEditorAction(editorAction: Int): Boolean {
                    bridge.dispatchKeyEvent(
                        KeyEvent(KeyEvent.ACTION_DOWN, ImeDispatcher.KEYCODE_ENTER)
                    )
                    bridge.dispatchKeyEvent(
                        KeyEvent(KeyEvent.ACTION_UP, ImeDispatcher.KEYCODE_ENTER)
                    )
                    return true
                }
            }
        }
    }
}