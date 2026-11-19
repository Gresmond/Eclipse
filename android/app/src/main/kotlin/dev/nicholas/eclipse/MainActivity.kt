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
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "eclipse/phone").setMethodCallHandler { call, result ->
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
                "schedule" -> {
                    Reminders.schedule(this, call.arguments as String)
                    result.success(null)
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
