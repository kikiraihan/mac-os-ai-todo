package com.kikiraihan.aitodo

import android.app.Application

class App : Application() {
    override fun onCreate() {
        super.onCreate()
        Notifier.channels(this)
        Push.initFirebase(this)
    }
}
