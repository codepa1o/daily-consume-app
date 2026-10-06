package com.example.daily_consume

import android.Manifest
import android.app.ActivityOptions
import android.app.AlarmManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.ref.WeakReference

class MainActivity : FlutterActivity() {
    private lateinit var retainedUpdateChannel: MethodChannel
    private var pendingNotificationPermission: MethodChannel.Result? = null

    companion object {
        var updateChannel: WeakReference<MethodChannel>? = null
        private const val notificationPermissionRequest = 1333
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "daily_consume/updates")
        retainedUpdateChannel = channel
        updateChannel = WeakReference(channel)
        PomodoroAlert.ensureNotificationChannel(this)
        channel.setMethodCallHandler { call, result ->
            val prefs = getSharedPreferences("updates", MODE_PRIVATE)
            when (call.method) {
                "state" -> {
                    val info = packageManager.getPackageInfo(packageName, 0)
                    result.success(mapOf(
                        "packageName" to packageName,
                        "versionCode" to versionCode(info),
                        "versionName" to info.versionName,
                        "cacheDirectory" to cacheDir.absolutePath,
                        "seenVersion" to prefs.getLong("seenVersion", 0),
                        "installError" to prefs.getBoolean("installError", false)
                    ))
                    prefs.edit().remove("installError").apply()
                }
                "markSeen" -> {
                    prefs.edit().putLong("seenVersion", (call.arguments as Number).toLong()).apply()
                    result.success(null)
                }
                "canInstall" -> result.success(canInstall())
                "openInstallSettings" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= 26) {
                            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName")))
                        }
                        result.success(null)
                    } catch (_: Exception) {
                        result.error("SETTINGS", "请在系统设置中允许本应用安装更新", null)
                    }
                }
                "install" -> {
                    if (!canInstall()) {
                        result.success("permissionRequired")
                    } else {
                        val path = call.argument<String>("path")
                        val expected = call.argument<Number>("versionCode")?.toLong()
                        // APK parsing, signature checks and copying run off the UI thread.
                        Thread {
                            try {
                                install(File(requireNotNull(path)), requireNotNull(expected))
                                runOnUiThread { result.success("started") }
                            } catch (_: Exception) {
                                runOnUiThread { result.error("INSTALL", "无法安装更新，请确认安装包版本、签名和剩余空间", null) }
                            }
                        }.start()
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "daily_consume/pomodoro")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasNotificationPermission" -> result.success(hasNotificationPermission())
                    "requestNotificationPermission" -> requestNotificationPermission(result)
                    "openNotificationSettings" -> openNotificationSettings(result)
                    "canScheduleExactAlarms" -> result.success(canScheduleExactAlarms())
                    "openExactAlarmSettings" -> openExactAlarmSettings(result)
                    "scheduleReminder" -> schedulePomodoroReminder(call, result)
                    "cancelReminder" -> {
                        cancelPomodoroReminder()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasNotificationPermission(): Boolean {
        val permissionGranted = Build.VERSION.SDK_INT < 33 ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        val notificationsEnabled = Build.VERSION.SDK_INT < Build.VERSION_CODES.N ||
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .areNotificationsEnabled()
        return permissionGranted && notificationsEnabled
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33 ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(hasNotificationPermission())
            return
        }
        if (pendingNotificationPermission != null) {
            result.error("PERMISSION_PENDING", "通知权限请求正在处理中", null)
            return
        }
        pendingNotificationPermission = result
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS), notificationPermissionRequest
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == notificationPermissionRequest) {
            pendingNotificationPermission?.success(
                grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED &&
                    hasNotificationPermission()
            )
            pendingNotificationPermission = null
        }
    }

    private fun canScheduleExactAlarms() =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            (getSystemService(Context.ALARM_SERVICE) as AlarmManager).canScheduleExactAlarms()

    private fun openNotificationSettings(result: MethodChannel.Result) {
        try {
            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                    .putExtra(Settings.EXTRA_CHANNEL_ID, PomodoroAlert.CHANNEL)
            } else {
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
            }
            startActivity(intent)
            result.success(null)
        } catch (_: Exception) {
            result.error("SETTINGS", "无法打开通知设置", null)
        }
    }

    private fun openExactAlarmSettings(result: MethodChannel.Result) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !canScheduleExactAlarms()) {
                startActivity(Intent(
                    Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                    Uri.parse("package:$packageName")
                ))
            }
            result.success(null)
        } catch (_: Exception) {
            result.error("SETTINGS", "无法打开闹钟和提醒设置", null)
        }
    }

    private fun schedulePomodoroReminder(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result
    ) {
        val triggerAt = call.argument<Number>("triggerAtMillis")?.toLong()
        val phase = call.argument<String>("phase")
        if (triggerAt == null || phase !in setOf("focus", "shortBreak", "longBreak")) {
            result.error("INVALID_REMINDER", "番茄钟提醒参数无效", null)
            return
        }
        if (!canScheduleExactAlarms()) {
            result.error("EXACT_ALARM_PERMISSION", "需要允许闹钟和提醒权限", null)
            return
        }
        try {
            cancelPomodoroReminder()
            val intent = Intent(this, PomodoroAlarmReceiver::class.java)
                .setAction(PomodoroAlert.ACTION)
                .putExtra("phase", phase)
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
            val pending = PendingIntent.getBroadcast(this, PomodoroAlert.REQUEST_CODE, intent, flags)
            val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pending)
            } else {
                alarmManager.setExact(AlarmManager.RTC_WAKEUP, triggerAt, pending)
            }
            result.success(null)
        } catch (_: SecurityException) {
            result.error("EXACT_ALARM_PERMISSION", "需要允许闹钟和提醒权限", null)
        } catch (_: Exception) {
            result.error("SCHEDULE_FAILED", "无法设置番茄钟后台提醒", null)
        }
    }

    private fun cancelPomodoroReminder() {
        val intent = Intent(this, PomodoroAlarmReceiver::class.java).setAction(PomodoroAlert.ACTION)
        val flags = PendingIntent.FLAG_NO_CREATE or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
        PendingIntent.getBroadcast(this, PomodoroAlert.REQUEST_CODE, intent, flags)?.let {
            (getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(it)
            it.cancel()
        }
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .cancel(PomodoroAlert.NOTIFICATION_ID)
    }

    private fun canInstall() = Build.VERSION.SDK_INT < 26 || packageManager.canRequestPackageInstalls()

    @Suppress("DEPRECATION")
    private fun versionCode(info: android.content.pm.PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    @Suppress("DEPRECATION")
    private fun install(file: File, expected: Long) {
        require(file.canonicalFile.parentFile == cacheDir.canonicalFile && file.isFile)
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val incoming = requireNotNull(packageManager.getPackageArchiveInfo(file.path, flags))
        val current = packageManager.getPackageInfo(packageName, flags)
        require(incoming.packageName == packageName && versionCode(incoming) == expected && expected > versionCode(current))
        val incomingSigners = if (Build.VERSION.SDK_INT >= 28) incoming.signingInfo?.apkContentsSigners else incoming.signatures
        val currentSigners = if (Build.VERSION.SDK_INT >= 28) current.signingInfo?.apkContentsSigners else current.signatures
        require(!incomingSigners.isNullOrEmpty() && !currentSigners.isNullOrEmpty() &&
            incomingSigners.toSet() == currentSigners.toSet())

        val installer = packageManager.packageInstaller
        val prefs = getSharedPreferences("updates", MODE_PRIVATE)
        prefs.edit().putInt("activeSession", -1).apply()
        installer.mySessions.filter { it.appPackageName == packageName }.forEach {
            try { installer.abandonSession(it.sessionId) } catch (_: Exception) { }
        }
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(packageName)
        params.setSize(file.length())
        if (Build.VERSION.SDK_INT >= 31) {
            params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        }
        val id = installer.createSession(params)
        prefs.edit().putInt("activeSession", id).apply()
        try {
            installer.openSession(id).use { session ->
                file.inputStream().use { input ->
                    session.openWrite("base.apk", 0, file.length()).use { output ->
                        input.copyTo(output)
                        session.fsync(output)
                    }
                }
                val callback = Intent(this, MainActivity::class.java)
                    .setAction("$packageName.UPDATE_RESULT")
                val mutable = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or mutable
                val pending = if (Build.VERSION.SDK_INT >= 34) {
                    val startMode = if (Build.VERSION.SDK_INT >= 36) {
                        ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOW_ALWAYS
                    } else {
                        @Suppress("DEPRECATION")
                        ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED
                    }
                val options = ActivityOptions.makeBasic()
                    .setPendingIntentCreatorBackgroundActivityStartMode(startMode)
                    PendingIntent.getActivity(this, id, callback, flags, options.toBundle())
                } else {
                    PendingIntent.getActivity(this, id, callback, flags)
                }
                session.commit(pending.intentSender)
            }
        } catch (error: Exception) {
            installer.abandonSession(id)
            throw error
        }
    }
}
