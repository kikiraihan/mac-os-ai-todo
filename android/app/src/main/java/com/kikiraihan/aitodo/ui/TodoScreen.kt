package com.kikiraihan.aitodo.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.RadioButtonUnchecked
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.Button
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.kikiraihan.aitodo.Notifier
import com.kikiraihan.aitodo.Todo
import org.json.JSONObject

@Composable
fun TodoScreen(model: MainModel, modifier: Modifier, adding: Boolean, onAdded: () -> Unit) {
    var filter by remember { mutableStateOf(model.prefs.todoFilter) }
    var editing by remember { mutableStateOf<Todo?>(null) }
    var deleting by remember { mutableStateOf<Todo?>(null) }
    val ctx = LocalContext.current
    val today = Dates.today(model.zone).toString()
    val withReminder = model.reminders.filter { it.active && it.todoId != null }.mapNotNull { it.todoId }.toSet()

    val shown = when (filter) {
        "today" -> model.todos.filter { !it.done && it.status == "open" && it.dueDate.isNotBlank() && it.dueDate <= today }
        "done" -> model.todos.filter { it.done }
        else -> model.todos.filter { it.status == "open" }
    }.sortedWith(compareBy<Todo> { it.dueDate.ifBlank { "9999" } }.thenBy { it.dueTime.ifBlank { "99" } }.thenBy { it.id })

    Column(modifier.fillMaxSize()) {
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)) {
            val opts = listOf("today" to "Hari ini", "all" to "Semua", "done" to "Selesai")
            opts.forEachIndexed { i, (k, label) ->
                SegmentedButton(selected = filter == k, onClick = { filter = k; model.prefs.todoFilter = k },
                    shape = SegmentedButtonDefaults.itemShape(i, opts.size)) { Text(label) }
            }
        }
        if (!model.loaded) return@Column Empty("Memuat…")
        if (shown.isEmpty()) return@Column Empty(
            when (filter) {
                "today" -> "Tidak ada todo untuk hari ini 🎉"
                "done" -> "Belum ada yang selesai."
                else -> "Belum ada todo. Ketuk ＋ atau minta asisten."
            },
        )
        LazyColumn(Modifier.fillMaxSize()) {
            items(shown, key = { it.id }) { t ->
                SwipeRow(
                    start = SwipeAction(if (t.done) "Buka lagi" else "Selesai", Icons.Outlined.CheckCircle, OkGreen) { model.toggleTodo(t) },
                    end = SwipeAction("Hapus", DeleteIcon, DangerRed) { deleting = t },
                ) {
                    TodoRow(model, t, t.id in withReminder, today,
                        onEdit = { editing = t },
                        onCopy = { Notifier.copy(ctx, t.copyText()); model.say(if (t.notes.isBlank()) "Judul disalin" else "Judul & detail disalin") },
                        onDelete = { deleting = t })
                }
                HorizontalDivider()
            }
        }
    }
    if (adding) TodoSheet(model, null) { onAdded() }
    editing?.let { t -> TodoSheet(model, t) { editing = null } }
    deleting?.let { t -> ConfirmDelete("“${t.title}”", { deleting = null }) { model.act("Todo dihapus") { it.deleteTodo(t.id) } } }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun TodoRow(model: MainModel, t: Todo, hasReminder: Boolean, today: String, onEdit: () -> Unit, onCopy: () -> Unit, onDelete: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Row(
        Modifier.fillMaxWidth().combinedClickable(onClick = onEdit, onLongClick = { menu = true }).padding(end = 16.dp, top = 4.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = { model.toggleTodo(t) }) {
            Icon(if (t.done) Icons.Outlined.CheckCircle else Icons.Outlined.RadioButtonUnchecked,
                if (t.done) "Buka lagi" else "Tandai selesai",
                tint = if (t.done) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Column(Modifier.weight(1f).padding(vertical = 6.dp)) {
            Text(t.title, textDecoration = if (t.done) TextDecoration.LineThrough else null, maxLines = 3, overflow = TextOverflow.Ellipsis)
            val meta = listOfNotNull(
                Dates.due(t, model.zone).ifBlank { null },
                t.list.ifBlank { null },
                if (t.priority == "high") "Penting" else null,
            )
            if (meta.isNotEmpty() || hasReminder) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    val late = !t.done && t.dueDate.isNotBlank() && t.dueDate < today
                    Text(meta.joinToString(" · "), style = MaterialTheme.typography.bodySmall,
                        color = if (late) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
                    if (hasReminder) Icon(Icons.Outlined.Notifications, "Ada pengingat", Modifier.size(14.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            if (t.notes.isNotBlank()) Text(t.notes, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Box {
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(text = { Text("Salin") }, onClick = { menu = false; onCopy() })
                DropdownMenuItem(text = { Text("Kirim ke perangkat lain") }, onClick = { menu = false; model.sendClip(t.copyText()) })
                DropdownMenuItem(text = { Text("Ubah…") }, leadingIcon = { Icon(Icons.Outlined.Edit, null) }, onClick = { menu = false; onEdit() })
                DropdownMenuItem(text = { Text("Hapus…", color = MaterialTheme.colorScheme.error) }, onClick = { menu = false; onDelete() })
            }
        }
    }
}

/** Lembar tambah / ubah todo. Tanggal & jam lewat picker; pilihan cepat Hari ini / Besok / Lusa. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TodoSheet(model: MainModel, todo: Todo?, onClose: () -> Unit) {
    val today = Dates.today(model.zone)
    var title by remember { mutableStateOf(todo?.title ?: "") }
    var notes by remember { mutableStateOf(todo?.notes ?: "") }
    var list by remember { mutableStateOf(todo?.list ?: "") }
    var date by remember { mutableStateOf(todo?.dueDate ?: if (todo == null) today.toString() else "") }
    var time by remember { mutableStateOf(todo?.dueTime ?: "") }
    var priority by remember { mutableStateOf(todo?.priority?.ifBlank { "normal" } ?: "normal") }
    var pickDate by remember { mutableStateOf(false) }
    var pickTime by remember { mutableStateOf(false) }
    val ctx = LocalContext.current

    ModalBottomSheet(onDismissRequest = onClose, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(if (todo == null) "Todo baru" else "Ubah todo", style = MaterialTheme.typography.titleLarge)
            OutlinedTextField(title, { title = it }, Modifier.fillMaxWidth(), label = { Text("Judul") }, singleLine = true)
            OutlinedTextField(notes, { notes = it }, Modifier.fillMaxWidth(), label = { Text("Detail (opsional)") }, minLines = 2, maxLines = 6)
            Text("Kapan", style = MaterialTheme.typography.labelLarge)
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                listOf("" to "Tanpa", today.toString() to "Hari ini", today.plusDays(1).toString() to "Besok", today.plusDays(2).toString() to "Lusa")
                    .forEach { (v, label) -> FilterChip(selected = date == v, onClick = { date = v; if (v.isEmpty()) time = "" }, label = { Text(label) }) }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { pickDate = true }) { Text(if (date.isBlank()) "Pilih tanggal" else Dates.friendlyDate(date, model.zone)) }
                OutlinedButton(onClick = { pickTime = true }, enabled = date.isNotBlank()) { Text(time.ifBlank { "Jam (opsional)" }) }
                if (time.isNotBlank()) TextButton(onClick = { time = "" }) { Text("Tanpa jam") }
            }
            OutlinedTextField(list, { list = it }, Modifier.fillMaxWidth(), label = { Text("Kategori (opsional)") }, singleLine = true)
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                val ps = listOf("low" to "Santai", "normal" to "Normal", "high" to "Penting")
                ps.forEachIndexed { i, (k, l) ->
                    SegmentedButton(priority == k, { priority = k }, SegmentedButtonDefaults.itemShape(i, ps.size)) { Text(l) }
                }
            }
            Row(Modifier.fillMaxWidth().padding(bottom = 24.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (todo != null) {
                    TextButton(onClick = { Notifier.copy(ctx, todo.copyText()); model.say("Disalin") }) { Text("Salin") }
                }
                Box(Modifier.weight(1f))
                TextButton(onClick = onClose) { Text("Batal") }
                Button(enabled = title.isNotBlank(), onClick = {
                    val f = JSONObject().put("title", title.trim()).put("notes", notes.trim()).put("list", list.trim())
                        .put("dueDate", date).put("dueTime", if (date.isBlank()) "" else time).put("priority", priority)
                    model.saveTodo(todo?.id, f)
                    onClose()
                }) { Text("Simpan") }
            }
        }
    }
    if (pickDate) DateDialog(date.ifBlank { today.toString() }, { pickDate = false }) { date = it }
    if (pickTime) TimeDialog(time, { pickTime = false }) { time = it }
}
