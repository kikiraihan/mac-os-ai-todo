package com.kikiraihan.aitodo

import android.Manifest
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.lifecycleScope
import com.kikiraihan.aitodo.ui.AITodoTheme
import com.kikiraihan.aitodo.ui.LoginScreen
import com.kikiraihan.aitodo.ui.MainModel
import com.kikiraihan.aitodo.ui.MainScreen
import com.kikiraihan.aitodo.ui.Tab
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val model: MainModel by viewModels()
    private var openTab by mutableStateOf<Tab?>(null)
    private var openClip by mutableLongStateOf(0L)
    private val askNotifications = registerForActivityResult(ActivityResultContracts.RequestPermission()) {
        lifecycleScope.launch { Push.setup(applicationContext) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        handle(intent)
        setContent {
            AITodoTheme {
                Surface(Modifier.fillMaxSize()) {
                    if (model.loggedIn) {
                        MainScreen(model, openTab, openClip) { openTab = null; openClip = 0 }
                    } else {
                        LoginScreen(model)
                    }
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    /** Dibuka dari notifikasi: langsung ke tab yang sesuai (kiriman → disorot dengan tombol Salin besar). */
    private fun handle(i: Intent?) {
        openTab = when (i?.getStringExtra("open")) {
            "clip" -> Tab.Clips
            "reminder" -> Tab.Reminders
            "due", "brief", "nudge" -> Tab.Todo
            else -> null
        }
        openClip = i?.getLongExtra("clipId", 0) ?: 0
    }

    override fun onStart() {
        super.onStart()
        if (model.loggedIn) {
            if (Build.VERSION.SDK_INT >= 33 && !Notifier.allowed(this)) askNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
            model.start()
        }
    }

    override fun onStop() {
        // Long-poll aplikasi berhenti saat tidak terlihat (notifikasi tetap lewat FCM / SyncService).
        model.stopPolling()
        super.onStop()
    }
}
