package com.kikiraihan.aitodo.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.kikiraihan.aitodo.Todo
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale

// Satu aksen teal (sama dengan web & Mac), warna sistem lainnya, mendukung mode gelap.
private val Teal = Color(0xFF0F766E)
private val TealDark = Color(0xFF2DD4BF)

@Composable
fun AITodoTheme(content: @Composable () -> Unit) {
    // Semua warna "container" bawaan Material (ungu) diganti turunan teal, supaya hanya ada satu aksen.
    val scheme = if (isSystemInDarkTheme()) {
        val soft = Color(0xFF134E4A)
        val onSoft = Color(0xFFCCFBF1)
        darkColorScheme(
            primary = TealDark, onPrimary = Color(0xFF00201C), primaryContainer = soft, onPrimaryContainer = onSoft,
            secondary = TealDark, onSecondary = Color(0xFF00201C), secondaryContainer = soft, onSecondaryContainer = onSoft,
            tertiary = TealDark, tertiaryContainer = soft, onTertiaryContainer = onSoft,
            background = Color(0xFF0F1419), surface = Color(0xFF0F1419),
            surfaceContainer = Color(0xFF161D24), surfaceContainerHigh = Color(0xFF1D252E), surfaceContainerLow = Color(0xFF131A20),
            surfaceContainerHighest = Color(0xFF242D36), surfaceVariant = Color(0xFF242D36),
        )
    } else {
        val soft = Color(0xFFD5F5EF)
        val onSoft = Color(0xFF134E4A)
        lightColorScheme(
            primary = Teal, onPrimary = Color.White, primaryContainer = soft, onPrimaryContainer = onSoft,
            secondary = Teal, onSecondary = Color.White, secondaryContainer = soft, onSecondaryContainer = onSoft,
            tertiary = Teal, tertiaryContainer = soft, onTertiaryContainer = onSoft,
            background = Color(0xFFF7F8FA), surface = Color(0xFFF7F8FA),
            surfaceContainer = Color(0xFFEEF1F4), surfaceContainerHigh = Color(0xFFE8ECEF), surfaceContainerLow = Color(0xFFF2F4F6),
            surfaceContainerHighest = Color(0xFFE3E8EC), surfaceVariant = Color(0xFFE3E8EC),
        )
    }
    MaterialTheme(colorScheme = scheme, content = content)
}

private val idLocale = Locale.forLanguageTag("id-ID")

object Dates {
    fun today(zone: ZoneId): LocalDate = LocalDate.now(zone)

    /** "Hari ini", "Besok", "Kemarin", atau "Sen, 2 Des". */
    fun friendlyDate(ymd: String, zone: ZoneId): String {
        val d = try {
            LocalDate.parse(ymd)
        } catch (_: Exception) {
            return ymd
        }
        val t = today(zone)
        return when (d) {
            t -> "Hari ini"
            t.plusDays(1) -> "Besok"
            t.minusDays(1) -> "Kemarin"
            else -> d.format(DateTimeFormatter.ofPattern(if (d.year == t.year) "EEE, d MMM" else "d MMM yyyy", idLocale))
        }
    }

    fun due(t: Todo, zone: ZoneId): String =
        if (t.dueDate.isBlank()) "" else friendlyDate(t.dueDate, zone) + if (t.dueTime.isNotBlank()) " ${t.dueTime}" else ""

    /** Stempel server (RFC3339 UTC) → "Hari ini 15.30" di zona pengguna. */
    fun stamp(rfc: String, zone: ZoneId): String = try {
        val z = Instant.parse(rfc).atZone(zone)
        friendlyDate(z.toLocalDate().toString(), zone) + " " + z.toLocalTime().format(DateTimeFormatter.ofPattern("HH.mm"))
    } catch (_: Exception) {
        ""
    }

    fun ymdToMillis(ymd: String): Long? = try {
        LocalDate.parse(ymd).atStartOfDay().toInstant(ZoneOffset.UTC).toEpochMilli()
    } catch (_: Exception) {
        null
    }

    fun millisToYmd(ms: Long): String = Instant.ofEpochMilli(ms).atZone(ZoneOffset.UTC).toLocalDate().toString()
}

/** Pemilih tanggal (kalender) — tanggal & jam selalu lewat picker, bukan diketik. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DateDialog(initial: String, onDismiss: () -> Unit, onPick: (String) -> Unit) {
    val state = rememberDatePickerState(initialSelectedDateMillis = Dates.ymdToMillis(initial) ?: System.currentTimeMillis())
    DatePickerDialog(
        onDismissRequest = onDismiss,
        confirmButton = { TextButton(onClick = { state.selectedDateMillis?.let { onPick(Dates.millisToYmd(it)) }; onDismiss() }) { Text("Pilih") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Batal") } },
    ) { DatePicker(state = state) }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TimeDialog(initial: String, onDismiss: () -> Unit, onPick: (String) -> Unit) {
    val t = try {
        LocalTime.parse(initial)
    } catch (_: Exception) {
        LocalTime.now().plusHours(1).withMinute(0)
    }
    val state = rememberTimePickerState(initialHour = t.hour, initialMinute = t.minute, is24Hour = true)
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = { TextButton(onClick = { onPick("%02d:%02d".format(state.hour, state.minute)); onDismiss() }) { Text("Pilih") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Batal") } },
        text = { TimePicker(state = state) },
    )
}

/** Konfirmasi sebelum menghapus (aksi yang menghapus selalu dikonfirmasi). */
@Composable
fun ConfirmDelete(what: String, onDismiss: () -> Unit, onConfirm: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Hapus $what?") },
        confirmButton = { TextButton(onClick = { onConfirm(); onDismiss() }) { Text("Hapus", color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Batal") } },
    )
}

data class SwipeAction(val label: String, val icon: ImageVector, val color: Color, val run: () -> Unit)

/**
 * Baris dengan gestur geser (pola PWA di HP): kanan = aksi utama, kiri = aksi kedua (ubah / hapus).
 * Setiap aksi geser juga punya jalan lain lewat ketukan (lembar ubah / menu).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SwipeRow(start: SwipeAction?, end: SwipeAction?, content: @Composable () -> Unit) {
    val state = rememberSwipeToDismissBoxState(
        confirmValueChange = {
            when (it) {
                SwipeToDismissBoxValue.StartToEnd -> start?.run?.invoke()
                SwipeToDismissBoxValue.EndToStart -> end?.run?.invoke()
                else -> {}
            }
            false // baris tidak dibuang; data dimuat ulang dari server
        },
        positionalThreshold = { it * 0.4f },
    )
    LaunchedEffect(state.currentValue) { if (state.currentValue != SwipeToDismissBoxValue.Settled) state.reset() }
    SwipeToDismissBox(
        state = state,
        enableDismissFromStartToEnd = start != null,
        enableDismissFromEndToStart = end != null,
        backgroundContent = {
            val a = if (state.dismissDirection == SwipeToDismissBoxValue.StartToEnd) start else end
            if (a != null) {
                Row(
                    Modifier.fillMaxSize().background(a.color).padding(horizontal = 20.dp),
                    horizontalArrangement = if (a == start) Arrangement.Start else Arrangement.End,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(a.icon, null, tint = Color.White)
                    Text("  ${a.label}", color = Color.White)
                }
            }
        },
    ) { Box(Modifier.background(MaterialTheme.colorScheme.background)) { content() } }
}

@Composable
fun Empty(text: String) {
    Column(Modifier.fillMaxWidth().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(text, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
    }
}

val DeleteIcon = Icons.Outlined.Delete
val DangerRed = Color(0xFFD93025)
val OkGreen = Color(0xFF1E8E3E)
