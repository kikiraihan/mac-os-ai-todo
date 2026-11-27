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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.NotificationsPaused
import androidx.compose.material.icons.outlined.Snooze
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.kikiraihan.aitodo.Reminder
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDateTime

@Composable
fun RemindersScreen(model: MainModel, modifier: Modifier, adding: Boolean, onAdded: () -> Unit) {
    var showDone by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<Reminder?>(null) }
    var deleting by remember { mutableStateOf<Reminder?>(null) }
    val shown = model.reminders.filter { it.active != showDone }.sortedBy { it.nextFireAt.ifBlank { "9" } }
    val todoTitle = model.todos.associate { it.id to it.title }

    Column(modifier.fillMaxSize()) {
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)) {
            SegmentedButton(!showDone, { showDone = false }, SegmentedButtonDefaults.itemShape(0, 2)) { Text("Aktif") }
            SegmentedButton(showDone, { showDone = true }, SegmentedButtonDefaults.itemShape(1, 2)) { Text("Selesai & jeda") }
        }
        if (!model.loaded) return@Column Empty("Memuat…")
        if (shown.isEmpty()) return@Column Empty(if (showDone) "Tidak ada." else "Belum ada pengingat. Ketuk ＋, minta asisten, atau AI lain lewat MCP.")
        LazyColumn(Modifier.fillMaxSize()) {
            items(shown, key = { it.id }) { r ->
                SwipeRow(
                    start = if (r.active) SwipeAction("Tunda 10 mnt", Icons.Outlined.Snooze, OkGreen) {
                        model.act("Ditunda 10 menit") { it.snooze(r.id, 10) }
                    } else null,
                    end = SwipeAction("Hapus", DeleteIcon, DangerRed) { deleting = r },
                ) { ReminderRow(model, r, r.todoId?.let(todoTitle::get), { editing = r }, { deleting = r }) }
                HorizontalDivider()
            }
        }
    }
    if (adding) ReminderSheet(model, null) { onAdded() }
    editing?.let { r -> ReminderSheet(model, r) { editing = null } }
    deleting?.let { r -> ConfirmDelete("pengingat “${r.title}”", { deleting = null }) { model.act("Pengingat dihapus") { it.deleteReminder(r.id) } } }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ReminderRow(model: MainModel, r: Reminder, todoTitle: String?, onEdit: () -> Unit, onDelete: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Row(
        Modifier.fillMaxWidth().combinedClickable(onClick = onEdit, onLongClick = { menu = true }).padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(if (r.active) Icons.Outlined.Notifications else Icons.Outlined.NotificationsPaused, null,
            tint = if (r.active) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
        Column(Modifier.weight(1f)) {
            Text(r.title)
            val next = if (r.nextFireAt.isNotBlank()) Dates.stamp(r.nextFireAt, model.zone) else ""
            Text(listOf(r.scheduleText, next.ifBlank { null }?.let { "berikutnya $it" }).filterNotNull().filter { it.isNotBlank() }.joinToString(" · "),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            todoTitle?.let { Text("Todo: $it", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
        Box {
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                if (r.active) DropdownMenuItem(text = { Text("Tunda 10 mnt") }, onClick = { menu = false; model.act("Ditunda") { it.snooze(r.id, 10) } })
                DropdownMenuItem(text = { Text(if (r.active) "Jeda" else "Lanjutkan") }, onClick = {
                    menu = false
                    model.act(if (r.active) "Dijeda" else "Dilanjutkan") { it.updateReminder(r.id, JSONObject().put("active", !r.active)) }
                })
                DropdownMenuItem(text = { Text("Ubah…") }, onClick = { menu = false; onEdit() })
                DropdownMenuItem(text = { Text("Hapus…", color = MaterialTheme.colorScheme.error) }, onClick = { menu = false; onDelete() })
            }
        }
    }
}

/** Tambah / ubah pengingat: Kapan (Hari ini / Besok / Lusa / Tiap hari / tanggal) + jam lewat picker; Todo terkait opsional. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReminderSheet(model: MainModel, r: Reminder?, onClose: () -> Unit) {
    val zone = model.zone
    val today = Dates.today(zone)
    val next = r?.nextFireAt?.takeIf { it.isNotBlank() }?.let { runCatching { Instant.parse(it).atZone(zone).toLocalDateTime() }.getOrNull() }
    val start = next ?: LocalDateTime.now(zone).plusHours(1).withMinute(0)
    var title by remember { mutableStateOf(r?.title ?: "") }
    var message by remember { mutableStateOf(r?.message ?: "") }
    var daily by remember { mutableStateOf(r?.scheduleKind == "daily") }
    var date by remember { mutableStateOf(start.toLocalDate().toString()) }
    var time by remember { mutableStateOf("%02d:%02d".format(start.hour, start.minute)) }
    var todoId by remember { mutableStateOf(r?.todoId ?: 0L) }
    // Jadwal berulang lain (mingguan, dsb. dari asisten) tidak diubah kecuali pengguna memilih waktu baru.
    var scheduleTouched by remember { mutableStateOf(r == null || r.scheduleKind == "once" || r.scheduleKind == "daily") }
    var pickDate by remember { mutableStateOf(false) }
    var pickTime by remember { mutableStateOf(false) }
    var todoMenu by remember { mutableStateOf(false) }
    val openTodos = model.todos.filter { it.status == "open" || it.id == todoId }

    ModalBottomSheet(onDismissRequest = onClose, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(if (r == null) "Pengingat baru" else "Ubah pengingat", style = MaterialTheme.typography.titleLarge)
            OutlinedTextField(title, { title = it }, Modifier.fillMaxWidth(), label = { Text("Judul") }, singleLine = true,
                placeholder = { Text(openTodos.firstOrNull { it.id == todoId }?.title ?: "") })
            OutlinedTextField(message, { message = it }, Modifier.fillMaxWidth(), label = { Text("Pesan (opsional)") }, maxLines = 3)
            if (!scheduleTouched && r != null) {
                Text("Jadwal: ${r.scheduleText}", color = MaterialTheme.colorScheme.onSurfaceVariant)
                TextButton(onClick = { scheduleTouched = true }) { Text("Ganti jadwal") }
            } else {
                Text("Kapan", style = MaterialTheme.typography.labelLarge)
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    listOf(today to "Hari ini", today.plusDays(1) to "Besok", today.plusDays(2) to "Lusa").forEach { (d, l) ->
                        FilterChip(selected = !daily && date == d.toString(), onClick = { daily = false; date = d.toString() }, label = { Text(l) })
                    }
                    FilterChip(selected = daily, onClick = { daily = true }, label = { Text("Tiap hari") })
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (!daily) OutlinedButton(onClick = { pickDate = true }) { Text(Dates.friendlyDate(date, zone)) }
                    OutlinedButton(onClick = { pickTime = true }) { Text(time) }
                }
            }
            ExposedDropdownMenuBox(expanded = todoMenu, onExpandedChange = { todoMenu = it }) {
                OutlinedTextField(
                    value = openTodos.firstOrNull { it.id == todoId }?.title ?: "Tidak ada",
                    onValueChange = {}, readOnly = true, label = { Text("Todo terkait") },
                    trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(todoMenu) },
                    modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
                )
                ExposedDropdownMenu(expanded = todoMenu, onDismissRequest = { todoMenu = false }) {
                    DropdownMenuItem(text = { Text("Tidak ada") }, onClick = { todoId = 0; todoMenu = false })
                    openTodos.forEach { t ->
                        DropdownMenuItem(text = { Text(t.title) }, onClick = {
                            todoId = t.id
                            todoMenu = false
                            // Todo berjam: kapan & jam menyesuaikan todo itu (seperti di Mac).
                            if (r == null && t.dueDate.isNotBlank()) {
                                date = t.dueDate
                                if (t.dueTime.isNotBlank()) time = t.dueTime
                                daily = false
                            }
                        })
                    }
                }
            }
            Row(Modifier.fillMaxWidth().padding(bottom = 24.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Box(Modifier.weight(1f))
                TextButton(onClick = onClose) { Text("Batal") }
                val effectiveTitle = title.trim().ifBlank { openTodos.firstOrNull { it.id == todoId }?.title ?: "" }
                Button(enabled = effectiveTitle.isNotBlank(), onClick = {
                    val body = JSONObject().put("title", effectiveTitle).put("message", message.trim()).put("todoId", todoId)
                    if (scheduleTouched) {
                        body.put("schedule", if (daily) JSONObject().put("kind", "daily").put("time", time)
                        else JSONObject().put("kind", "once").put("at", "${date}T$time"))
                    }
                    if (r == null) model.act("Pengingat dibuat") { it.createReminder(body) }
                    else model.act("Pengingat disimpan") { it.updateReminder(r.id, body) }
                    onClose()
                }) { Text("Simpan") }
            }
        }
    }
    if (pickDate) DateDialog(date, { pickDate = false }) { date = it }
    if (pickTime) TimeDialog(time, { pickTime = false }) { time = it }
}
