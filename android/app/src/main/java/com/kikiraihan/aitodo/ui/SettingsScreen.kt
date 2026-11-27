package com.kikiraihan.aitodo.ui

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.kikiraihan.aitodo.BuildConfig
import com.kikiraihan.aitodo.Notifier
import com.kikiraihan.aitodo.Push
import com.kikiraihan.aitodo.SyncService
import com.kikiraihan.aitodo.Updater
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(model: MainModel, onBack: () -> Unit) {
    BackHandler(onBack = onBack)
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var refreshTick by remember { mutableIntStateOf(0) }
    var bg by remember { mutableStateOf(model.prefs.backgroundSync) }
    var updateText by remember { mutableStateOf<String?>(null) }
    var updating by remember { mutableStateOf(false) }
    val askNotif = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        refreshTick++
        scope.launch { Push.setup(ctx.applicationContext) }
    }
    refreshTick.let { } // dibaca supaya status izin dihitung ulang setelah dialog izin
    val notifOk = Notifier.allowed(ctx)
    val fcm = Push.usingFcm(ctx)
    val pm = ctx.getSystemService(PowerManager::class.java)
    val batteryFree = pm.isIgnoringBatteryOptimizations(ctx.packageName)

    Scaffold(topBar = {
        TopAppBar(title = { Text("Pengaturan") }, navigationIcon = {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Kembali") }
        })
    }) { pad ->
        Column(Modifier.padding(pad).fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Akun", style = MaterialTheme.typography.titleMedium)
            Text("${model.me?.user?.name ?: model.prefs.username} · ${model.prefs.server.removePrefix("https://")}",
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            HorizontalDivider()

            Text("Notifikasi", style = MaterialTheme.typography.titleMedium)
            if (!notifOk) {
                Text("Notifikasi belum diizinkan — pengingat & kiriman tidak akan muncul.", color = MaterialTheme.colorScheme.error)
                Button(onClick = { if (Build.VERSION.SDK_INT >= 33) askNotif.launch(Manifest.permission.POST_NOTIFICATIONS) }) { Text("Izinkan notifikasi") }
            } else {
                Text(
                    if (fcm) "Lewat Firebase Cloud Messaging (hemat baterai). Isi notifikasi diambil langsung dari server kamu, tidak lewat Google."
                    else "Lewat koneksi langsung ke server (server belum memasang FCM, atau HP tanpa Google Play). Ada notifikasi tetap “Terhubung ke server”.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (!fcm) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Koneksi latar", Modifier.weight(1f))
                        Switch(bg, {
                            bg = it
                            model.prefs.backgroundSync = it
                            if (it) SyncService.start(ctx) else SyncService.stop(ctx)
                        })
                    }
                    if (!batteryFree) {
                        Text("Supaya koneksi tidak diputus Android saat HP diam, izinkan AI Todo berjalan tanpa pembatasan baterai.",
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        OutlinedButton(onClick = {
                            ctx.startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${ctx.packageName}")))
                        }) { Text("Izinkan berjalan di latar") }
                    }
                }
                OutlinedButton(onClick = {
                    ctx.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, ctx.packageName))
                }) { Text("Atur jenis notifikasi…") }
            }
            Text("Jam ringkasan pagi, tenggat, dan sembunyikan isi notifikasi diatur di web → Pengaturan (berlaku untuk semua perangkat).",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            HorizontalDivider()

            Text("Pembaruan aplikasi", style = MaterialTheme.typography.titleMedium)
            Text("Versi ${BuildConfig.VERSION_NAME}", color = MaterialTheme.colorScheme.onSurfaceVariant)
            updateText?.let { Text(it) }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(enabled = !updating, onClick = {
                    updating = true
                    scope.launch {
                        updateText = Updater.checkAndInstall(ctx, model.prefs.api()) { updateText = it }
                        updating = false
                    }
                }) { Text(if (updating) "Memeriksa…" else "Periksa pembaruan") }
            }
            HorizontalDivider()
            TextButton(onClick = { model.logout(); onBack() }) { Text("Keluar", color = MaterialTheme.colorScheme.error) }
        }
    }
}
