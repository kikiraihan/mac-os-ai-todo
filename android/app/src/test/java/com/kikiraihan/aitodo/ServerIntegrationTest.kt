package com.kikiraihan.aitodo

import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * Klien Android (Api.kt) terhadap server Go asli. Dijalankan oleh scripts/test-android.sh
 * (AITODO_URL/USER/PASS diisi); tanpa env itu tes dilewati.
 */
class ServerIntegrationTest {
    private val url = System.getenv("AITODO_URL").orEmpty()
    private val user = System.getenv("AITODO_USER").orEmpty()
    private val pass = System.getenv("AITODO_PASS").orEmpty()

    @Test fun fullFlow() = runBlocking {
        assumeTrue("AITODO_URL tidak diisi", url.isNotEmpty())
        val phone = Api(url, Api(url, null).loginDevice(user, pass, "Pixel Tes").token)
        val mac = Api(url, Api(url, null).loginDevice(user, pass, "MacBook Tes").token)

        assertTrue(phone.me().user.username.equals(user, ignoreCase = true))
        // Server tanpa FCM_CREDENTIALS → aplikasi memakai koneksi langsung.
        assertEquals(null, phone.androidConfig())

        val start = phone.inbox(null)
        assertTrue(start.items.isEmpty())

        // Mac mengirim kiriman → HP menerima notifikasi dengan teks Salin; Mac sendiri tidak.
        val macStart = mac.inbox(null).last
        assertEquals(0, mac.sendClip("kode OTP 123456")) // belum ada perangkat dengan Web Push / FCM
        val got = phone.inbox(start.last)
        val clip = got.items.single { it.kind == "clip" }
        assertEquals("kode OTP 123456", clip.text)
        assertEquals("Kiriman dari MacBook Tes", clip.title)
        assertEquals(clip.clipId, phone.clips().first().id)
        assertEquals("kode OTP 123456", phone.clip(clip.clipId).content)
        assertTrue(mac.inbox(macStart).items.none { it.kind == "clip" })

        // Todo: tambah, selesai lewat aksi notifikasi, buka lagi, hapus.
        val t = phone.createTodo(JSONObject().put("title", "Tes Android").put("notes", "detail").put("dueDate", "2099-01-01").put("dueTime", "09:00"))
        assertEquals("Tes Android\n\ndetail", t.copyText())
        phone.completeTodo(t.id)
        assertTrue(phone.todos("done").any { it.id == t.id })
        phone.reopenTodo(t.id)

        // Pengingat terkait todo, tunda, hapus.
        val r = phone.createReminder(JSONObject().put("title", "Ingat").put("todoId", t.id)
            .put("schedule", JSONObject().put("kind", "once").put("at", "2099-01-01T08:30")))
        val rid = r.getJSONObject("reminder").getLong("id")
        assertTrue(phone.reminders().any { it.id == rid && it.todoId == t.id && it.scheduleKind == "once" })
        phone.snooze(rid, 10)
        phone.deleteReminder(rid)
        phone.deleteTodo(t.id)

        // Catatan.
        val n = phone.createNote(JSONObject().put("content", "https://contoh.id\n- satu"))
        assertEquals("https://contoh.id", n.title)
        phone.deleteNote(n.id)

        // Chat perintah tanpa AI (/catat) → balasan + data berubah.
        val (msgs, _) = phone.sendChat("/catat beli kopi")
        assertEquals(2, msgs.size)
        assertNotNull(phone.chat().messages.lastOrNull())

        // Token FCM hanya untuk token perangkat, bentuknya dicek server.
        phone.registerFcm("dGVzdA:APA91bH-token-android-panjang")
        val err = runCatching { phone.registerFcm("x") }.exceptionOrNull() as ApiException
        assertEquals(400, err.status)

        // Pembaruan lewat server belum diatur di server tes → 501 berpesan.
        val rel = runCatching { phone.latestRelease() }.exceptionOrNull() as ApiException
        assertEquals(501, rel.status)

        // Keluar → token tidak berlaku.
        phone.logout()
        assertEquals(401, (runCatching { phone.me() }.exceptionOrNull() as ApiException).status)
    }
}
