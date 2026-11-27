package com.kikiraihan.aitodo.ui

import android.content.ClipboardManager
import androidx.compose.foundation.clickable
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
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.ContentPaste
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.kikiraihan.aitodo.Clip
import com.kikiraihan.aitodo.Notifier

/** Kiriman: teks dari Mac / web / AI lain (ketuk = salin), dan kirim teks dari HP ini ke perangkat lain. */
@Composable
fun ClipsScreen(model: MainModel, modifier: Modifier, focusId: Long, onFocusDone: () -> Unit) {
    var text by remember { mutableStateOf("") }
    val ctx = LocalContext.current
    fun copy(c: Clip) {
        Notifier.copy(ctx, c.content)
        model.say("Kiriman disalin")
    }
    val focused = model.clips.firstOrNull { it.id == focusId }

    Column(modifier.fillMaxSize()) {
        if (focused != null) {
            Card(Modifier.fillMaxWidth().padding(16.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer)) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Dari ${focused.device.ifBlank { "perangkat lain" }} · ${Dates.stamp(focused.createdAt, model.zone)}",
                        style = MaterialTheme.typography.bodySmall)
                    Text(focused.content, fontFamily = FontFamily.Monospace, maxLines = 12, overflow = TextOverflow.Ellipsis)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(onClick = { copy(focused); onFocusDone() }) {
                            Icon(Icons.Outlined.ContentCopy, null)
                            Text("  Salin")
                        }
                        TextButton(onClick = onFocusDone) { Text("Tutup") }
                    }
                }
            }
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(text, { text = it }, Modifier.weight(1f), placeholder = { Text("Kirim teks ke perangkat lain…") }, maxLines = 4)
            IconButton(onClick = {
                val cm = ctx.getSystemService(ClipboardManager::class.java)
                text = cm.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(ctx)?.toString() ?: text
            }) { Icon(Icons.Outlined.ContentPaste, "Tempel dari clipboard") }
            FilledIconButton(onClick = { model.sendClip(text) { text = "" } }, enabled = text.isNotBlank()) {
                Icon(Icons.AutoMirrored.Outlined.Send, "Kirim")
            }
        }
        if (!model.loaded) return@Column Empty("Memuat…")
        if (model.clips.isEmpty()) return@Column Empty(
            "Belum ada kiriman. Teks yang dikirim dari Mac (klik kanan ikon → Kirim clipboard ke HP), web, atau AI lain " +
                "muncul sebagai notifikasi dengan tombol Salin, dan tersimpan di sini 7 hari.",
        )
        LazyColumn(Modifier.fillMaxSize()) {
            items(model.clips, key = { it.id }) { c ->
                SwipeRow(
                    start = SwipeAction("Salin", Icons.Outlined.ContentCopy, OkGreen) { copy(c) },
                    end = SwipeAction("Hapus", DeleteIcon, DangerRed) { model.act("Kiriman dihapus") { it.deleteClip(c.id) } },
                ) {
                    Column(Modifier.fillMaxWidth().clickable { copy(c) }.padding(horizontal = 16.dp, vertical = 10.dp)) {
                        Text(c.content, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodyMedium, maxLines = 4,
                            overflow = TextOverflow.Ellipsis)
                        Text("${c.device.ifBlank { "Perangkat" }} · ${Dates.stamp(c.createdAt, model.zone)}",
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                HorizontalDivider()
            }
            item { Box(Modifier.padding(16.dp)) { Text("Kiriman terhapus otomatis setelah 7 hari. Untuk disimpan, pakai Catatan.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) } }
        }
    }
}
