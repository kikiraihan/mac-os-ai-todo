package com.kikiraihan.aitodo

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.widget.Toast
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Notifikasi dari server (kotak masuk). Kanal terpisah supaya pengguna bisa mengatur masing-masing di
 * Pengaturan Android. Tombol aksi: Salin (kiriman & todo), Selesai (todo), Tunda 10 mnt (pengingat) —
 * semuanya jalan langsung dari notifikasi tanpa membuka aplikasi (ActionReceiver).
 */
object Notifier {
    const val CH_CLIP = "clip"
    const val CH_REMINDER = "reminder"
    const val CH_DUE = "due"
    const val CH_SUMMARY = "summary"
    const val CH_SYNC = "sync"

    fun channels(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannels(
            listOf(
                NotificationChannel(CH_CLIP, "Kiriman", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Teks yang dikirim dari Mac, web, atau AI lain — dengan tombol Salin"
                },
                NotificationChannel(CH_REMINDER, "Pengingat", NotificationManager.IMPORTANCE_HIGH),
                NotificationChannel(CH_DUE, "Tenggat todo", NotificationManager.IMPORTANCE_HIGH),
                NotificationChannel(CH_SUMMARY, "Ringkasan harian", NotificationManager.IMPORTANCE_DEFAULT),
                NotificationChannel(CH_SYNC, "Koneksi latar", NotificationManager.IMPORTANCE_MIN).apply {
                    description = "Tampil saat notifikasi memakai koneksi langsung ke server (tanpa Google FCM)"
                    setShowBadge(false)
                },
            ),
        )
    }

    fun allowed(ctx: Context) = Build.VERSION.SDK_INT < 33 ||
        ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun channelFor(kind: String) = when (kind) {
        "clip" -> CH_CLIP
        "reminder" -> CH_REMINDER
        "due" -> CH_DUE
        else -> CH_SUMMARY
    }

    private fun idFor(item: InboxItem) = (item.tag.ifBlank { "n-${item.id}" }).hashCode()

    private fun action(ctx: Context, item: InboxItem, what: String, req: Int): PendingIntent {
        val i = Intent(ctx, ActionReceiver::class.java).apply {
            action = "com.kikiraihan.aitodo.$what"
            putExtra("nid", idFor(item))
            putExtra("todoId", item.todoId)
            putExtra("reminderId", item.reminderId)
            putExtra("clipId", item.clipId)
            if (!item.textTruncated) putExtra("text", item.text)
        }
        return PendingIntent.getBroadcast(ctx, idFor(item) * 8 + req, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    fun show(ctx: Context, item: InboxItem) {
        if (!allowed(ctx)) return
        val open = Intent(ctx, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("open", item.kind)
            putExtra("clipId", item.clipId)
        }
        val b = NotificationCompat.Builder(ctx, channelFor(item.kind))
            .setSmallIcon(R.drawable.ic_stat)
            .setColor(0xFF0F766E.toInt())
            .setContentTitle(item.title)
            .setContentText(item.body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(item.body))
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(if (item.kind == "clip") NotificationCompat.CATEGORY_MESSAGE else NotificationCompat.CATEGORY_REMINDER)
            .setContentIntent(
                PendingIntent.getActivity(ctx, idFor(item), open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE),
            )
        val canCopy = item.clipId > 0 || item.text.isNotBlank()
        if (canCopy) b.addAction(0, "Salin", action(ctx, item, "COPY", 1))
        if (item.todoId > 0) b.addAction(0, "Selesai", action(ctx, item, "DONE", 2))
        if (item.reminderId > 0) b.addAction(0, "Tunda 10 mnt", action(ctx, item, "SNOOZE", 3))
        try {
            NotificationManagerCompat.from(ctx).notify(idFor(item), b.build())
        } catch (_: SecurityException) {
            // izin notifikasi dicabut di tengah jalan
        }
    }

    fun cancel(ctx: Context, id: Int) = NotificationManagerCompat.from(ctx).cancel(id)

    /** Salin ke clipboard. Android 13+ menampilkan konfirmasi sendiri; versi lama diberi toast. */
    fun copy(ctx: Context, text: String, label: String = "Disalin") {
        val cm = ctx.getSystemService(ClipboardManager::class.java)
        cm.setPrimaryClip(ClipData.newPlainText("AI Todo", text))
        if (Build.VERSION.SDK_INT < 33) Toast.makeText(ctx, label, Toast.LENGTH_SHORT).show()
    }
}

/** Menarik notifikasi baru dari kotak masuk server lalu menampilkannya (dipakai FCM & long-poll). */
object InboxSync {
    private val lock = Mutex()

    suspend fun pull(ctx: Context) = lock.withLock {
        val prefs = Prefs(ctx)
        if (!prefs.loggedIn) return@withLock
        val api = prefs.api()
        var last = prefs.lastNotification
        if (last < 0) {
            // Baru masuk: mulai dari nomor terakhir supaya notifikasi lama tidak muncul.
            prefs.lastNotification = api.inbox(null).last
            return@withLock
        }
        repeat(5) {
            val box = api.inbox(last)
            box.items.forEach { Notifier.show(ctx, it) }
            // Kosong = tidak ada yang baru untuk HP ini (mis. kiriman dari HP ini sendiri) → lompat ke nomor terakhir.
            last = if (box.items.isEmpty()) maxOf(last, box.last) else box.items.maxOf { it.id }
            prefs.lastNotification = last
            if (box.items.size < 50) return@withLock
        }
    }
}
