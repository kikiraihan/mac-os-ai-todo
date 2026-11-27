package com.kikiraihan.aitodo

import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import com.kikiraihan.aitodo.ui.AITodoTheme
import kotlinx.coroutines.launch
import org.json.JSONObject

/** Bagikan → AI Todo: teks dari aplikasi lain jadi Kiriman (ke perangkat lain), Todo, atau Catatan. */
class ShareActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val text = intent?.takeIf { it.action == Intent.ACTION_SEND }?.getStringExtra(Intent.EXTRA_TEXT)?.trim().orEmpty()
        val subject = intent?.getStringExtra(Intent.EXTRA_SUBJECT)?.trim().orEmpty()
        val prefs = Prefs(this)
        if (text.isEmpty() || !prefs.loggedIn) {
            Toast.makeText(this, if (text.isEmpty()) "Tidak ada teks untuk dibagikan" else "Masuk ke AI Todo dulu", Toast.LENGTH_SHORT).show()
            if (!prefs.loggedIn) startActivity(Intent(this, MainActivity::class.java))
            finish()
            return
        }
        setContent {
            AITodoTheme {
                AlertDialog(
                    onDismissRequest = ::finish,
                    title = { Text("Kirim ke AI Todo") },
                    text = {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(text, maxLines = 4, overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            listOf(
                                "Kirim ke perangkat lain" to "clip",
                                "Jadikan todo hari ini" to "todo",
                                "Simpan sebagai catatan" to "note",
                            ).forEach { (label, what) ->
                                OutlinedButton(onClick = { save(what, text, subject) }, Modifier.fillMaxWidth().padding(top = 2.dp)) { Text(label) }
                            }
                        }
                    },
                    confirmButton = {},
                    dismissButton = { TextButton(onClick = ::finish) { Text("Batal") } },
                )
            }
        }
    }

    private fun save(what: String, text: String, subject: String) {
        val api = Prefs(this).api()
        lifecycleScope.launch {
            val msg = try {
                when (what) {
                    "clip" -> api.sendClip(text).let { if (it > 0) "Terkirim ke $it perangkat" else "Tersimpan di Kiriman" }
                    "todo" -> {
                        val title = subject.ifBlank { text.lineSequence().first() }.take(200)
                        val notes = if (title == text) "" else text
                        val today = java.time.LocalDate.now(runCatching { java.time.ZoneId.of(api.me().timezone) }.getOrDefault(java.time.ZoneId.systemDefault()))
                        api.createTodo(JSONObject().put("title", title).put("notes", notes).put("dueDate", today.toString()))
                        "Todo ditambahkan"
                    }
                    else -> {
                        api.createNote(JSONObject().put("title", subject).put("content", text))
                        "Catatan disimpan"
                    }
                }
            } catch (e: Exception) {
                e.message ?: "Gagal"
            }
            Toast.makeText(this@ShareActivity, msg, Toast.LENGTH_SHORT).show()
            finish()
        }
    }
}
