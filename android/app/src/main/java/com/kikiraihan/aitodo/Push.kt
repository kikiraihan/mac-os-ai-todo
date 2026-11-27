package com.kikiraihan.aitodo

import android.content.Context
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONObject
import kotlin.coroutines.resume

/**
 * Jalur notifikasi: FCM bila server AI Todo memasang FCM (pengenal Firebase dikirim server, jadi satu
 * APK cocok untuk server mana pun), selain itu long-poll lewat SyncService.
 */
object Push {
    /** FCM aktif = token sudah terdaftar di server (HP tanpa Google Play tidak pernah dapat token). */
    fun usingFcm(ctx: Context) = Prefs(ctx).fcmTokenSent.isNotBlank()

    /** Inisialisasi Firebase dari pengenal yang tersimpan (tanpa google-services.json). */
    fun initFirebase(ctx: Context): Boolean {
        if (FirebaseApp.getApps(ctx).isNotEmpty()) return true
        val raw = Prefs(ctx).fcmConfig
        if (raw.isBlank()) return false
        return try {
            val o = JSONObject(raw)
            val opts = FirebaseOptions.Builder()
                .setProjectId(o.str("projectId"))
                .setApplicationId(o.str("appId"))
                .setApiKey(o.str("apiKey"))
                .setGcmSenderId(o.str("senderId"))
                .build()
            FirebaseApp.initializeApp(ctx, opts)
            true
        } catch (_: Exception) {
            false
        }
    }

    /** Setelah login / saat aplikasi dibuka: ambil konfigurasi server, nyalakan FCM atau long-poll. */
    suspend fun setup(ctx: Context) {
        val prefs = Prefs(ctx)
        if (!prefs.loggedIn) return
        val cfg = try {
            prefs.api().androidConfig()
        } catch (_: Exception) {
            // Offline: pakai keadaan terakhir.
            if (!usingFcm(ctx)) SyncService.start(ctx)
            return
        }
        if (cfg != null) {
            prefs.fcmConfig = JSONObject().put("projectId", cfg.projectId).put("appId", cfg.appId)
                .put("apiKey", cfg.apiKey).put("senderId", cfg.senderId).toString()
            if (initFirebase(ctx)) {
                val t = token()
                if (t != null) register(ctx, t)
                if (usingFcm(ctx)) {
                    SyncService.stop(ctx)
                    return
                }
            }
        } else {
            prefs.fcmTokenSent = ""
        }
        // Server tanpa FCM (atau HP tanpa Google Play): koneksi langsung.
        SyncService.start(ctx)
    }

    private suspend fun token(): String? = suspendCancellableCoroutine { cont ->
        try {
            FirebaseMessaging.getInstance().token
                .addOnSuccessListener { cont.resume(it) }
                .addOnFailureListener { cont.resume(null) }
        } catch (_: Exception) {
            cont.resume(null)
        }
    }

    suspend fun register(ctx: Context, token: String) {
        val prefs = Prefs(ctx)
        if (!prefs.loggedIn || prefs.fcmTokenSent == token) return
        try {
            prefs.api().registerFcm(token)
            prefs.fcmTokenSent = token
        } catch (_: Exception) {
            // dicoba lagi saat aplikasi dibuka berikutnya
        }
    }
}
