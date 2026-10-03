package com.example.daily_consume

import android.app.PendingIntent
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
    companion object {
        var updateChannel: WeakReference<MethodChannel>? = null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "daily_consume/updates")
        retainedUpdateChannel = channel
        updateChannel = WeakReference(channel)
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
                val callback = Intent(this, UpdateInstallReceiver::class.java).setAction("$packageName.UPDATE_RESULT")
                val mutable = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
                val pending = PendingIntent.getBroadcast(this, id, callback, PendingIntent.FLAG_UPDATE_CURRENT or mutable)
                session.commit(pending.intentSender)
            }
        } catch (error: Exception) {
            installer.abandonSession(id)
            throw error
        }
    }
}
