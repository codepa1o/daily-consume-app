package com.example.daily_consume

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.os.Bundle

class UpdateCompletionActivity : Activity() {
    @Suppress("DEPRECATION")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> showInstallerConfirmation()
            PackageInstaller.STATUS_SUCCESS -> launchUpdatedApp()
            else -> reportInstallFailure()
        }
    }

    private fun showInstallerConfirmation() {
        val confirmation = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
        } else {
            intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
        }
        if (confirmation == null) {
            reportInstallFailure()
            return
        }
        try {
            confirmation.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(confirmation)
        } catch (_: Exception) {
            reportInstallFailure()
        }
        finish()
    }

    private fun launchUpdatedApp() {
        getSharedPreferences("updates", MODE_PRIVATE).edit()
            .remove("installError")
            .apply()
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        if (launch == null) {
            finish()
            return
        }
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or
            Intent.FLAG_ACTIVITY_CLEAR_TOP or
            Intent.FLAG_ACTIVITY_SINGLE_TOP)
        try {
            startActivity(launch)
        } catch (_: Exception) {
            // Keep the update log available on the next manual launch.
        }
        finish()
    }

    private fun reportInstallFailure() {
        getSharedPreferences("updates", MODE_PRIVATE).edit()
            .putBoolean("installError", true)
            .apply()
        MainActivity.updateChannel?.get()?.invokeMethod("installFailure", null)
        finish()
    }
}
