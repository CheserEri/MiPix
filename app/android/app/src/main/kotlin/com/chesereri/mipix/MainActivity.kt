package com.chesereri.mipix

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
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

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

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
