import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/services.dart';

/// 备份传输期间的保活锁（仅 Android）。
///
/// 屏幕关闭后系统会对 WiFi 启用省电策略、并压制 CPU 与定时器，批量的 SMB
/// 会话可能因此长时间停顿甚至被断开。这里通过原生侧持有
/// `PARTIAL_WAKE_LOCK` + `WifiLock`，削掉「一息屏就断链」这个主因。
///
/// 边界说明：保活锁只能降低断连概率，**不能保证永不中断**——路由器/NAS 侧
/// 同样可能主动断开。断线后的重连与续传由 transfer_provider 的恢复逻辑负责。
///
/// 释放路径：Dart 侧由备份批次的 `finally` 释放；原生侧在 Activity
/// `onDestroy` 兜底释放，避免锁泄漏。
class KeepAliveService {
  KeepAliveService._();

  static const MethodChannel _channel = MethodChannel('mipix/keepalive');

  /// 持有者计数：真源是「还有几个备份批次在跑」。
  ///
  /// 不能用单个布尔值——分批 / 多服务器 / 用户连点「全部备份」都会让批次重叠，
  /// 先结束的那批会把原生锁释放掉，仍在跑的那批就变成无锁上传（真机已实测到
  /// 这种「锁只在开头持有 9 秒、之后 2.5 分钟上传全裸奔」的现象）。
  static int _holders = 0;

  static bool get isHeld => _holders > 0;

  /// 仅测试用：`flutter test` 跑在桌面端，`Platform.isAndroid` 恒为 false，
  /// 置为 true 才能让单测走到 MethodChannel 分支。
  @visibleForTesting
  static bool debugForcePlatform = false;

  static bool get _isAndroid => debugForcePlatform || Platform.isAndroid;

  /// 申请保活锁；拿不到锁不应让备份整体失败，因此吞掉异常。
  static Future<void> acquire() async {
    _holders += 1;
    if (_holders > 1) return; // 已有批次持有，无需重复申请。

    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('acquire');
    } catch (e) {
      debugPrint('[keepalive] acquire 失败：$e');
      _holders -= 1;
    }
  }

  /// 释放保活锁；仍被其它批次使用时只减计数，不真正释放。
  static Future<void> release() async {
    if (_holders == 0) return;
    _holders -= 1;
    if (_holders > 0) return;

    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('release');
    } catch (e) {
      debugPrint('[keepalive] release 失败：$e');
    }
  }
}
