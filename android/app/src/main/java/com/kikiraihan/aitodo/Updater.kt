package com.kikiraihan.aitodo

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File

/**
 * Pembaruan lewat server AI Todo (rilis GitHub boleh private, token GitHub hanya di server).
 * Keaslian dicek Android sendiri: APK baru hanya bisa menggantikan aplikasi ini kalau tanda tangannya sama.
 */
object Updater {
    suspend fun checkAndInstall(ctx: Context, api: Api, progress: (String) -> Unit): String {
        val rel = try {
            api.latestRelease()
        } catch (e: ApiException) {
            return when (e.status) {
                404 -> "Belum ada rilis."
                501 -> "Server belum diatur untuk pembaruan: ${e.message}"
                else -> e.message ?: "Gagal memeriksa pembaruan"
            }
        }
        if (!Versions.newer(rel.version, BuildConfig.VERSION_NAME.removeSuffix("-debug"))) return "Sudah versi terbaru (${rel.version})."
        if (!rel.apk) return "Rilis ${rel.version} belum berisi AITodo.apk."
        if (Build.VERSION.SDK_INT >= 26 && !ctx.packageManager.canRequestPackageInstalls()) {
            ctx.startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${ctx.packageName}")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            return "Izinkan AI Todo memasang pembaruan, lalu ketuk Periksa pembaruan lagi."
        }
        progress("Mengunduh ${rel.version}…")
        val file = File(ctx.cacheDir, "updates/AITodo.apk")
        api.downloadApk(file)
        val uri = FileProvider.getUriForFile(ctx, "${ctx.packageName}.files", file)
        ctx.startActivity(
            Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        return "Versi ${rel.version} siap dipasang."
    }
}
