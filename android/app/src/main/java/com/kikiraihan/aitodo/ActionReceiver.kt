package com.kikiraihan.aitodo

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.widget.Toast
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** Tombol di notifikasi: Salin / Selesai / Tunda — langsung jalan tanpa membuka aplikasi. */
class ActionReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        val app = ctx.applicationContext
        val nid = intent.getIntExtra("nid", 0)
        val what = intent.action?.substringAfterLast('.') ?: return
        // null bila receiver dipanggil langsung (mis. tes), bukan lewat sistem.
        val pending: PendingResult? = goAsync()
        scope.launch {
            try {
                val api = Prefs(app).api()
                when (what) {
                    "COPY" -> {
                        var text = intent.getStringExtra("text").orEmpty()
                        val clipId = intent.getLongExtra("clipId", 0)
                        // Teks panjang / isi disembunyikan: ambil langsung dari server.
                        if (text.isEmpty() && clipId > 0) text = api.clip(clipId).content
                        if (text.isNotEmpty()) main { Notifier.copy(app, text) }
                        Notifier.cancel(app, nid)
                    }
                    "DONE" -> {
                        api.completeTodo(intent.getLongExtra("todoId", 0))
                        Notifier.cancel(app, nid)
                        main { Toast.makeText(app, "Todo selesai", Toast.LENGTH_SHORT).show() }
                    }
                    "SNOOZE" -> {
                        api.snooze(intent.getLongExtra("reminderId", 0), 10)
                        Notifier.cancel(app, nid)
                        main { Toast.makeText(app, "Ditunda 10 menit", Toast.LENGTH_SHORT).show() }
                    }
                }
            } catch (e: Exception) {
                main { Toast.makeText(app, e.message ?: "Gagal", Toast.LENGTH_LONG).show() }
            } finally {
                pending?.finish()
            }
        }
    }

    private fun main(f: () -> Unit) = Handler(Looper.getMainLooper()).post(f)

    companion object {
        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    }
}
