package com.kikiraihan.aitodo.ui

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.kikiraihan.aitodo.Api
import com.kikiraihan.aitodo.ApiException
import com.kikiraihan.aitodo.Batch
import com.kikiraihan.aitodo.ChatMessage
import com.kikiraihan.aitodo.Clip
import com.kikiraihan.aitodo.InboxSync
import com.kikiraihan.aitodo.Me
import com.kikiraihan.aitodo.Note
import com.kikiraihan.aitodo.Prefs
import com.kikiraihan.aitodo.Push
import com.kikiraihan.aitodo.Reminder
import com.kikiraihan.aitodo.SyncService
import com.kikiraihan.aitodo.Todo
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.time.ZoneId

/**
 * Keadaan aplikasi: data dari server + sinkron. Selama aplikasi terbuka, long-poll /api/changes
 * membuat daftar langsung ikut berubah saat data diubah dari Mac / web / AI lain.
 */
class MainModel(app: Application) : AndroidViewModel(app) {
    val prefs = Prefs(app)

    var loggedIn by mutableStateOf(prefs.loggedIn)
        private set
    var me by mutableStateOf<Me?>(null)
        private set
    var todos by mutableStateOf<List<Todo>>(emptyList())
        private set
    var reminders by mutableStateOf<List<Reminder>>(emptyList())
        private set
    var notes by mutableStateOf<List<Note>>(emptyList())
        private set
    var clips by mutableStateOf<List<Clip>>(emptyList())
        private set
    var chat by mutableStateOf<List<ChatMessage>>(emptyList())
        private set
    val batches = mutableStateMapOf<Long, Batch>()
    var loaded by mutableStateOf(false)
        private set
    var online by mutableStateOf(true)
        private set
    var chatBusy by mutableStateOf(false)
        private set
    /** Pesan singkat (snackbar). */
    var message by mutableStateOf<String?>(null)

    val zone: ZoneId
        get() = try {
            ZoneId.of(me?.timezone?.ifBlank { null } ?: ZoneId.systemDefault().id)
        } catch (_: Exception) {
            ZoneId.systemDefault()
        }

    private val api: Api get() = prefs.api()
    private var rev = 0L
    private var pollJob: Job? = null

    fun say(text: String) {
        message = text
    }

    private fun fail(e: Exception) {
        if (e is ApiException && e.unauthorized) {
            signedOut()
            say("Sesi berakhir — masuk lagi")
            return
        }
        say(e.message ?: "Terjadi kesalahan")
    }

    /** Jalankan aksi ke server; gagal → pesan. Setelah berhasil, data dimuat ulang. */
    fun act(done: String? = null, reload: Boolean = true, f: suspend (Api) -> Unit) {
        viewModelScope.launch {
            try {
                f(api)
                done?.let(::say)
                if (reload) refresh()
            } catch (e: Exception) {
                fail(e)
            }
        }
    }

    suspend fun login(server: String, username: String, password: String, device: String) {
        val l = Api(server, null).loginDevice(username, password, device)
        prefs.server = server
        prefs.username = username
        prefs.token = l.token
        prefs.lastNotification = -1
        loggedIn = true
        start()
    }

    fun start() {
        if (!loggedIn) return
        viewModelScope.launch {
            try {
                InboxSync.pull(getApplication())
            } catch (_: Exception) {
            }
            Push.setup(getApplication())
        }
        refresh()
        poll()
    }

    fun stopPolling() {
        pollJob?.cancel()
        pollJob = null
    }

    fun poll() {
        if (pollJob?.isActive == true || !loggedIn) return
        pollJob = viewModelScope.launch {
            var failures = 0
            while (isActive && loggedIn) {
                try {
                    val next = api.changes(rev, wait = rev != 0L)
                    online = true
                    failures = 0
                    if (next != rev) {
                        rev = next
                        refresh()
                    }
                } catch (e: ApiException) {
                    if (e.unauthorized) return@launch signedOut()
                    online = false
                    failures++
                    delay(minOf(30_000L, 1_000L shl minOf(failures, 5)))
                }
            }
        }
    }

    fun refresh() {
        viewModelScope.launch {
            try {
                val a = api
                me = a.me()
                todos = a.todos("all")
                reminders = a.reminders()
                notes = a.notes()
                clips = a.clips()
                loaded = true
                online = true
            } catch (e: Exception) {
                if (e is ApiException && e.status == 0) online = false else fail(e)
            }
        }
    }

    fun loadChat() {
        if (!prefs.loggedIn) return
        viewModelScope.launch {
            try {
                val p = api.chat()
                chat = p.messages
                batches.putAll(p.batches)
            } catch (e: Exception) {
                fail(e)
            }
        }
    }

    fun sendChat(text: String) {
        if (text.isBlank() || chatBusy) return
        chatBusy = true
        viewModelScope.launch {
            try {
                val (msgs, batch) = api.sendChat(text)
                chat = chat + msgs
                batch?.let { batches[it.id] = it }
                refresh()
            } catch (e: Exception) {
                fail(e)
            } finally {
                chatBusy = false
            }
        }
    }

    fun batchAction(id: Long, action: String) = act(reload = true) { a -> batches[id] = a.batchAction(id, action) }

    fun sendClip(text: String, done: () -> Unit = {}) = act { a ->
        val n = a.sendClip(text)
        say(if (n > 0) "Terkirim ke $n perangkat" else "Tersimpan — belum ada perangkat lain dengan notifikasi aktif")
        done()
    }

    fun saveTodo(id: Long?, fields: JSONObject) = act(if (id == null) "Todo ditambahkan" else "Todo disimpan") { a ->
        if (id == null) a.createTodo(fields) else a.updateTodo(id, fields)
    }

    fun toggleTodo(t: Todo) = act(if (t.done) "Dibuka lagi" else "Selesai") { a ->
        if (t.done) a.reopenTodo(t.id) else a.completeTodo(t.id)
    }

    fun saveNote(id: Long?, body: JSONObject) = act("Catatan disimpan") { a -> if (id == null) a.createNote(body) else a.updateNote(id, body) }

    fun signedOut() {
        stopPolling()
        SyncService.stop(getApplication())
        prefs.clearSession()
        loggedIn = false
        me = null
        todos = emptyList(); reminders = emptyList(); notes = emptyList(); clips = emptyList(); chat = emptyList()
        batches.clear()
        loaded = false
        rev = 0
    }

    /** Data contoh untuk tes tampilan (Robolectric) — tidak dipakai aplikasi. */
    internal fun demo(me: Me, todos: List<Todo>, reminders: List<Reminder>, notes: List<Note>, clips: List<Clip>, chat: List<ChatMessage>, batches: List<Batch>) {
        this.me = me
        this.todos = todos
        this.reminders = reminders
        this.notes = notes
        this.clips = clips
        this.chat = chat
        batches.forEach { this.batches[it.id] = it }
        loggedIn = true
        loaded = true
    }

    fun logout() {
        viewModelScope.launch {
            try {
                api.logout()
            } catch (_: Exception) {
            }
            signedOut()
        }
    }
}
