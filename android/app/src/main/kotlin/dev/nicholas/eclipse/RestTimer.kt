package dev.nicholas.eclipse

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager

internal object RestTimer {
    private const val DEADLINE = "deadline"
    private const val COUNTDOWN = "rest-countdown"
    private const val ALERT = "rest-alert"
    private const val COUNTDOWN_ID = 710
    private const val ALERT_ID = 711
    private const val TAG = "workout-rest"
    private const val ALARM_REQUEST = 710

    private fun prefs(context: Context) = context.getSharedPreferences("workout-rest", Context.MODE_PRIVATE)

    private fun alarm(context: Context, deadline: Long = 0) = PendingIntent.getBroadcast(
        context,
        ALARM_REQUEST,
        Intent(context, RestTimerReceiver::class.java).putExtra(DEADLINE, deadline),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun openApp(context: Context) = PendingIntent.getActivity(
        context,
        ALARM_REQUEST,
        Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE,
    )

    fun deadline(context: Context): Long? =
        prefs(context).getLong(DEADLINE, 0).takeIf { it > System.currentTimeMillis() }

    fun start(context: Context, deadline: Long) {
        require(deadline - System.currentTimeMillis() in 1..3_600_000L)
        val alarms = context.getSystemService(AlarmManager::class.java)
        alarms.setAlarmClock(AlarmManager.AlarmClockInfo(deadline, openApp(context)), alarm(context, deadline))
        prefs(context).edit().putLong(DEADLINE, deadline).apply()
        context.getSystemService(NotificationManager::class.java).cancel(TAG, ALERT_ID)
        showCountdown(context)
    }

    fun cancel(context: Context) {
        context.getSystemService(AlarmManager::class.java).cancel(alarm(context))
        prefs(context).edit().remove(DEADLINE).apply()
        val notifications = context.getSystemService(NotificationManager::class.java)
        notifications.cancel(TAG, COUNTDOWN_ID)
        notifications.cancel(TAG, ALERT_ID)
    }

    fun showCountdown(context: Context) {
        val deadline = deadline(context) ?: return
        val notifications = context.getSystemService(NotificationManager::class.java)
        if (!notifications.areNotificationsEnabled()) return
        notifications.createNotificationChannel(
            NotificationChannel(COUNTDOWN, "Rest countdown", NotificationManager.IMPORTANCE_LOW),
        )
        notifications.notify(
            TAG,
            COUNTDOWN_ID,
            notification(context, COUNTDOWN, "Workout rest timer")
                .setWhen(deadline)
                .setShowWhen(true)
                .setUsesChronometer(true)
                .setChronometerCountDown(true)
                .setOngoing(true)
                .build(),
        )
    }

    fun finish(context: Context, intent: Intent) {
        val deadline = intent.getLongExtra(DEADLINE, 0)
        if (deadline == 0L || deadline != prefs(context).getLong(DEADLINE, 0)) return
        prefs(context).edit().remove(DEADLINE).apply()
        val notifications = context.getSystemService(NotificationManager::class.java)
        notifications.cancel(TAG, COUNTDOWN_ID)
        if (!notifications.areNotificationsEnabled()) return
        notifications.createNotificationChannel(
            NotificationChannel(ALERT, "Rest timer alerts", NotificationManager.IMPORTANCE_HIGH).apply {
                setSound(
                    RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM),
                    AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build(),
                )
            },
        )
        notifications.notify(
            TAG,
            ALERT_ID,
            notification(context, ALERT, "Rest complete")
                .setContentText("Ready for your next set")
                .setAutoCancel(true)
                .build(),
        )
    }

    private fun notification(context: Context, channel: String, title: String) =
        Notification.Builder(context, channel)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentIntent(openApp(context))
            .setCategory(Notification.CATEGORY_ALARM)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
}

class RestTimerReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = RestTimer.finish(context, intent)
}
