package dev.nicholas.eclipse

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject

/**
 * Reminders set as alarms, so they go off with the app closed. Dart hands over
 * the whole list each time; it's kept, to set again after a restart.
 */
object Reminders {
    private const val PREFS = "reminders"
    private const val LIST = "list"
    private const val COUNT = "count"
    const val CHANNEL = "reminders"

    fun schedule(context: Context, json: String) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val alarms = context.getSystemService(AlarmManager::class.java)
        for (i in 0 until prefs.getInt(COUNT, 0)) {
            alarms.cancel(pending(context, i, null))
        }
        val list = JSONArray(json)
        val now = System.currentTimeMillis()
        var set = 0
        for (i in 0 until list.length()) {
            val reminder = list.getJSONObject(i)
            val at = reminder.getLong("at")
            if (at <= now) continue
            val intent = pending(context, set, reminder)
            if (Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms()) {
                alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, intent)
            } else {
                alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, intent)
            }
            set++
        }
        prefs.edit().putString(LIST, json).putInt(COUNT, set).apply()
    }

    fun restore(context: Context) {
        val json = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(LIST, null) ?: return
        schedule(context, json)
    }

    private fun pending(context: Context, code: Int, reminder: JSONObject?): PendingIntent {
        val intent = Intent(context, ReminderReceiver::class.java)
        if (reminder != null) {
            intent.putExtra("title", reminder.getString("title"))
            intent.putExtra("body", reminder.getString("body"))
            intent.putExtra("id", reminder.getString("key").hashCode())
        }
        return PendingIntent.getBroadcast(
            context,
            code,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}

class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(Reminders.CHANNEL, "Reminders", NotificationManager.IMPORTANCE_HIGH),
        )
        val open = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        manager.notify(
            intent.getIntExtra("id", 0),
            Notification.Builder(context, Reminders.CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(intent.getStringExtra("title"))
                .setContentText(intent.getStringExtra("body"))
                .setContentIntent(open)
                .setAutoCancel(true)
                .build(),
        )
    }
}

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) Reminders.restore(context)
    }
}
