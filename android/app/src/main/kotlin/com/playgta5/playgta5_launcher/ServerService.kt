package com.playgta5.playgta5_launcher

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Keeps the app process, and the game server running in its Dart code, alive while the game plays in Chrome.
 * Android stops background work of an app within about a minute; a foreground service with a visible notification
 * is the supported way to keep it. The notification's Stop button asks the launcher to stop the server.
 */
class ServerService : Service() {
    companion object {
        const val CHANNEL = "playgta5/server_service"
        const val EXTRA_URL = "url"
        private const val ACTION_STOP = "com.playgta5.playgta5_launcher.STOP_SERVER"
        private const val NOTIFICATION_CHANNEL = "game_server"
        private const val NOTIFICATION_ID = 1

        /** Set by MainActivity while its Flutter engine is attached. */
        var onStop: (() -> Unit)? = null
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            onStop?.invoke()
            stopSelf()
            return START_NOT_STICKY
        }
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(NOTIFICATION_CHANNEL, "Game server", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shown while the game server runs for the browser"
            }
        )
        val flagsImmutable = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        val stop = PendingIntent.getService(
            this, 0, Intent(this, ServerService::class.java).setAction(ACTION_STOP), flagsImmutable
        )
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), flagsImmutable
        )
        val notification = Notification.Builder(this, NOTIFICATION_CHANNEL)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("Game server running")
            .setContentText(intent?.getStringExtra(EXTRA_URL) ?: "Serving the game to the browser")
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // The app was swiped away: the server dies with the process, so the notification goes too.
        stopSelf()
    }
}
