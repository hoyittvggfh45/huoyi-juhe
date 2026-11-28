package com.fanrenxiuxianguanyingchuan

import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 导入前台服务桥（通道 fqapp/import_foreground）：Dart 侧
 * ImportJobService 在导入开始/进度/结束时调 start/update/
 * stop，本插件只负责把命令转成 ImportForegroundService 的
 * intent。全部方法立即回 success——服务起不来（容器限制等）
 * 也不能反噬导入本身，Dart 侧同样是 fail-soft 调用。
 */
class ImportForegroundPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "fqapp/import_foreground")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "start" -> {
                    val intent = Intent(context, ImportForegroundService::class.java).apply {
                        putExtra(
                            ImportForegroundService.EXTRA_TEXT,
                            call.argument<String>("text") ?: "正在导入数据库…"
                        )
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        ContextCompat.startForegroundService(context, intent)
                    } else {
                        context.startService(intent)
                    }
                }
                "update" -> {
                    val intent = Intent(context, ImportForegroundService::class.java).apply {
                        action = ImportForegroundService.ACTION_UPDATE
                        putExtra(
                            ImportForegroundService.EXTRA_TEXT,
                            call.argument<String>("text") ?: ""
                        )
                        putExtra(
                            ImportForegroundService.EXTRA_FRACTION,
                            call.argument<Double>("fraction") ?: -1.0
                        )
                    }
                    context.startService(intent)
                }
                "stop" -> {
                    val intent = Intent(context, ImportForegroundService::class.java).apply {
                        action = ImportForegroundService.ACTION_STOP
                        putExtra(
                            ImportForegroundService.EXTRA_SUCCESS,
                            call.argument<Boolean>("success") ?: false
                        )
                        putExtra(
                            ImportForegroundService.EXTRA_TEXT,
                            call.argument<String>("text") ?: ""
                        )
                    }
                    context.startService(intent)
                }
                else -> {
                    result.notImplemented()
                    return
                }
            }
        } catch (_: Throwable) {
            // fail-soft：前台服务承载失败不回错误给 Dart。
        }
        result.success(null)
    }
}
