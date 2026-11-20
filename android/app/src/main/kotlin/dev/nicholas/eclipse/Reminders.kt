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
import androidx.work.workDataOf
import org.json.JSONArray
import java.time.LocalDateTime
import java.time.ZoneId

data class PlannedReminder(
    val id: Int,
    val uid: String,
    val triggerAt: Long,
    val title: String,
    val body: String,
    val key: String = "",
    val account: String = "",
)

/**
 * Pure planning and restore checks for scheduled reminders, kept independent of
 * Android framework classes so unit tests run directly on the JVM.
 */
object ReminderPlanner {
    const val MAX_ALARMS = 450

    val RESTORE_ACTIONS = setOf(
        Intent.ACTION_BOOT_COMPLETED,
        Intent.ACTION_MY_PACKAGE_REPLACED,
        Intent.ACTION_TIMEZONE_CHANGED,
        Intent.ACTION_TIME_CHANGED,
    )

    fun shouldRestore(action: String?): Boolean = action != null && RESTORE_ACTIONS.contains(action)

    fun plan(
        json: String,
        nowMillis: Long,
        zoneId: ZoneId = ZoneId.systemDefault(),
    ): List<PlannedReminder> {
        val list = JSONArray(json)
        val planned = ArrayList<PlannedReminder>(list.length())
        for (i in 0 until list.length()) {
            val reminder = list.getJSONObject(i)
            val exact = reminder.optBoolean("exact", false)
            val triggerAt =
                if (!exact &&
                    reminder.has("year") &&
                    reminder.has("month") &&
                    reminder.has("day") &&
                    reminder.has("hour") &&
                    reminder.has("minute")
                ) {
                    LocalDateTime.of(
                        reminder.getInt("year"),
                        reminder.getInt("month"),
                        reminder.getInt("day"),
                        reminder.getInt("hour"),
                        reminder.getInt("minute"),
                        reminder.optInt("second", 0),
                    )
                        .atZone(zoneId)
                        .toInstant()
                        .toEpochMilli()
                } else {
                    reminder.getLong("at")
                }
            if (triggerAt <= nowMillis) continue
            planned.add(
                PlannedReminder(
                    id = reminder.getString("key").hashCode(),
                    uid = reminder.optString("uid", ""),
                    triggerAt = triggerAt,
                    title = reminder.getString("title"),
                    body = reminder.getString("body"),
                    key = reminder.getString("key"),
                    account = if (reminder.isNull("account")) "" else reminder.getString("account"),
                ),
            )
        }
        planned.sortBy { it.triggerAt }
        return if (planned.size > MAX_ALARMS) planned.subList(0, MAX_ALARMS) else planned
    }
}

/**
 * Reminders set as alarms, so they go off with the app closed. Dart hands over
 * the whole list each time; it's kept, to set again after a restart, update,
 * or time zone change.
 */
object Reminders {
    private const val PREFS = "reminders"
    private const val LIST = "list"
    private const val COUNT = "count"
    const val CHANNEL = "reminders"
    const val EXTRA_UID = "uid"

    fun schedule(context: Context, json: String) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val alarms = context.getSystemService(AlarmManager::class.java)
        val planned = ReminderPlanner.plan(json, System.currentTimeMillis())
        for (i in 0 until prefs.getInt(COUNT, 0)) {
            alarms.cancel(pending(context, i, null))
        }
        var set = 0
        for (item in planned) {
            val intent = pending(context, set, item)
            if (Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms()) {
                alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, item.triggerAt, intent)
            } else {
                alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, item.triggerAt, intent)
            }
            set++
        }
        prefs.edit().putString(LIST, json).putInt(COUNT, set).apply()
    }

    fun startRest(context: Context, seconds: Int) {
        require(seconds in 1..3600)
        val alarms = context.getSystemService(AlarmManager::class.java)
        val whenDue = android.os.SystemClock.elapsedRealtime() + seconds * 1000L
        val alarm = pending(context, -1, PlannedReminder(-1, "", 0, "Rest complete", "Ready for your next set"))
        if (Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms()) {
            alarms.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, whenDue, alarm)
        } else {
            alarms.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, whenDue, alarm)
        }
    }

    fun cancelRest(context: Context) {
        val alarms = context.getSystemService(AlarmManager::class.java)
        alarms.cancel(pending(context, -1, null))
    }

    fun restore(context: Context) {
        val json = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(LIST, null) ?: return
        schedule(context, json)
    }

    private fun pending(context: Context, code: Int, reminder: PlannedReminder?): PendingIntent {
        val intent = Intent(context, ReminderReceiver::class.java)
        if (reminder != null) {
            intent.putExtra("title", reminder.title)
            intent.putExtra("body", reminder.body)
            intent.putExtra("id", reminder.id)
            intent.putExtra("key", reminder.key).putExtra("account", reminder.account)
            if (reminder.uid.isNotEmpty()) intent.putExtra(EXTRA_UID, reminder.uid)
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
        val action = intent.action
        if (action in setOf("done", "snooze")) {
            val key = intent.getStringExtra("key") ?: return
            SyncWorker.act(
                context,
                workDataOf(
                    "key" to key,
                    "action" to action,
                    "account" to intent.getStringExtra("account"),
                ),
            )
            if (intent.hasExtra("id")) {
                context.getSystemService(NotificationManager::class.java).cancel(intent.getIntExtra("id", 0))
            }
            return
        }
        if (action != null || !intent.hasExtra("id")) return
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(Reminders.CHANNEL, "Reminders", NotificationManager.IMPORTANCE_HIGH),
        )
        val id = intent.getIntExtra("id", 0)
        val uid = intent.getStringExtra(Reminders.EXTRA_UID)
        val openIntent = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (!uid.isNullOrEmpty()) openIntent.putExtra(Reminders.EXTRA_UID, uid)
        val open = PendingIntent.getActivity(
            context,
            id,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = Notification.Builder(context, Reminders.CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(intent.getStringExtra("title"))
            .setContentText(intent.getStringExtra("body"))
            .setContentIntent(open)
            .setAutoCancel(true)
        if (!uid.isNullOrEmpty()) {
            val key = intent.getStringExtra("key") ?: return
            for ((act, label) in listOf("snooze" to "Snooze 10 min", "done" to "Mark done")) {
                val command = Intent(context, ReminderReceiver::class.java).setAction(act)
                    .putExtra("key", key).putExtra("id", id).putExtra("account", intent.getStringExtra("account"))
                val pending = PendingIntent.getBroadcast(context, id, command, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                builder.addAction(Notification.Action.Builder(null, label, pending).build())
            }
        }
        manager.notify(id, builder.build())
    }
}

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            context.deleteSharedPreferences("widget")
        }
        if (ReminderPlanner.shouldRestore(intent.action)) Reminders.restore(context)
    }
}
