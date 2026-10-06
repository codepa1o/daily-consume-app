package com.example.daily_consume

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build

internal object PomodoroAlert {
    const val ACTION = "com.example.daily_consume.POMODORO_ALERT"
    const val REQUEST_CODE = 1334
    const val NOTIFICATION_ID = 1334
    const val CHANNEL = "pomodoro_completion_v2"

    fun soundUri(context: Context): Uri =
        Uri.parse("android.resource://${context.packageName}/raw/pomodoro_chime")

    fun ensureNotificationChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL) != null) return

        val audioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        val channel = NotificationChannel(
            CHANNEL, "番茄钟提醒", NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "番茄钟阶段结束时播放专属铃声并振动"
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 350, 180, 350)
            setSound(soundUri(context), audioAttributes)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }
}

class PomodoroAlarmReceiver : BroadcastReceiver() {
    @Suppress("DEPRECATION")
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != PomodoroAlert.ACTION) return
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && !manager.areNotificationsEnabled()) return

        val phase = intent.getStringExtra("phase") ?: return
        PomodoroAlert.ensureNotificationChannel(context)
        val focusEnded = phase == "focus"
        val openApp = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
        val contentIntent = PendingIntent.getActivity(
            context, PomodoroAlert.NOTIFICATION_ID, openApp, pendingFlags
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, PomodoroAlert.CHANNEL)
        } else {
            Notification.Builder(context).apply {
                setSound(PomodoroAlert.soundUri(context))
                setVibrate(longArrayOf(0, 350, 180, 350))
                setPriority(Notification.PRIORITY_HIGH)
            }
        }
        val notification = builder
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle(if (focusEnded) "专注时间结束" else "休息时间结束")
            .setContentText(if (focusEnded) "专注时段已结束，休息一下。" else "休息结束，可以开始下一轮。")
            .setCategory(Notification.CATEGORY_ALARM)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentIntent(contentIntent)
            .setOnlyAlertOnce(true)
            .setAutoCancel(true)
            .build()
        manager.notify(PomodoroAlert.NOTIFICATION_ID, notification)
    }
}
