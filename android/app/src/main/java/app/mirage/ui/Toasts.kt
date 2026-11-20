package app.mirage.ui

import android.content.Context
import android.widget.Toast

/** 同一时间只显示最新一条 Toast，避免连续点击时排队延迟。 */
object Toasts {
    private var current: Toast? = null

    fun show(context: Context, text: String) {
        current?.cancel()
        current = Toast.makeText(context.applicationContext, text, Toast.LENGTH_SHORT).also { it.show() }
    }
}
