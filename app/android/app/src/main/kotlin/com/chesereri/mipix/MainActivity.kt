package com.chesereri.mipix

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 备份传输期间的保活锁宿主。
 *
 * 屏幕关闭后系统会对 WiFi 启用省电策略并压制 CPU/定时器，批量的 SMB 会话
 * 可能因此长时间停顿甚至被断开。Dart 侧进入备份批次时申请、批次结束时释放：
 *  - PARTIAL_WAKE_LOCK：保持 CPU 与 Dart 定时器不被压制；
 *  - WifiLock：抑制息屏时的 WiFi 省电。
 *
 * Android 14 起 WIFI_MODE_FULL_HIGH_PERF 已废弃并被映射为 low-latency 模式，
 * 因此 API 29+ 直接使用 FULL_LOW_LATENCY，低版本才回退到 FULL_HIGH_PERF。
 * 该锁只降低断连概率，不保证永不中断。
 *
 * onDestroy 兜底释放，避免 Activity 销毁时锁泄漏。
 */
class MainActivity : FlutterActivity() {
    private val channelName = "mipix/keepalive"
    private val permissionChannelName = "mipix/permission"

    /// 位置信息权限申请的回调标识（任意不冲突的值即可）。
    private val mediaLocationRequestCode = 0x4D50

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var pendingMediaLocationResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> {
                        acquireKeepAlive()
                        result.success(null)
                    }
                    "release" -> {
                        releaseKeepAlive()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, permissionChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "ensureMediaLocation" -> ensureMediaLocation(result)
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 申请 `ACCESS_MEDIA_LOCATION` 并返回是否已持有。
     *
     * Android 10 起，应用缺少该权限时，MediaProvider 的 FUSE 层会在读取照片时
     * 把 EXIF 中的位置信息（GPS）数值区间替换为 0——文件长度与其余字节完全不变，
     * 因此「同名同大小」的去重和本地哈希校验都发现不了，备份端会静默丢 GPS。
     * 要忠实备份位置信息，必须在读文件前就持有该权限。
     */
    private fun ensureMediaLocation(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
            ContextCompat.checkSelfPermission(
                this, Manifest.permission.ACCESS_MEDIA_LOCATION
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        // 极端情况下前一次请求还没回调：先把旧的那次收敛为失败，避免结果悬空。
        pendingMediaLocationResult?.success(false)
        pendingMediaLocationResult = result
        requestPermissions(
            arrayOf(Manifest.permission.ACCESS_MEDIA_LOCATION), mediaLocationRequestCode
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        if (requestCode == mediaLocationRequestCode) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingMediaLocationResult?.success(granted)
            pendingMediaLocationResult = null
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    private fun acquireKeepAlive() {
        if (wakeLock == null) {
            val power = applicationContext.getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "mipix:backup").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        if (wifiLock == null) {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            } else {
                WifiManager.WIFI_MODE_FULL_HIGH_PERF
            }
            wifiLock = wifi.createWifiLock(mode, "mipix:backup").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    private fun releaseKeepAlive() {
        wakeLock?.let {
            runCatching { if (it.isHeld) it.release() }
            wakeLock = null
        }
        wifiLock?.let {
            runCatching { if (it.isHeld) it.release() }
            wifiLock = null
        }
    }

    override fun onDestroy() {
        releaseKeepAlive()
        super.onDestroy()
    }
}
