package com.playgta5.playgta5_launcher

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    /** Starts the service once the notification permission request is answered (granted or not). */
    private var afterPermission: (() -> Unit)? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ServerService.CHANNEL)
        // The notification's Stop button reaches the launcher's Dart code through this channel.
        ServerService.onStop = { runOnUiThread { channel.invokeMethod("stopRequested", null) } }
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val start = {
                        val intent = Intent(this, ServerService::class.java)
                            .putExtra(ServerService.EXTRA_URL, call.argument<String>("url"))
                        startForegroundService(intent)
                        result.success(null)
                    }
                    if (Build.VERSION.SDK_INT >= 33 &&
                        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                    ) {
                        // Asked before the browser opens (it would cover the prompt). If refused, the service still
                        // runs; only its notification, with the Stop button, is hidden.
                        afterPermission = start
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATION_REQUEST)
                    } else {
                        start()
                    }
                }
                "stop" -> {
                    stopService(Intent(this, ServerService::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == NOTIFICATION_REQUEST) {
            afterPermission?.invoke()
            afterPermission = null
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        ServerService.onStop = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private companion object {
        const val NOTIFICATION_REQUEST = 1
    }
}
