package com.kikiraihan.aitodo

import android.app.Application
import android.app.NotificationManager
import android.content.ClipboardManager
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.test.core.app.ApplicationProvider
import com.kikiraihan.aitodo.ui.AITodoTheme
import com.kikiraihan.aitodo.ui.MainModel
import com.kikiraihan.aitodo.ui.MainScreen
import com.kikiraihan.aitodo.ui.Tab
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File
import java.time.LocalDate

/**
 * Tes tampilan & notifikasi tanpa emulator (Robolectric). Screenshot setiap tab disimpan di
 * app/build/screenshots/ supaya bisa dilihat tanpa HP.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], qualifiers = "w400dp-h860dp-xhdpi", application = UiTest.TestApp::class)
class UiTest {
    /** Tanpa Firebase/Keystore (tidak tersedia di Robolectric). */
    class TestApp : Application() {
        override fun onCreate() {
            super.onCreate()
            Notifier.channels(this)
        }
    }

    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val app: Application = ApplicationProvider.getApplicationContext()

    private fun model(): MainModel {
        val today = LocalDate.now()
        return MainModel(app).apply {
            demo(
                me = Me(User(1, "budi", "Budi"), "Asia/Jakarta", false, 5, "0.22.0"),
                todos = listOf(
                    Todo(1, "Bayar listrik", "token PLN 20 digit", "open", "high", "Rumah", today.toString(), "09:00", "manual"),
                    Todo(2, "Kirim laporan mingguan", "", "open", "normal", "Kantor", today.minusDays(1).toString(), "", "mcp"),
                    Todo(3, "Beli galon", "", "open", "normal", "", today.toString(), "", "chat"),
                    Todo(4, "Servis motor", "", "open", "low", "", today.plusDays(3).toString(), "", "manual"),
                ),
                reminders = listOf(
                    Reminder(1, 1, "Bayar listrik", "", "Sekali, hari ini 08.30", "once", "2099-01-01T01:30:00Z", true),
                    Reminder(2, null, "Minum air", "", "Tiap hari 10.00", "daily", "2099-01-01T03:00:00Z", true),
                ),
                notes = listOf(
                    Note(1, "Resep sambal", "https://contoh.id/resep\n- cabai\n- bawang", "Dapur", true, "2026-11-27T03:00:00Z"),
                    Note(2, "Wifi kantor", "SSID: Lantai3", "", false, "2026-11-26T03:00:00Z"),
                ),
                clips = listOf(
                    Clip(10, "ssh deploy@10.0.0.5 -p 2222", "MacBook", "2026-11-27T07:00:00Z"),
                    Clip(9, "Alamat: Jl. Merdeka No. 10, Gorontalo", "Claude", "2026-11-27T05:00:00Z"),
                ),
                chat = listOf(
                    ChatMessage(1, "user", "ingatkan bayar listrik besok jam 9", 0),
                    ChatMessage(2, "assistant", "Siap, aku buatkan pengingatnya:", 7),
                ),
                batches = listOf(Batch(7, "pending", listOf(BatchItem("reminder.create", "Pengingat “Bayar listrik” besok 09.00")), false)),
            )
        }
    }

    private fun shot(name: String) {
        compose.waitForIdle()
        // captureToImage menunggu redraw yang tidak pernah datang di Robolectric → gambar view jendela langsung.
        val v = compose.activity.window.decorView
        val bmp = Bitmap.createBitmap(v.width, v.height, Bitmap.Config.ARGB_8888)
        compose.runOnUiThread { v.draw(Canvas(bmp)) }
        val dir = File("build/screenshots").apply { mkdirs() }
        File(dir, "$name.png").outputStream().use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    @Test fun screens() {
        val m = model()
        val tab = androidx.compose.runtime.mutableStateOf<Tab?>(Tab.Todo)
        compose.setContent { AITodoTheme { MainScreen(m, tab.value, 0) {} } }
        compose.onNodeWithText("Bayar listrik").assertExists()
        compose.onNodeWithText("Kirim laporan mingguan").assertExists() // terlambat ikut tampil di "Hari ini"
        shot("1-todo")
        for ((t, name) in listOf(Tab.Reminders to "2-pengingat", Tab.Notes to "3-catatan", Tab.Clips to "4-kiriman", Tab.Chat to "5-asisten")) {
            compose.runOnIdle { tab.value = t }
            shot(name)
        }
        compose.onNodeWithText("Ya, lakukan").assertExists()
    }

    @Test fun clipFromNotification() {
        val m = model()
        compose.setContent { AITodoTheme { MainScreen(m, Tab.Clips, 10) {} } }
        compose.onNodeWithText("Dari MacBook", substring = true).assertExists()
        shot("6-kiriman-dari-notifikasi")
    }

    @Test fun notificationActionsAndCopy() {
        shadowOf(app).grantPermissions(android.Manifest.permission.POST_NOTIFICATIONS)
        val item = InboxItem(42, "clip", "Kiriman dari MacBook", "ssh deploy@10.0.0.5", "clip-10", 0, 0, 10, "ssh deploy@10.0.0.5 -p 2222", false)
        Notifier.show(app, item)
        val nm = shadowOf(app.getSystemService(NotificationManager::class.java))
        val n = nm.allNotifications.single()
        assertEquals(Notifier.CH_CLIP, n.channelId)
        assertEquals(listOf("Salin"), n.actions.map { it.title.toString() })

        val due = InboxItem(43, "due", "Bayar listrik", "Tenggat 10 menit lagi", "todo-1", 1, 0, 0, "Bayar listrik\n\ntoken", false)
        Notifier.show(app, due)
        val n2 = nm.allNotifications.first { it.channelId == Notifier.CH_DUE }
        assertEquals(listOf("Salin", "Selesai"), n2.actions.map { it.title.toString() })

        val rem = InboxItem(44, "reminder", "Minum air", "", "reminder-2", 0, 2, 0, "Minum air", false)
        Notifier.show(app, rem)
        assertEquals(listOf("Salin", "Tunda 10 mnt"), nm.allNotifications.first { it.channelId == Notifier.CH_REMINDER }.actions.map { it.title.toString() })

        // Tombol Salin: teks langsung masuk clipboard tanpa membuka aplikasi.
        val pi = n.actions[0].actionIntent
        val sent: Intent = shadowOf(pi).savedIntent
        ActionReceiver().onReceive(app, sent)
        org.robolectric.shadows.ShadowLooper.idleMainLooper()
        Thread.sleep(300)
        org.robolectric.shadows.ShadowLooper.idleMainLooper()
        val clip = app.getSystemService(ClipboardManager::class.java).primaryClip
        assertNotNull(clip)
        assertEquals("ssh deploy@10.0.0.5 -p 2222", clip!!.getItemAt(0).text.toString())
    }
}
