package dev.nicholas.eclipse

import android.content.Context
import androidx.work.*
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.TimeUnit

/** The worker and activity share one Dart isolate, including during cold startup. */
object PhoneRuntime {
    private var engine: FlutterEngine? = null
    private var users = 0
    private var uiAttached = false
    private var ready = CompletableDeferred<Boolean>()
    private lateinit var channel: MethodChannel

    val current: FlutterEngine? get() = engine

    // Called on Android's main thread by both the activity and the worker.
    fun retain(context: Context, created: FlutterEngine, withUi: Boolean = false) {
        if (withUi) uiAttached = true
        if (users > 0) {
            check(engine === created)
            users++
            return
        }
        channel = MethodChannel(created.dartExecutor.binaryMessenger, "eclipse/background")
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasUi" -> result.success(uiAttached)
                "ready" -> {
                    if (ready.isCompleted) ready = CompletableDeferred()
                    ready.complete(true)
                    try {
                        if (call.arguments as? Boolean == true) {
                            SyncWorker.schedule(context)
                        } else {
                            SyncWorker.cancel(context)
                        }
                        result.success(uiAttached)
                    } catch (e: IllegalStateException) {
                        result.error("schedule", e.message, null)
                    }
                }
                "schedule" -> {
                    try {
                        Reminders.schedule(context, call.arguments as String)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("schedule", e.message, null)
                    }
                }
                "scheduleSync" -> {
                    try {
                        if (call.arguments as? Boolean == true) {
                            SyncWorker.schedule(context)
                        } else {
                            SyncWorker.cancel(context)
                        }
                        result.success(null)
                    } catch (e: IllegalStateException) {
                        result.error("schedule", e.message, null)
                    }
                }
                "startupError" -> {
                    ready.complete(false)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        engine = created
        users = 1
    }

    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    fun attachUi() {
        uiAttached = true
        if (users > 0 && ready.isCompleted && runCatching { ready.getCompleted() }.getOrDefault(false)) {
            channel.invokeMethod("attachUi", null)
        }
    }

    fun release() {
        if (users <= 0) return
        if (--users == 0) {
            channel.setMethodCallHandler(null)
            engine?.destroy()
            engine = null
            uiAttached = false
            ready = CompletableDeferred()
        }
    }

    suspend fun sync(context: Context, input: Data): Boolean {
        if (!ready.await()) return false
        val completed = CompletableDeferred<Boolean>()
        channel.invokeMethod(if (input.getString("action") == null) "sync" else "action", input.keyValueMap, object : MethodChannel.Result {
            override fun success(result: Any?) {
                try {
                    if (result is String) Reminders.schedule(context, result)
                    completed.complete(true)
                } catch (e: Exception) { completed.complete(false) }
            }
            override fun error(code: String, message: String?, details: Any?) { completed.complete(false) }
            override fun notImplemented() { completed.complete(false) }
        })
        return completed.await()
    }
}

class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result = withContext(Dispatchers.Main) {
        // Start Dart headlessly only when the worker creates the engine.
        val existing = PhoneRuntime.current
        val engine = existing ?: FlutterEngine(applicationContext)
        PhoneRuntime.retain(applicationContext, engine)
        try {
            if (existing == null) {
                engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            }
            if (withTimeoutOrNull(480_000) { PhoneRuntime.sync(applicationContext, inputData) } == true) {
                Result.success()
            } else if (runAttemptCount >= 3) {
                Result.failure()
            } else {
                Result.retry()
            }
        } finally {
            PhoneRuntime.release()
        }
    }

    companion object {
        fun act(context: Context, data: Data) {
            val work = OneTimeWorkRequestBuilder<SyncWorker>().setInputData(data).build()
            WorkManager.getInstance(context).enqueueUniqueWork("eclipse-actions", ExistingWorkPolicy.APPEND_OR_REPLACE, work)
        }

        fun schedule(context: Context) {
            val request = PeriodicWorkRequestBuilder<SyncWorker>(30, TimeUnit.MINUTES)
                .setInitialDelay(30, TimeUnit.MINUTES)
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(NetworkType.CONNECTED)
                        .setRequiresBatteryNotLow(true)
                        .build(),
                )
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork("drive-sync", ExistingPeriodicWorkPolicy.UPDATE, request)
        }

        fun cancel(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork("drive-sync")
        }
    }
}
