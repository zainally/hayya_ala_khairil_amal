package com.hayya.hayya_ala_khairil_amal

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetPlugin

class PrayerWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        for (appWidgetId in appWidgetIds) {
            try {
                val widgetData = HomeWidgetPlugin.getData(context)
                val views = RemoteViews(context.packageName, R.layout.prayer_widget)

                // Render the active Hijri date string
                views.setTextViewText(R.id.widget_hijri_date, widgetData.getString("hijri_date", "---"))
                
                // Render the prayer time strings
                views.setTextViewText(R.id.widget_fajr_time, widgetData.getString("time_fajr", "--:--"))
                views.setTextViewText(R.id.widget_dhuhr_time, widgetData.getString("time_dhuhr", "--:--"))
                views.setTextViewText(R.id.widget_asr_time, widgetData.getString("time_asr", "--:--"))
                views.setTextViewText(R.id.widget_maghrib_time, widgetData.getString("time_maghrib", "--:--"))
                views.setTextViewText(R.id.widget_isha_time, widgetData.getString("time_isha", "--:--"))

                val prayers = listOf("fajr", "dhuhr", "asr", "maghrib", "isha")
                val nameComponentIds = listOf(R.id.widget_fajr_name, R.id.widget_dhuhr_name, R.id.widget_asr_name, R.id.widget_maghrib_name, R.id.widget_isha_name)
                val timeComponentIds = listOf(R.id.widget_fajr_time, R.id.widget_dhuhr_time, R.id.widget_asr_time, R.id.widget_maghrib_time, R.id.widget_isha_time)

                val nextActivePrayerKey = widgetData.getString("next_prayer", "")

                for (i in prayers.indices) {
                    if (prayers[i] == nextActivePrayerKey) {
                        views.setTextColor(nameComponentIds[i], Color.parseColor("#00796B"))
                        views.setTextColor(timeComponentIds[i], Color.parseColor("#00796B"))
                    } else {
                        views.setTextColor(nameComponentIds[i], Color.parseColor("#222222"))
                        views.setTextColor(timeComponentIds[i], Color.parseColor("#555555"))
                    }
                }

                val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
                if (intent != null) {
                    val pendingIntent = PendingIntent.getActivity(
                        context, 
                        0, 
                        intent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                    )
                    views.setOnClickPendingIntent(R.id.widget_container, pendingIntent)
                }

                appWidgetManager.updateAppWidget(appWidgetId, views)
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }
}