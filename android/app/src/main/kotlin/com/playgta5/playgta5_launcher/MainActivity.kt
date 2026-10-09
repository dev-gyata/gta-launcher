package com.playgta5.playgta5_launcher

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    /** Starts the service once the notification permission request is answered (granted or not). */
    private var afterPermission: (() -> Unit)? = null

    /** Answers the pending storage access request once the user is back from the system screen or prompt. */
    private var afterStorage: ((Boolean) -> Unit)? = null

    /**
     * Whether the app may read any folder on the device storage by path. The game data (about 20 GB) is read with
     * random access through dart:io, which needs real paths, not the content:// links of the system folder picker.
     * Android 11+: "All files access" (MANAGE_EXTERNAL_STORAGE); before that, READ_EXTERNAL_STORAGE.
     */
    private fun hasStorageAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= 30) Environment.isExternalStorageManager()
        else checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ServerService.CHANNEL)
        // The notification's Stop button reaches the launcher's Dart code through this channel.
        ServerService.onStop = { runOnUiThread { channel.invokeMethod("stopRequested", null) } }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STORAGE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasAccess" -> result.success(hasStorageAccess())
                "requestAccess" -> {
                    if (hasStorageAccess()) {
                        result.success(true)
                    } else {
                        afterStorage = { result.success(it) }
                        if (Build.VERSION.SDK_INT >= 30) {
                            val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                                .setData(Uri.parse("package:$packageName"))
                            startActivityForResult(intent, STORAGE_REQUEST)
                        } else {
                            requestPermissions(arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE), STORAGE_REQUEST)
                        }
                    }
                }
                // Chrome's own pages (chrome://flags) cannot be opened from another app, so this only opens Chrome;
                // the launcher puts the address on the clipboard first.
                "openChrome" -> {
                    val intent = packageManager.getLaunchIntentForPackage("com.android.chrome")
                    if (intent != null) startActivity(intent)
                    result.success(intent != null)
                }
                "storageRoots" -> result.success(
                    // The device's main storage, then removable cards (from the app's own folder on each volume)
                    getExternalFilesDirs(null).filterNotNull().map { it.absolutePath.substringBefore("/Android/data/") }
                )
                else -> result.notImplemented()
            }
        }
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
        } else if (requestCode == STORAGE_REQUEST) {
            afterStorage?.invoke(hasStorageAccess())
            afterStorage = null
        }
    }

    @Deprecated("Needed for the All files access settings screen")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == STORAGE_REQUEST) {
            afterStorage?.invoke(hasStorageAccess())
            afterStorage = null
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        ServerService.onStop = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private companion object {
        const val NOTIFICATION_REQUEST = 1
        const val STORAGE_REQUEST = 2
        const val STORAGE_CHANNEL = "playgta5/storage"
    }
}
