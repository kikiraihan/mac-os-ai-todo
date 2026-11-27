package com.kikiraihan.aitodo

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import kotlinx.coroutines.runBlocking

/**
 * FCM hanya membawa nomor notifikasi ("nid") — judul, isi, dan teks Salin diambil langsung dari server
 * AI Todo, jadi isi todo/kiriman tidak lewat Google.
 */
class PushService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        // Dipanggil di thread latar; waktu yang tersedia ±10 detik, cukup untuk satu request.
        runBlocking {
            try {
                InboxSync.pull(applicationContext)
            } catch (_: Exception) {
                // Gagal (offline): notifikasi diambil saat aplikasi dibuka / pesan berikutnya.
            }
        }
    }

    override fun onNewToken(token: String) {
        runBlocking { Push.register(applicationContext, token) }
    }
}
