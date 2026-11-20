package dev.nicholas.eclipse

import android.Manifest
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.widget.Toast
import androidx.core.content.FileProvider
import androidx.core.content.pm.PackageInfoCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** What Dart can't do by itself on a phone, over one channel. */
class MainActivity : FlutterActivity() {
    private companion object {
        const val REST_NOTIFICATION_REQUEST = 2
    }
    // On a cold launch, let FlutterActivity create and attach its own engine.
    // A running worker already owns the database, so reuse its isolate.
    override fun provideFlutterEngine(context: android.content.Context): FlutterEngine? = PhoneRuntime.current
    override fun shouldDestroyEngineWithHost(): Boolean = false

    private var retained = false
    private var pendingReminderUid: String? = null
    private var phoneChannel: MethodChannel? = null

    override fun onDestroy() {
        super.onDestroy()
        if (retained) {
            retained = false
            PhoneRuntime.release()
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        phoneChannel?.setMethodCallHandler(null)
        phoneChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

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

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REST_NOTIFICATION_REQUEST) return
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            RestTimer.showCountdown(this)
        } else {
            Toast.makeText(this, "Allow Eclipse notifications for rest timer sounds.", Toast.LENGTH_LONG).show()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val reused = PhoneRuntime.current === flutterEngine
        PhoneRuntime.retain(applicationContext, flutterEngine)
        retained = true
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "eclipse/phone")
        phoneChannel = channel
        takeReminderUid(intent)?.let { uid ->
            if (reused) {
                channel.invokeMethod("openReminder", uid)
            } else {
                pendingReminderUid = uid
            }
        }
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
                "startRest" -> {
                    try {
                        RestTimer.start(this, (call.arguments as Number).toLong())
                        if (Build.VERSION.SDK_INT >= 33 &&
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                        ) {
                            requestPermissions(
                                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                REST_NOTIFICATION_REQUEST,
                            )
                        } else if (!getSystemService(NotificationManager::class.java).areNotificationsEnabled()) {
                            Toast.makeText(this, "Allow Eclipse notifications for rest timer sounds.", Toast.LENGTH_LONG).show()
                        }
                        result.success(null)
                    } catch (_: SecurityException) {
                        result.error("rest_alarm", "Allow Eclipse to schedule exact alarms for rest timer sounds.", null)
                    }
                }
                "restDeadline" -> result.success(RestTimer.deadline(this))
                "cancelRest" -> {
                    RestTimer.cancel(this)
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
