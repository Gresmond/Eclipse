package dev.nicholas.eclipse

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.core.content.pm.PackageInfoCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** What Dart can't do by itself on a phone, over one channel. */
class MainActivity : FlutterActivity() {
    // On a cold launch, let FlutterActivity create and attach its own engine.
    // A running worker already owns the database, so reuse its isolate.
    override fun provideFlutterEngine(context: android.content.Context): FlutterEngine? = PhoneRuntime.current
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onDestroy() {
        super.onDestroy()
        PhoneRuntime.release()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        phoneChannel?.setMethodCallHandler(null)
        phoneChannel = null
        exportResult?.success(false)
        exportResult = null
        exportFile = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private var exportFile: File? = null
    private var exportResult: MethodChannel.Result? = null

    @Deprecated("Platform activity result callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 91) return
        val callback = exportResult ?: return
        val file = exportFile
        exportResult = null
        exportFile = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null || file == null) { callback.success(false); return }
        Thread {
            try {
                requireNotNull(contentResolver.openOutputStream(uri)).use { out -> file.inputStream().use { it.copyTo(out) } }
                runOnUiThread { callback.success(true) }
            } catch (e: Exception) {
                runOnUiThread { callback.error("export", e.message, null) }
            }
        }.start()
    }

    private var pendingReminderUid: String? = null
    private var phoneChannel: MethodChannel? = null

    private fun takeReminderUid(intent: Intent?): String? {
        val uid = intent?.getStringExtra(Reminders.EXTRA_UID)
        if (!uid.isNullOrEmpty()) {
            intent.removeExtra(Reminders.EXTRA_UID)
            return uid
        }
        return null
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val uid = takeReminderUid(intent) ?: return
        val channel = phoneChannel
        if (channel != null) {
            channel.invokeMethod("openReminder", uid)
        } else {
            pendingReminderUid = uid
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        PhoneRuntime.retain(applicationContext, flutterEngine)
        takeReminderUid(intent)?.let { pendingReminderUid = it }
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "eclipse/phone")
        phoneChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "openUrl" -> {
                    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(call.arguments as String)))
                    result.success(null)
                }
                // Back from the browser once a sign-in has come through.
                "toFront" -> {
                    startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT))
                    result.success(null)
                }
                "version" -> result.success(packageManager.getPackageInfo(packageName, 0).versionName)
                "versionCode" -> result.success(
                    PackageInfoCompat.getLongVersionCode(packageManager.getPackageInfo(packageName, 0)),
                )
                "askNotifications" -> {
                    if (Build.VERSION.SDK_INT >= 33 &&
                        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                    ) {
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
                    }
                    result.success(null)
                }
                "saveExport" -> {
                    val name = call.argument<String>("name")!!
                    val file = File(call.argument<String>("path")!!).canonicalFile
                    if (exportResult != null || file.parentFile != cacheDir.canonicalFile || file.name != name) {
                        result.error("export", "Unavailable export", null)
                    } else {
                        exportResult = result
                        exportFile = file
                        startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT)
                            .addCategory(Intent.CATEGORY_OPENABLE).setType(if (name.endsWith(".ics")) "text/calendar" else "application/zip")
                            .putExtra(Intent.EXTRA_TITLE, name), 91)
                    }
                }
                "startRest" -> {
                    Reminders.startRest(this, call.arguments as Int)
                    result.success(null)
                }
                "schedule" -> {
                    Reminders.schedule(this, call.arguments as String)
                    result.success(null)
                }
                "initialReminder" -> {
                    val uid = pendingReminderUid
                    pendingReminderUid = null
                    result.success(uid)
                }
                "install" -> {
                    val updatesDir = File(cacheDir, "updates").canonicalFile
                    val target = File(call.arguments as String).canonicalFile
                    if (target.parentFile != updatesDir || !target.name.endsWith(".apk") || !target.isFile) {
                        result.error("invalid_path", "Update file must be in the updates cache.", null)
                    } else if (!packageManager.canRequestPackageInstalls()) {
                        startActivity(
                            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")),
                        )
                        result.success(false)
                    } else {
                        val apk = FileProvider.getUriForFile(this, "$packageName.files", target)
                        startActivity(
                            Intent(Intent.ACTION_VIEW)
                                .setDataAndType(apk, "application/vnd.android.package-archive")
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
                        )
                        result.success(true)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
