package dev.nicholas.eclipse

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.text.InputType
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.Toast
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/** A private capture window. Only the new draft is visible above the keyguard. */
class QuickTaskActivity : Activity() {
    private lateinit var name: EditText
    private lateinit var save: Button
    private lateinit var open: Button
    private var saving = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        @Suppress("DEPRECATION")
        window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_SECURE)
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE or WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        title = "Add task"
        val pad = (16 * resources.displayMetrics.density).toInt()
        val form = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad, pad, pad)
        }
        name = EditText(this).apply {
            setSingleLine()
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            hint = "Call Marge tomorrow at 7:35 pm"
            imeOptions = EditorInfo.IME_ACTION_DONE or EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
            setText(savedInstanceState?.getString("draft"))
            setSelection(length())
            setOnEditorActionListener { _, action, event ->
                if (action == EditorInfo.IME_ACTION_DONE || (event?.keyCode == android.view.KeyEvent.KEYCODE_ENTER && event.action == android.view.KeyEvent.ACTION_DOWN)) {
                    submit()
                    true
                } else false
            }
        }
        form.addView(name)
        open = Button(this).apply {
            text = "Open Eclipse"
            setOnClickListener {
                startActivity(Intent(this@QuickTaskActivity, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                finish()
            }
        }
        save = Button(this).apply { text = "Save"; setOnClickListener { submit() } }
        form.addView(LinearLayout(this).apply { addView(open); addView(save) })
        setContentView(form)
        name.requestFocus()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putString("draft", name.text.toString())
    }

    private fun submit() {
        val text = name.text.toString().trim()
        if (text.isEmpty() || saving) return
        saving = true
        save.isEnabled = false
        open.isEnabled = false
        name.isEnabled = false
        val context = applicationContext
        CoroutineScope(Dispatchers.Main.immediate).launch {
            try {
                val existing = PhoneRuntime.current
                val engine = existing ?: FlutterEngine(context)
                PhoneRuntime.retain(context, engine)
                try {
                    if (existing == null) engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
                    PhoneRuntime.capture(context, text)
                } finally {
                    PhoneRuntime.release()
                }
                Toast.makeText(context, "Task added to Eclipse", Toast.LENGTH_SHORT).show()
                finish()
            } catch (e: Exception) {
                if (!isDestroyed && !isFinishing) {
                    name.isEnabled = true
                    save.isEnabled = true
                    open.isEnabled = true
                    saving = false
                    name.error = e.localizedMessage ?: "Couldn’t save. Try again."
                    name.requestFocus()
                }
            }
        }
    }
}
