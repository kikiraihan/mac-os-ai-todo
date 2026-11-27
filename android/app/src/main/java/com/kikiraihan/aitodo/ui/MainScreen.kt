package com.kikiraihan.aitodo.ui

import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Chat
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.ContentPaste
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.CloudOff
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.nestedscroll.nestedScroll

enum class Tab(val label: String, val icon: ImageVector) {
    Chat("Asisten", Icons.AutoMirrored.Outlined.Chat),
    Todo("Todo", Icons.Outlined.CheckCircle),
    Reminders("Pengingat", Icons.Outlined.Notifications),
    Notes("Catatan", Icons.Outlined.Description),
    Clips("Kiriman", Icons.Outlined.ContentPaste),
}

/** Menu bawah 5 tab (pola Android); judul besar; tombol utama = ikon bulat (＋). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(model: MainModel, openTab: Tab?, openClip: Long, onOpened: () -> Unit) {
    var tab by remember { mutableIntStateOf(model.prefs.lastTab.coerceIn(0, Tab.entries.size - 1)) }
    var settings by remember { mutableStateOf(false) }
    var adding by remember { mutableStateOf(false) }
    var focusClip by remember { mutableStateOf(0L) }
    val snack = remember { SnackbarHostState() }

    LaunchedEffect(openTab, openClip) {
        if (openTab != null) {
            tab = openTab.ordinal
            focusClip = openClip
            onOpened()
        }
    }
    LaunchedEffect(tab) { model.prefs.lastTab = tab }
    LaunchedEffect(model.message) {
        model.message?.let {
            snack.showSnackbar(it)
            model.message = null
        }
    }

    if (settings) return SettingsScreen(model) { settings = false }

    val current = Tab.entries[tab]
    val scroll = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    Scaffold(
        modifier = Modifier.nestedScroll(scroll.nestedScrollConnection),
        topBar = {
            LargeTopAppBar(
                title = { Text(current.label) },
                actions = {
                    if (!model.online) Icon(Icons.Outlined.CloudOff, "Offline")
                    IconButton(onClick = { settings = true }) { Icon(Icons.Outlined.Settings, "Pengaturan") }
                },
                scrollBehavior = scroll,
            )
        },
        bottomBar = {
            NavigationBar {
                Tab.entries.forEach { t ->
                    NavigationBarItem(
                        selected = t == current,
                        onClick = { tab = t.ordinal },
                        icon = { Icon(t.icon, null) },
                        label = { Text(t.label) },
                    )
                }
            }
        },
        floatingActionButton = {
            if (current == Tab.Todo || current == Tab.Reminders || current == Tab.Notes) {
                FloatingActionButton(onClick = { adding = true }) { Icon(Icons.Outlined.Add, "Tambah") }
            }
        },
        snackbarHost = { SnackbarHost(snack) },
    ) { pad ->
        val m = Modifier.padding(pad)
        when (current) {
            Tab.Chat -> ChatScreen(model, m)
            Tab.Todo -> TodoScreen(model, m, adding) { adding = false }
            Tab.Reminders -> RemindersScreen(model, m, adding) { adding = false }
            Tab.Notes -> NotesScreen(model, m, adding) { adding = false }
            Tab.Clips -> ClipsScreen(model, m, focusClip) { focusClip = 0 }
        }
    }
}
