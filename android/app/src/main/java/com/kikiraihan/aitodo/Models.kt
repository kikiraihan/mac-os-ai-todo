package com.kikiraihan.aitodo

import org.json.JSONArray
import org.json.JSONObject

// Model data (sama dengan JSON server Go). JSON dibaca manual dengan org.json (bawaan Android).

data class User(val id: Long, val username: String, val displayName: String) {
    val name get() = displayName.ifBlank { username }
}

data class Me(val user: User, val timezone: String, val hideContent: Boolean, val sessionId: Long, val version: String)

data class Todo(
    val id: Long,
    val title: String,
    val notes: String,
    val status: String,
    val priority: String,
    val list: String,
    val dueDate: String,
    val dueTime: String,
    val source: String,
) {
    val done get() = status == "done"
    /** Salin = "Judul" + baris kosong + detail (sama dengan web & Mac). */
    fun copyText(titleOnly: Boolean = false) = if (titleOnly || notes.isBlank()) title else "$title\n\n$notes"
}

data class Reminder(
    val id: Long,
    val todoId: Long?,
    val title: String,
    val message: String,
    val scheduleText: String,
    val scheduleKind: String,
    val nextFireAt: String,
    val active: Boolean,
)

data class Note(
    val id: Long,
    val title: String,
    val content: String,
    val list: String,
    val pinned: Boolean,
    val updatedAt: String,
) {
    fun copyText(titleOnly: Boolean = false) = if (titleOnly || content.isBlank()) title else "$title\n\n$content"
}

data class Clip(val id: Long, val content: String, val device: String, val createdAt: String)

/** Satu notifikasi dari kotak masuk server (GET /api/notifications). */
data class InboxItem(
    val id: Long,
    val kind: String,
    val title: String,
    val body: String,
    val tag: String,
    val todoId: Long,
    val reminderId: Long,
    val clipId: Long,
    val text: String,
    val textTruncated: Boolean,
)

data class Inbox(val last: Long, val items: List<InboxItem>)

data class ChatMessage(val id: Long, val role: String, val content: String, val batchId: Long)

data class BatchItem(val op: String, val summary: String)

data class Batch(val id: Long, val status: String, val items: List<BatchItem>, val undoable: Boolean)

data class ChatPage(val messages: List<ChatMessage>, val batches: Map<Long, Batch>)

data class FcmConfig(val projectId: String, val appId: String, val apiKey: String, val senderId: String)

data class AppRelease(val version: String, val apk: Boolean)

// --- parsing -----------------------------------------------------------------------

internal fun JSONObject.str(k: String) = if (isNull(k)) "" else optString(k, "")
internal fun JSONObject.long(k: String) = if (isNull(k)) 0L else optLong(k, 0L)

internal inline fun <T> JSONArray?.mapObjects(f: (JSONObject) -> T): List<T> {
    if (this == null) return emptyList()
    return (0 until length()).map { f(getJSONObject(it)) }
}

object Parse {
    fun user(o: JSONObject) = User(o.long("id"), o.str("username"), o.str("displayName"))

    fun me(o: JSONObject) = Me(
        user = user(o.getJSONObject("user")),
        timezone = o.str("timezone"),
        hideContent = o.optJSONObject("prefs")?.optBoolean("hideContent") ?: false,
        sessionId = o.long("sessionId"),
        version = o.str("version"),
    )

    fun todo(o: JSONObject) = Todo(
        o.long("id"), o.str("title"), o.str("notes"), o.str("status"), o.str("priority"),
        o.str("list"), o.str("dueDate"), o.str("dueTime"), o.str("source"),
    )

    fun reminder(o: JSONObject) = Reminder(
        id = o.long("id"),
        todoId = if (o.isNull("todoId") || !o.has("todoId")) null else o.getLong("todoId"),
        title = o.str("title"),
        message = o.str("message"),
        scheduleText = o.str("scheduleText"),
        scheduleKind = o.optJSONObject("schedule")?.str("kind") ?: "",
        nextFireAt = o.str("nextFireAt"),
        active = o.optBoolean("active"),
    )

    fun note(o: JSONObject) = Note(o.long("id"), o.str("title"), o.str("content"), o.str("list"), o.optBoolean("pinned"), o.str("updatedAt"))

    fun clip(o: JSONObject) = Clip(o.long("id"), o.str("content"), o.str("device"), o.str("createdAt"))

    fun inboxItem(o: JSONObject) = InboxItem(
        id = o.long("id"), kind = o.str("kind"), title = o.str("title"), body = o.str("body"), tag = o.str("tag"),
        todoId = o.long("todoId"), reminderId = o.long("reminderId"), clipId = o.long("clipId"),
        text = o.str("text"), textTruncated = o.optBoolean("textTruncated"),
    )

    fun inbox(o: JSONObject) = Inbox(o.long("last"), o.optJSONArray("items").mapObjects(::inboxItem))

    fun batch(o: JSONObject) = Batch(
        o.long("id"), o.str("status"),
        o.optJSONArray("items").mapObjects { BatchItem(it.str("op"), it.str("summary")) },
        o.optBoolean("undoable"),
    )

    fun chatMessage(o: JSONObject) = ChatMessage(o.long("id"), o.str("role"), o.str("content"), o.long("batchId"))

    fun chatPage(o: JSONObject): ChatPage {
        val bs = mutableMapOf<Long, Batch>()
        o.optJSONObject("batches")?.let { m -> m.keys().forEach { k -> m.optJSONObject(k)?.let { bs[k.toLong()] = batch(it) } } }
        return ChatPage(o.optJSONArray("messages").mapObjects(::chatMessage), bs)
    }

    fun fcm(o: JSONObject): FcmConfig? {
        val f = o.optJSONObject("fcm") ?: return null
        val c = FcmConfig(f.str("projectId"), f.str("appId"), f.str("apiKey"), f.str("senderId"))
        return if (c.projectId.isBlank() || c.appId.isBlank() || c.apiKey.isBlank() || c.senderId.isBlank()) null else c
    }
}

/** Perbandingan versi "v0.22.0" / "0.22.0". */
object Versions {
    private fun parts(v: String) = v.trim().removePrefix("v").split(".").map { it.takeWhile(Char::isDigit).toIntOrNull() ?: 0 }

    fun newer(candidate: String, current: String): Boolean {
        val a = parts(candidate)
        val b = parts(current)
        for (i in 0 until maxOf(a.size, b.size)) {
            val x = a.getOrElse(i) { 0 }
            val y = b.getOrElse(i) { 0 }
            if (x != y) return x > y
        }
        return false
    }
}
