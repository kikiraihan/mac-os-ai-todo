package com.kikiraihan.aitodo.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import com.kikiraihan.aitodo.Batch

/** Asisten: pesan pengguna di kanan, jawaban penuh lebar; kartu aksi dengan Ya / Batal / Batalkan (undo). */
@Composable
fun ChatScreen(model: MainModel, modifier: Modifier) {
    var text by remember { mutableStateOf("") }
    val list = rememberLazyListState()
    LaunchedEffect(Unit) { model.loadChat() }
    LaunchedEffect(model.chat.size) { if (model.chat.isNotEmpty()) list.animateScrollToItem(model.chat.size - 1) }

    Column(modifier.fillMaxSize().imePadding()) {
        LazyColumn(Modifier.weight(1f).fillMaxWidth(), state = list, contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (model.chat.isEmpty()) item { Empty("Tulis apa yang perlu diingat, mis. “besok jam 9 bayar listrik”.") }
            items(model.chat, key = { it.id }) { m ->
                if (m.role == "user") {
                    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
                        Text(m.content, Modifier.widthIn(max = 300.dp).background(MaterialTheme.colorScheme.primaryContainer, RoundedCornerShape(16.dp))
                            .padding(horizontal = 14.dp, vertical = 10.dp))
                    }
                } else {
                    Column {
                        SelectionContainer { Text(m.content) }
                        model.batches[m.batchId]?.let { BatchCard(model, it) }
                    }
                }
            }
            if (model.chatBusy) item { CircularProgressIndicator(Modifier.padding(8.dp), strokeWidth = 2.dp) }
        }
        Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(text, { text = it }, Modifier.weight(1f), placeholder = { Text("Tanya atau suruh asisten…") }, maxLines = 5)
            FilledIconButton(onClick = { model.sendChat(text.trim()); text = "" }, enabled = text.isNotBlank() && !model.chatBusy) {
                Icon(Icons.AutoMirrored.Outlined.Send, "Kirim")
            }
        }
    }
}

@Composable
private fun BatchCard(model: MainModel, b: Batch) {
    val dim = b.status in listOf("undone", "rejected", "expired")
    Card(Modifier.fillMaxWidth().padding(top = 8.dp)) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            b.items.forEach { Text("• ${it.summary}", textDecoration = if (dim) TextDecoration.LineThrough else null) }
            val status = mapOf("pending" to "Menunggu konfirmasi", "rejected" to "Dibatalkan", "expired" to "Kedaluwarsa — minta ulang lewat chat",
                "undone" to "Sudah di-undo", "failed" to "Gagal")[b.status]
            status?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (b.status == "pending") {
                    OutlinedButton(onClick = { model.batchAction(b.id, "reject") }) { Text("Batal") }
                    Button(onClick = { model.batchAction(b.id, "confirm") }) { Text("Ya, lakukan") }
                } else if (b.undoable) {
                    OutlinedButton(onClick = { model.batchAction(b.id, "undo") }) { Text("↶ Batalkan") }
                }
            }
        }
    }
}
