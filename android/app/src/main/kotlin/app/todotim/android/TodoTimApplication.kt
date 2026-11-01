package app.todotim.android

import android.app.Application
import app.todotim.android.data.AppGraph
import app.todotim.android.data.SyncWorker

class TodoTimApplication : Application() {
    lateinit var graph: AppGraph
        private set

    override fun onCreate() {
        super.onCreate()
        graph = AppGraph(this)
        SyncWorker.schedule(this)
    }
}
