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
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.kikiraihan.aitodo.Note
import com.kikiraihan.aitodo.Notifier
import org.json.JSONObject

@Composable
fun NotesScreen(model: MainModel, modifier: Modifier, adding: Boolean, onAdded: () -> Unit) {
    var pinnedOnly by remember { mutableStateOf(false) }
    var query by remember { mutableStateOf("") }
    var editing by remember { mutableStateOf<Note?>(null) }
    var deleting by remember { mutableStateOf<Note?>(null) }
    val ctx = LocalContext.current
    val words = query.lowercase().split(Regex("\\s+")).filter { it.isNotBlank() }
    val shown = model.notes.filter { n ->
        (!pinnedOnly || n.pinned) && words.all { w -> "${n.title}\n${n.content}\n${n.list}".lowercase().contains(w) }
    }

    Column(modifier.fillMaxSize()) {
        Row(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            FilterChip(selected = !pinnedOnly, onClick = { pinnedOnly = false }, label = { Text("Semua") })
            FilterChip(selected = pinnedOnly, onClick = { pinnedOnly = true }, label = { Text("Disematkan") })
        }
        OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
            placeholder = { Text("Cari") }, leadingIcon = { Icon(Icons.Outlined.Search, null) }, singleLine = true)
        if (!model.loaded) return@Column Empty("Memuat…")
        if (shown.isEmpty()) return@Column Empty(if (query.isNotBlank()) "Tidak ada catatan yang cocok." else "Belum ada catatan. Ketuk ＋ untuk menyimpan teks atau link.")
        LazyColumn(Modifier.fillMaxSize()) {
            items(shown, key = { it.id }) { n ->
                SwipeRow(
                    start = SwipeAction(if (n.pinned) "Lepas" else "Sematkan", Icons.Outlined.PushPin, OkGreen) { togglePin(model, n) },
                    end = SwipeAction("Hapus", DeleteIcon, DangerRed) { deleting = n },
                ) {
                    NoteRow(model, n, onOpen = { editing = n }, onCopy = {
                        Notifier.copy(ctx, n.copyText())
                        model.say(if (n.content.isBlank()) "Judul disalin" else "Judul & isi disalin")
                    }, onDelete = { deleting = n })
                }
                HorizontalDivider()
            }
        }
    }
    if (adding) NoteSheet(model, null) { onAdded() }
    editing?.let { n -> NoteSheet(model, n) { editing = null } }
    deleting?.let { n -> ConfirmDelete("catatan “${n.title}”", { deleting = null }) { model.act("Catatan dihapus") { it.deleteNote(n.id) } } }
}

private fun togglePin(model: MainModel, n: Note) =
    model.act(if (n.pinned) "Sematan dilepas" else "Catatan disematkan") { it.updateNote(n.id, JSONObject().put("pinned", !n.pinned)) }

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun NoteRow(model: MainModel, n: Note, onOpen: () -> Unit, onCopy: () -> Unit, onDelete: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().combinedClickable(onClick = onOpen, onLongClick = { menu = true }).padding(end = 16.dp, top = 4.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = { togglePin(model, n) }) {
            Icon(Icons.Outlined.PushPin, if (n.pinned) "Lepas sematan" else "Sematkan",
                tint = if (n.pinned) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant)
        }
        Column(Modifier.weight(1f).padding(vertical = 6.dp)) {
            Text(n.title, maxLines = 2, overflow = TextOverflow.Ellipsis)
            val preview = n.content.lines().map { it.trim().removePrefix("- ") }.firstOrNull { it.isNotBlank() && it != n.title }
            if (preview != null) Text(preview, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            val meta = listOfNotNull(n.list.ifBlank { null }, Dates.stamp(n.updatedAt, model.zone).ifBlank { null })
            Text(meta.joinToString(" · "), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Box {
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(text = { Text("Salin") }, onClick = { menu = false; onCopy() })
                DropdownMenuItem(text = { Text("Kirim ke perangkat lain") }, onClick = { menu = false; model.sendClip(n.copyText()) })
                DropdownMenuItem(text = { Text(if (n.pinned) "Lepas sematan" else "Sematkan") }, onClick = { menu = false; togglePin(model, n) })
                DropdownMenuItem(text = { Text("Hapus…", color = MaterialTheme.colorScheme.error) }, onClick = { menu = false; onDelete() })
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NoteSheet(model: MainModel, note: Note?, onClose: () -> Unit) {
    var title by remember { mutableStateOf(note?.title ?: "") }
    var content by remember { mutableStateOf(note?.content ?: "") }
    var list by remember { mutableStateOf(note?.list ?: "") }
    var pinned by remember { mutableStateOf(note?.pinned ?: false) }
    val ctx = LocalContext.current
    ModalBottomSheet(onDismissRequest = onClose, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(if (note == null) "Catatan baru" else "Catatan", style = MaterialTheme.typography.titleLarge)
            OutlinedTextField(title, { title = it }, Modifier.fillMaxWidth(), label = { Text("Judul (kosong = baris pertama isi)") }, singleLine = true)
            OutlinedTextField(content, { content = it }, Modifier.fillMaxWidth(), label = { Text("Isi / link") }, minLines = 4, maxLines = 12)
            OutlinedTextField(list, { list = it }, Modifier.fillMaxWidth(), label = { Text("Kategori (opsional)") }, singleLine = true)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Sematkan di atas", Modifier.weight(1f))
                Switch(pinned, { pinned = it })
            }
            Row(Modifier.fillMaxWidth().padding(bottom = 24.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (note != null) TextButton(onClick = { Notifier.copy(ctx, note.copyText()); model.say("Disalin") }) { Text("Salin") }
                Box(Modifier.weight(1f))
                TextButton(onClick = onClose) { Text("Batal") }
                Button(enabled = title.isNotBlank() || content.isNotBlank(), onClick = {
                    model.saveNote(note?.id, JSONObject().put("title", title.trim()).put("content", content.trim()).put("list", list.trim()).put("pinned", pinned))
                    onClose()
                }) { Text("Simpan") }
            }
        }
    }
}
