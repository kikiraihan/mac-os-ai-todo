package com.kikiraihan.aitodo

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.net.URLEncoder

/** Kesalahan dari server (pesan sudah berbahasa Indonesia) atau jaringan (status 0). */
class ApiException(val status: Int, message: String) : Exception(message) {
    val unauthorized get() = status == 401
}

object ServerUrl {
    /** "todo.contoh.id" → "https://todo.contoh.id"; buang "/" & "/api" di ujung. null = tidak valid. */
    fun normalize(raw: String): String? {
        var s = raw.trim().trimEnd('/')
        if (s.isEmpty()) return null
        if (!s.contains("://")) s = "https://$s"
        s = s.removeSuffix("/api").trimEnd('/')
        return try {
            val u = URI(s)
            val scheme = u.scheme?.lowercase()
            val host = u.host ?: return null
            val local = host == "localhost" || host == "10.0.2.2" || host == "127.0.0.1"
            if (scheme != "https" && !(scheme == "http" && local)) null else s
        } catch (_: Exception) {
            null
        }
    }
}

/**
 * Klien HTTP ke server AI Todo. Semua request membawa X-AITodo: 1 (wajib server) dan token perangkat
 * (Authorization: Bearer). Fungsi suspend — dijalankan di Dispatchers.IO.
 */
class Api(val base: String, private val token: String?) {

    private fun conn(method: String, path: String, timeoutMs: Int): HttpURLConnection {
        val c = URL("$base/api$path").openConnection() as HttpURLConnection
        c.requestMethod = method
        c.connectTimeout = 15_000
        c.readTimeout = timeoutMs
        c.instanceFollowRedirects = false
        c.setRequestProperty("X-AITodo", "1")
        c.setRequestProperty("Accept", "application/json")
        token?.let { c.setRequestProperty("Authorization", "Bearer $it") }
        return c
    }

    suspend fun request(method: String, path: String, body: JSONObject? = null, timeoutMs: Int = 30_000): JSONObject =
        withContext(Dispatchers.IO) {
            val c = conn(method, path, timeoutMs)
            try {
                if (body != null) {
                    c.doOutput = true
                    c.setRequestProperty("Content-Type", "application/json")
                    c.outputStream.use { it.write(body.toString().toByteArray()) }
                }
                val code = c.responseCode
                val text = (if (code < 400) c.inputStream else c.errorStream)?.bufferedReader()?.use { it.readText() } ?: ""
                val json = try {
                    if (text.isBlank()) JSONObject() else JSONObject(text)
                } catch (_: Exception) {
                    JSONObject()
                }
                if (code !in 200..299) throw ApiException(code, json.str("error").ifBlank { "HTTP $code" })
                json
            } catch (e: IOException) {
                throw ApiException(0, "Tidak bisa terhubung ke server. Periksa koneksi internet.")
            } finally {
                c.disconnect()
            }
        }

    suspend fun get(path: String, timeoutMs: Int = 30_000) = request("GET", path, timeoutMs = timeoutMs)
    suspend fun post(path: String, body: JSONObject = JSONObject()) = request("POST", path, body)
    suspend fun put(path: String, body: JSONObject) = request("PUT", path, body)
    suspend fun delete(path: String) = request("DELETE", path)

    // --- akun ---------------------------------------------------------------------

    data class Login(val token: String, val user: User)

    suspend fun loginDevice(username: String, password: String, device: String): Login {
        val o = post("/login/device", JSONObject().put("username", username).put("password", password).put("device", device))
        return Login(o.str("token"), Parse.user(o.getJSONObject("user")))
    }

    suspend fun me() = Parse.me(get("/me"))
    suspend fun logout() = post("/logout")
    suspend fun androidConfig() = Parse.fcm(get("/app/android/config"))
    suspend fun registerFcm(token: String) = post("/push/fcm", JSONObject().put("token", token))
    suspend fun changes(since: Long, wait: Boolean) =
        get("/changes?since=$since" + if (wait) "&wait=1" else "", timeoutMs = 45_000).long("rev")

    // --- kotak masuk & kiriman -------------------------------------------------------

