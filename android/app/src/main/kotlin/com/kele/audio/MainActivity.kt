package com.kele.audio

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// 主 Activity。
///
/// 1. 继承 [AudioServiceActivity]（audio_service 要求）：后台播放 / 通知栏 /
///    锁屏控制由此获得前台服务绑定；
/// 2. 音频焦点原生通道（移植自 abts，MIT）：`kele/audio_focus`（方法）+
///    `kele/audio_focus_events`（事件），五个事件语义见
///    `lib/core/services/player/audio_focus.dart` 的文档。
class MainActivity : AudioServiceActivity() {

    private var audioManager: AudioManager? = null
    private var focusCallback: EventChannel.EventSink? = null
    private var focusRequest: AudioFocusRequest? = null

    /// 拔耳机 / 蓝牙断开：系统广播 AUDIO_BECOMING_NOISY，通知 Dart 侧暂停
    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                focusCallback?.success("noisy")
            }
        }
    }

    private val focusListener = AudioManager.OnAudioFocusChangeListener { focusChange ->
        when (focusChange) {
            AudioManager.AUDIOFOCUS_GAIN -> {
                // 打断结束：通知 Dart 侧续播
                focusCallback?.success("gained")
            }

            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                // 来电/导航等暂时打断：暂停并等待恢复
                focusCallback?.success("interrupted")
            }

            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                // 短暂提示音：仅降低音量，不中断播放
                focusCallback?.success("ducked")
            }

            AudioManager.AUDIOFOCUS_LOSS -> {
                // 被其他播放器永久抢占：暂停且不自动恢复
                focusCallback?.success("lost")
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

        // 注册「即将变噪音」广播（拔耳机/蓝牙断开）→ 自动暂停
        try {
            val noisyFilter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                // targetSdk 33+ 必须显式声明导出属性；系统受保护广播照常送达
                registerReceiver(noisyReceiver, noisyFilter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(noisyReceiver, noisyFilter)
            }
        } catch (e: Exception) {
            // 个别 ROM 限制隐式广播时忽略，不影响播放
        }

        // 音频焦点
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "kele/audio_focus",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "request" -> result.success(requestFocus())
                "abandon" -> {
                    abandonFocus()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "kele/audio_focus_events",
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                focusCallback = events
            }

            override fun onCancel(arguments: Any?) {
                focusCallback = null
            }
        })

        // 检查更新：APK 安装链路（提示词 2「Android 安装链路」）
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.kele.audio/update",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "canRequestInstall" -> result.success(canRequestInstall())
                "openInstallPermission" -> {
                    openInstallPermission()
                    result.success(null)
                }
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("INVALID_ARG", "missing path", null)
                        return@setMethodCallHandler
                    }
                    try {
                        installApk(path)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("INSTALL_FAILED", e.message ?: "", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun canRequestInstall(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else {
            true
        }
    }

    private fun openInstallPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                val intent = Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName"),
                )
                startActivity(intent)
            } catch (e: Exception) {
                // 个别 ROM 无此页，忽略
            }
        }
    }

    private fun installApk(path: String) {
        val file = File(path)
        if (!file.exists()) throw Exception("apk not found: $path")
        val uri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            file,
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(noisyReceiver)
        } catch (e: Exception) {
            // 未注册过则忽略
        }
        super.onDestroy()
    }

    private fun requestFocus(): Boolean {
        val am = audioManager ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build(),
                )
                .setOnAudioFocusChangeListener(focusListener)
                .setAcceptsDelayedFocusGain(true)
                .build()
            focusRequest = request
            val r = am.requestAudioFocus(request)
            r == AudioManager.AUDIOFOCUS_REQUEST_GRANTED || r == AudioManager.AUDIOFOCUS_REQUEST_DELAYED
        } else {
            val r = am.requestAudioFocus(
                focusListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN,
            )
            r == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
    }

    private fun abandonFocus() {
        val am = audioManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // 必须使用同一个 AudioFocusRequest 实例才能真正释放
            val request = focusRequest ?: return
            am.abandonAudioFocusRequest(request)
            focusRequest = null
        } else {
            am.abandonAudioFocus(focusListener)
        }
    }
}
