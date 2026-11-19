package dev.nicholas.eclipse

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.appwidget.AppWidgetProviderInfo
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject

class TodayWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) draw(context, manager, id)
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: android.os.Bundle) {
        draw(context, manager, id)
    }

    companion object {
        fun publish(context: Context, snapshot: String) {
            context.getSharedPreferences("widget", Context.MODE_PRIVATE).edit().putString("today", snapshot).apply()
            val manager = AppWidgetManager.getInstance(context)
            for (id in manager.getAppWidgetIds(ComponentName(context, TodayWidget::class.java))) draw(context, manager, id)
        }

        fun draw(context: Context, manager: AppWidgetManager, id: Int) {
            val prefs = context.getSharedPreferences("widget", Context.MODE_PRIVATE)
            val data = JSONObject(prefs.getString("today", "{}") ?: "{}")
            val rows = data.optJSONArray("rows")
            val total = rows?.length() ?: 0
            val options = manager.getAppWidgetOptions(id)
            val privateHost = options.getInt(AppWidgetManager.OPTION_APPWIDGET_HOST_CATEGORY) != AppWidgetProviderInfo.WIDGET_CATEGORY_HOME_SCREEN
            val capacity = ((options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 180) - 100) / 40).coerceIn(1, 12)
            val pages = ((total + capacity - 1) / capacity).coerceAtLeast(1)
            val page = prefs.getInt("page$id", 0) % pages
            val views = RemoteViews(context.packageName, R.layout.today_widget)
            val day = data.optString("day")
            views.setTextViewText(R.id.day, if (day.isEmpty()) "Eclipse" else "Today · $day")
            val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            val capture = Intent(context, QuickTaskActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            views.setOnClickPendingIntent(R.id.add_task, PendingIntent.getActivity(context, 0, capture, flags))
            views.removeAllViews(R.id.rows)
            if (privateHost) {
                views.setViewVisibility(R.id.day, View.GONE)
                views.setViewVisibility(R.id.rows, View.GONE)
                views.setViewVisibility(R.id.more, View.GONE)
                manager.updateAppWidget(id, views)
                return
            }
            views.setViewVisibility(R.id.day, View.VISIBLE)
            views.setViewVisibility(R.id.rows, View.VISIBLE)
            val launch = Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            views.setContentDescription(R.id.day, "Open Eclipse")
            views.setOnClickPendingIntent(R.id.day, PendingIntent.getActivity(context, 1, launch, flags))
            fun tap(action: String, key: String): PendingIntent {
                val intent = Intent(context, ReminderReceiver::class.java).setAction(action)
                    .setData(Uri.Builder().scheme("eclipse").authority("widget").appendPath(id.toString()).appendPath(day).appendPath(key).build())
                    .putExtra("widget", id).putExtra("day", day).putExtra("account", data.optString("account")).putExtra("key", key)
                return PendingIntent.getBroadcast(context, id, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            }
            for (i in page * capacity until minOf((page + 1) * capacity, total)) {
                val row = rows!!.getJSONObject(i)
                val item = RemoteViews(context.packageName, R.layout.today_widget_row)
                item.setTextViewText(R.id.label, "○  " + row.getString("text"))
                item.setOnClickPendingIntent(R.id.label, tap(row.getString("action"), row.getString("key")))
                views.addView(R.id.rows, item)
            }
            views.setViewVisibility(R.id.more, if (pages > 1) View.VISIBLE else View.GONE)
            views.setOnClickPendingIntent(R.id.more, tap("next", ""))
            manager.updateAppWidget(id, views)
        }
    }
}