    suspend fun inbox(after: Long?) = Parse.inbox(get(if (after == null) "/notifications" else "/notifications?after=$after"))
    suspend fun clips() = get("/clips").optJSONArray("clips").mapObjects(Parse::clip)
    suspend fun clip(id: Long) = Parse.clip(get("/clips/$id").getJSONObject("clip"))
    suspend fun sendClip(content: String) = post("/clips", JSONObject().put("content", content)).optInt("sent")
    suspend fun deleteClip(id: Long) = delete("/clips/$id")

    // --- todo -----------------------------------------------------------------------

    suspend fun todos(status: String = "all") = get("/todos?status=$status").optJSONArray("todos").mapObjects(Parse::todo)
    suspend fun createTodo(fields: JSONObject) = Parse.todo(post("/todos", fields).getJSONObject("todo"))
    suspend fun updateTodo(id: Long, fields: JSONObject) = Parse.todo(put("/todos/$id", fields).getJSONObject("todo"))
    suspend fun completeTodo(id: Long) = post("/todos/$id/complete")
    suspend fun reopenTodo(id: Long) = post("/todos/$id/reopen")
    suspend fun deleteTodo(id: Long) = delete("/todos/$id")

    // --- pengingat -------------------------------------------------------------------

    suspend fun reminders() = get("/reminders").optJSONArray("reminders").mapObjects(Parse::reminder)
    suspend fun createReminder(body: JSONObject) = post("/reminders", body)
    suspend fun updateReminder(id: Long, body: JSONObject) = put("/reminders/$id", body)
    suspend fun deleteReminder(id: Long) = delete("/reminders/$id")
    suspend fun snooze(id: Long, minutes: Int = 10) = post("/reminders/$id/snooze", JSONObject().put("minutes", minutes))

    // --- catatan ---------------------------------------------------------------------

    suspend fun notes() = get("/notes").optJSONArray("notes").mapObjects(Parse::note)
    suspend fun createNote(body: JSONObject) = Parse.note(post("/notes", body).getJSONObject("note"))
    suspend fun updateNote(id: Long, body: JSONObject) = Parse.note(put("/notes/$id", body).getJSONObject("note"))
    suspend fun deleteNote(id: Long) = delete("/notes/$id")

    // --- chat ------------------------------------------------------------------------

    suspend fun chat() = Parse.chatPage(get("/chat"))
    suspend fun sendChat(message: String): Pair<List<ChatMessage>, Batch?> {
        val o = request("POST", "/chat", JSONObject().put("message", message), timeoutMs = 95_000)
        val msgs = listOfNotNull(o.optJSONObject("user")?.let(Parse::chatMessage), o.optJSONObject("assistant")?.let(Parse::chatMessage))
        return msgs to o.optJSONObject("batch")?.let(Parse::batch)
    }
    suspend fun batchAction(id: Long, action: String) = Parse.batch(post("/chat/batches/$id/$action").getJSONObject("batch"))

    // --- pembaruan aplikasi ------------------------------------------------------------

    suspend fun latestRelease(): AppRelease {
        val o = get("/app/android/latest", timeoutMs = 20_000)
        return AppRelease(o.str("version"), o.optBoolean("apk"))
    }

    /** Unduh AITodo.apk lewat server (repo GitHub boleh private). */
    suspend fun downloadApk(dest: File) = withContext(Dispatchers.IO) {
        val c = conn("GET", "/app/android/download/AITodo.apk", 600_000)
        try {
            if (c.responseCode != 200) throw ApiException(c.responseCode, "Unduhan gagal (HTTP ${c.responseCode})")
            dest.parentFile?.mkdirs()
            c.inputStream.use { input -> dest.outputStream().use { input.copyTo(it) } }
        } catch (e: IOException) {
            throw ApiException(0, "Unduhan terputus. Coba lagi.")
        } finally {
            c.disconnect()
        }
    }

    companion object {
        fun q(s: String): String = URLEncoder.encode(s, "UTF-8")
    }
}

internal fun jsonOf(vararg pairs: Pair<String, Any?>): JSONObject {
    val o = JSONObject()
    for ((k, v) in pairs) o.put(k, v ?: JSONObject.NULL)
    return o
}

internal fun JSONArray.ints(vararg v: Int) = apply { v.forEach { put(it) } }
