package com.kikiraihan.aitodo

import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Mode tanpa FCM (server belum memasang FCM_CREDENTIALS, atau HP tanpa Google Play): koneksi long-poll
 * ke /api/changes tetap hidup di latar; setiap ada perubahan, kotak masuk notifikasi dibaca.
 * Android mewajibkan notifikasi tetap ("Terhubung ke server") untuk layanan seperti ini.
 */
class SyncService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var job: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val n = NotificationCompat.Builder(this, Notifier.CH_SYNC)
            .setSmallIcon(R.drawable.ic_stat)
            .setContentTitle("Terhubung ke server")
            .setContentText("Notifikasi AI Todo lewat koneksi langsung")
            .setOngoing(true)
            .setSilent(true)
            .setContentIntent(open)
            .build()
        val type = if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0
        ServiceCompat.startForeground(this, 1, n, type)
        if (job?.isActive != true) job = scope.launch { loop() }
        return START_STICKY
    }

    private suspend fun loop() {
        var rev = 0L
        var failures = 0
        while (scope.isActive) {
            val prefs = Prefs(applicationContext)
            if (!prefs.loggedIn || !prefs.backgroundSync || Push.usingFcm(applicationContext)) {
                stopSelf()
                return
            }
            try {
                val api = prefs.api()
                val next = api.changes(rev, wait = rev != 0L)
                if (next != rev) {
                    InboxSync.pull(applicationContext)
                    rev = next
                }
                failures = 0
            } catch (e: ApiException) {
                if (e.unauthorized) {
                    stopSelf()
                    return
                }
                failures++
                delay(minOf(60_000L, 2_000L shl minOf(failures, 5)))
            }
        }
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    companion object {
        fun start(ctx: Context) {
            val p = Prefs(ctx)
            if (!p.loggedIn || !p.backgroundSync || Push.usingFcm(ctx) || !Notifier.allowed(ctx)) return
            try {
                ctx.startForegroundService(Intent(ctx, SyncService::class.java))
            } catch (_: Exception) {
                // Android 12+: tidak boleh memulai dari latar belakang → dimulai saat aplikasi dibuka.
            }
        }

        fun stop(ctx: Context) = ctx.stopService(Intent(ctx, SyncService::class.java))
    }
}
