package com.fanrenxiuxianguanyingchuan

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * 数据库导入前台服务（2026-11-28 后台导入批）：导入大文件要
 * 十几分钟，切后台/锁屏时没有原生承载，容器可能暂停或杀掉
 * 进程。本服务只做承载：常驻一条低优先级通知（标题固定
 * 「正在导入数据库」，文本随 Dart 侧进度节流刷新），并在存
 * 在期间持 PARTIAL_WAKE_LOCK 防 CPU 休眠；导入逻辑仍在 Dart
 * 侧的 ImportJobService 里跑，本服务不碰任何文件。
 *
 * 结束口径：Dart 侧 stop 时先换一条「导入完成/失败」的普通
 * 通知（可划除、点开回应用），再 stopSelf 撤前台身份。
 */
class ImportForegroundService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        acquireWakeLock()
    }

    override fun onDestroy() {
        releaseWakeLock()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                val success = intent.getBooleanExtra(EXTRA_SUCCESS, false)
                val text = intent.getStringExtra(EXTRA_TEXT)
                    ?: if (success) "数据库导入完成" else "数据库导入失败"
                postResultNotification(success, text)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_UPDATE -> {
                val text = intent.getStringExtra(EXTRA_TEXT) ?: currentText
                val fraction = intent.getDoubleExtra(EXTRA_FRACTION, -1.0)
                currentText = text
                notifyProgress(text, fraction)
                return START_NOT_STICKY
            }
            else -> {
                val text = intent?.getStringExtra(EXTRA_TEXT) ?: currentText
                currentText = text
                val notification = buildProgressNotification(text, -1.0)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    ServiceCompat.startForeground(
                        this,
                        NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                    )
                } else {
                    startForeground(NOTIFICATION_ID, notification)
                }
                return START_NOT_STICKY
            }
        }
    }

    private fun notifyProgress(text: String, fraction: Double) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildProgressNotification(text, fraction))
    }

    private fun buildProgressNotification(text: String, fraction: Double): Notification {
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("正在导入数据库")
            .setContentText(text)
            .setContentIntent(contentIntent())
            .setOngoing(true)
            .setSilent(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setPriority(NotificationCompat.PRIORITY_LOW)
        if (fraction >= 0) {
            builder.setProgress(100, (fraction * 100).toInt().coerceIn(0, 100), false)
        } else {
            builder.setProgress(0, 0, true)
        }
        return builder.build()
    }

    /** 结束通知：普通通知（非 ongoing），用户可划除。 */
    private fun postResultNotification(success: Boolean, text: String) {
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(if (success) "数据库导入完成" else "数据库导入失败")
            .setContentText(text)
            .setContentIntent(contentIntent())
            .setOngoing(false)
            .setAutoCancel(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(RESULT_NOTIFICATION_ID, notification)
    }

    private fun contentIntent(): PendingIntent? {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        } ?: return null
        return PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "数据库导入",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "数据库导入进度"
                    setShowBadge(false)
                }
                manager.createNotificationChannel(channel)
            }
        }
    }

    private fun acquireWakeLock() {
        try {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "fqapp:import"
            ).apply {
                setReferenceCounted(false)
                // 兜底超时：导入最长按 2 小时算，防异常情况下永久持锁。
                acquire(2 * 60 * 60 * 1000L)
            }
        } catch (_: Throwable) {
            wakeLock = null
        }
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Throwable) {
        }
        wakeLock = null
    }

    companion object {
        const val CHANNEL_ID = "database_import"
        const val NOTIFICATION_ID = 48
        const val RESULT_NOTIFICATION_ID = 49

        const val ACTION_UPDATE = "com.fanrenxiuxianguanyingchuan.IMPORT_UPDATE"
        const val ACTION_STOP = "com.fanrenxiuxianguanyingchuan.IMPORT_STOP"

        const val EXTRA_TEXT = "text"
        const val EXTRA_FRACTION = "fraction"
        const val EXTRA_SUCCESS = "success"

        @Volatile
        private var currentText: String = "正在导入数据库…"
    }
}
