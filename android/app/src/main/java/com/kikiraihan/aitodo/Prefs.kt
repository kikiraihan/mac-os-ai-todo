package com.kikiraihan.aitodo

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Pengaturan lokal. Token perangkat disimpan terenkripsi AES-GCM dengan kunci di Android Keystore
 * (kunci tidak bisa dikeluarkan dari perangkat; data aplikasi tidak ikut backup — allowBackup=false).
 */
class Prefs(context: Context) {
    private val sp: SharedPreferences = context.getSharedPreferences("aitodo", Context.MODE_PRIVATE)

    var server: String
        get() = sp.getString("server", "") ?: ""
        set(v) = sp.edit().putString("server", v).apply()

    var token: String?
        get() = sp.getString("token", null)?.let { Secure.decrypt(it) }
        set(v) = sp.edit().apply { if (v == null) remove("token") else putString("token", Secure.encrypt(v)) }.apply()

    var username: String
        get() = sp.getString("username", "") ?: ""
        set(v) = sp.edit().putString("username", v).apply()

    /** Nomor notifikasi terakhir yang sudah ditampilkan (-1 = belum tahu; ambil nomor terakhir server dulu). */
    var lastNotification: Long
        get() = sp.getLong("last_nid", -1)
        set(v) = sp.edit().putLong("last_nid", v).apply()

    /** Pengenal Firebase dari server (JSON); kosong = server tanpa FCM → long-poll. */
    var fcmConfig: String
        get() = sp.getString("fcm_config", "") ?: ""
        set(v) = sp.edit().putString("fcm_config", v).apply()

    var fcmTokenSent: String
        get() = sp.getString("fcm_token_sent", "") ?: ""
        set(v) = sp.edit().putString("fcm_token_sent", v).apply()

    /** Mode tanpa FCM: layanan latar depan long-poll menyala. */
    var backgroundSync: Boolean
        get() = sp.getBoolean("bg_sync", true)
        set(v) = sp.edit().putBoolean("bg_sync", v).apply()

    var todoFilter: String
        get() = sp.getString("todo_filter", "today") ?: "today"
        set(v) = sp.edit().putString("todo_filter", v).apply()

    var lastTab: Int
        get() = sp.getInt("last_tab", 1) // bawaan: tab Todo
        set(v) = sp.edit().putInt("last_tab", v).apply()

    val loggedIn get() = server.isNotBlank() && token != null

    fun api() = Api(server, token)

    fun clearSession() {
        sp.edit().remove("token").remove("last_nid").remove("fcm_token_sent").remove("fcm_config").apply()
    }
}

private object Secure {
    private const val ALIAS = "aitodo-token"

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build(),
        )
        return gen.generateKey()
    }

    fun encrypt(plain: String): String {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key())
        val out = c.iv + c.doFinal(plain.toByteArray())
        return Base64.encodeToString(out, Base64.NO_WRAP)
    }

    fun decrypt(stored: String): String? = try {
        val raw = Base64.decode(stored, Base64.NO_WRAP)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, raw, 0, 12))
        String(c.doFinal(raw, 12, raw.size - 12))
    } catch (_: Exception) {
        null // kunci hilang (mis. data dipulihkan ke HP lain): harus masuk lagi
    }
}
