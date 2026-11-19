package com.kele.audio

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
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

    companion object {
        /// 媒体播放通知渠道（IMPORTANCE_LOW + 无声）：后台/锁屏控制条不「叮」。
        /// 必须与 main.dart 的 androidNotificationChannelId 一致。
        private const val MEDIA_CHANNEL_ID = "com.kele.audio.channel.audio2"

        /// 下载完成通知渠道（IMPORTANCE_DEFAULT + 默认提示音）：低频、用户主动触发。
        private const val DOWNLOAD_CHANNEL_ID = "com.kele.audio.channel.download"
    }

    private var audioManager: AudioManager? = null
    private var focusCallback: EventChannel.EventSink? = null
    private var focusRequest: AudioFocusRequest? = null

    /// 通知权限弹窗期间挂起的 MethodChannel 回复：requestPermissions 是异步的，
    /// 必须等用户在系统弹窗上做出选择后再回传结果，否则总是误报「未授权」。
    private var pendingNotificationResult: MethodChannel.Result? = null

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

        // 预建通知渠道：importance/sound 创建后不可改，必须先于 audio_service
        // 用同 id 创建。媒体渠道静默，下载渠道带声。
        ensureNotificationChannels()

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

        // M9.3：Android 13+ 通知运行时权限（后台/锁屏听书通知依赖）
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.kele.audio/notifications",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(hasNotificationPermission())
                "request" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                        !hasNotificationPermission()
                    ) {
                        // requestPermissions 是异步的：先把回复挂起，等用户在系统
                        // 弹窗上选择后由 onRequestPermissionsResult 回传真实结果。
                        pendingNotificationResult = result
                        ActivityCompat.requestPermissions(
                            this,
                            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                            101,
                        )
                    } else {
                        result.success(hasNotificationPermission())
                    }
                }
                "openSettings" -> {
                    openNotificationSettings()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

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

        // 网络类型（M8 离线缓存「仅 Wi-Fi 下载」门控；已有 ACCESS_NETWORK_STATE 权限）
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.kele.audio/network",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "type" -> result.success(currentNetworkType())
                else -> result.notImplemented()
            }
        }

        // 一次性下载完成通知（离线缓存 / 更新包）：带声渠道，低频提醒
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.kele.audio/notifier",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "showDownloadComplete" -> {
                    val title = call.argument<String>("title") ?: "下载完成"
                    val body = call.argument<String>("body") ?: ""
                    val ok = showDownloadComplete(title, body)
                    result.success(ok)
                }
                else -> result.notImplemented()
            }
        }
    }

    /// 预建两个通知渠道。渠道的 importance / sound 一经创建不可更改，必须在
    /// audio_service 用媒体渠道 id 创建前先建好：这样它会复用本渠道的静默配置，
    /// 播放/缓冲时反复重建通知也不再发声。
    private fun ensureNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return

        // 媒体播放：低重要性、无声、不振动——后台/锁屏控制条常驻但不打扰。
        val media = NotificationChannel(
            MEDIA_CHANNEL_ID,
            "播放有声内容",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "后台/锁屏播放控制（静默）"
            setSound(null, null)
            enableVibration(false)
            setShowBadge(false)
        }
        manager.createNotificationChannel(media)

        // 下载完成：默认重要性、系统提示音——用户主动发起、低频，理应提醒。
        val download = NotificationChannel(
            DOWNLOAD_CHANNEL_ID,
            "下载完成",
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = "离线缓存 / 更新包下载完成提醒"
            enableVibration(true)
        }
        manager.createNotificationChannel(download)
    }

    /// 在带声渠道上发一条一次性下载完成通知。返回是否成功发出。
    private fun showDownloadComplete(title: String, body: String): Boolean {
        if (!hasNotificationPermission()) return false
        return try {
            val manager = getSystemService(NotificationManager::class.java) ?: return false
            val intent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            val pending = PendingIntent.getActivity(this, 0, intent, flags)
            val notification = Notification.Builder(this, DOWNLOAD_CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentTitle(title)
                .setContentText(body)
                .setContentIntent(pending)
                .setAutoCancel(true)
                .setOnlyAlertOnce(true)
                .build()
            manager.notify(1001, notification)
            true
        } catch (e: Exception) {
            false
        }
    }

    /// 当前网络类型：wifi / ethernet / mobile / none / unknown。
    private fun currentNetworkType(): String {
        return try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return "none"
            when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "mobile"
                else -> "unknown"
            }
        } catch (e: Exception) {
            "unknown"
        }
    }

    private fun hasNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
    }

    /// 通知权限弹窗结果：回传挂起的 MethodChannel 回复。
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 101) return
        val pending = pendingNotificationResult
        pendingNotificationResult = null
        pending?.success(
            grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED,
        )
    }

    /// 打开本应用的通知设置页；个别 ROM 无此页时退回应用详情页。
    private fun openNotificationSettings() {
        try {
            val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        } catch (e: Exception) {
            try {
                startActivity(
                    Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:$packageName"),
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
            } catch (ignored: Exception) {
                // 无可用设置页时静默忽略
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
