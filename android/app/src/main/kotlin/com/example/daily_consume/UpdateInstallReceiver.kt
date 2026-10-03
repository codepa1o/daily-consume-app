package com.example.daily_consume

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build

class UpdateInstallReceiver : BroadcastReceiver() {
    @Suppress("DEPRECATION")
    override fun onReceive(context: Context, intent: Intent) {
        val active = context.getSharedPreferences("updates", Context.MODE_PRIVATE).getInt("activeSession", -1)
        if (active < 0 || intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -2) != active) return
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirmation = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                } else intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                try {
                    requireNotNull(confirmation).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(confirmation)
                } catch (_: Exception) { reportFailure(context) }
            }
            PackageInstaller.STATUS_SUCCESS -> {
                context.getSharedPreferences("updates", Context.MODE_PRIVATE).edit().remove("installError").apply()
            }
            else -> reportFailure(context)
        }
    }

    private fun reportFailure(context: Context) {
        context.getSharedPreferences("updates", Context.MODE_PRIVATE).edit().putBoolean("installError", true).apply()
        MainActivity.updateChannel?.get()?.invokeMethod("installFailure", null)
    }
}
