package dev.nicholas.eclipse

import android.content.Context
import androidx.work.*
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.TimeUnit

/** The worker and activity share one Dart isolate, including during cold startup. */
object PhoneRuntime {
    private var engine: FlutterEngine? = null
    private var users = 0
    private var ready = CompletableDeferred<Unit>()
    private val mutex = Mutex()
    private lateinit var channel: MethodChannel

    fun acquire(context: Context): FlutterEngine {
        users++
        engine?.let { return it }
        val loader = io.flutter.FlutterInjector.instance().flutterLoader()
        loader.startInitialization(context.applicationContext)
        loader.ensureInitializationComplete(context.applicationContext, null)
        val created = FlutterEngine(context.applicationContext)
        Vault.register(created.dartExecutor.binaryMessenger)
        engine = created
        channel = MethodChannel(created.dartExecutor.binaryMessenger, "eclipse/background")
        channel.setMethodCallHandler { call, result ->
            if (call.method == "ready") {
                ready.complete(Unit)
                result.success(null)
            } else if (call.method == "widget") {
                TodayWidget.publish(context.applicationContext, call.arguments as String)
                result.success(null)
            } else result.notImplemented()
        }
        created.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        return created
    }

    fun release() {
        if (--users == 0) {
            channel.setMethodCallHandler(null)
            engine?.destroy()
            engine = null
            ready = CompletableDeferred()
        }
    }

    suspend fun sync(context: Context, input: Data): Boolean = mutex.withLock {
        ready.await()
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
        completed.await()
    }
}

class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result = withContext(Dispatchers.Main) {
        PhoneRuntime.acquire(applicationContext)
        try {
            if (withTimeoutOrNull(480_000) { PhoneRuntime.sync(applicationContext, inputData) } == true)
                Result.success() else Result.retry()
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
            val request = PeriodicWorkRequestBuilder<SyncWorker>(15, TimeUnit.MINUTES)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork("drive-sync", ExistingPeriodicWorkPolicy.KEEP, request)
        }
    }
}
