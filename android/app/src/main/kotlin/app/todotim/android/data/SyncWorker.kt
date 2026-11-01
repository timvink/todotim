package app.todotim.android.data

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import app.todotim.android.TodoTimApplication
import java.util.concurrent.TimeUnit

/** Background sync every 15 minutes while connected. Uses the app's [SyncManager], so it never overlaps a UI sync. */
class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val loaded = try {
            (applicationContext as TodoTimApplication).graph.await()
        } catch (e: Exception) {
            return Result.failure()
        }
        // Failures land in the sync status; the next period tries again.
        loaded.sync.sync()
        return Result.success()
    }

    companion object {
        private const val NAME = "sync"

        fun schedule(context: Context) {
            val request = PeriodicWorkRequestBuilder<SyncWorker>(15, TimeUnit.MINUTES)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(NAME, ExistingPeriodicWorkPolicy.KEEP, request)
        }
    }
}
