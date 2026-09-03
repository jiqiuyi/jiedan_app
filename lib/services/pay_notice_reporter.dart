import 'dart:convert';

import 'package:flutter/services.dart';

import '../api_client.dart';
import '../database.dart';

/// 收款到账自动核对桥：连接 Android 原生解析到的到账记录（金额 + 时间），
/// 带上登录态上报后端匹配订单。
///
/// 设计说明：
/// - 原生侧只负责「读取系统公开推送的到账通知 → 解析金额与时间 → 暂存队列」；
/// - 本类负责「拉取暂存 → 携带 token 上报 → 失败重试」，上报动作始终由网络层完成，
///   避免在原生侧存放任何账号凭据；
/// - 全部调用静默容错：原生组件不可用 / 未授权时不影响任何既有功能，
///   付款确认与后台抽查依然能兜住开通闭环。
class PayNoticeReporter {
  PayNoticeReporter._();
  static final PayNoticeReporter instance = PayNoticeReporter._();

  static const MethodChannel _channel =
      MethodChannel('com.jiedan.guanjia/paylistener');

  static const String _retryKey = 'pay_report_retry';

  /// 原生到账解析组件是否已开启（系统侧授权）。未开启时返回 false，不抛错。
  Future<bool> listenerEnabled() async {
    try {
      final r = await _channel.invokeMethod<bool>('listenerEnabled');
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 引导用户到系统设置开启（一次性，不循环弹窗）。
  Future<void> openListenerSettings() async {
    try {
      await _channel.invokeMethod('openListenerSettings');
    } catch (_) {}
  }

  /// 拉取原生暂存的到账记录并上报；上报失败进入本地重试队列，下次再传。
  /// 返回本次成功上报条数。
  Future<int> uploadPending() async {
    final t = ApiClient.instance.token;
    if (t == null) return 0; // 未登录不触发上报

    final List<dynamic> reports = [];
    try {
      reports.addAll(await _channel.invokeListMethod<dynamic>(
              'flushPendingReports') ??
          const []);
    } catch (_) {
      // 原生侧不可用时忽略，不影响主流程
    }
    if (reports.isEmpty) return 0;

    var success = 0;
    for (final r in reports) {
      final amount = (r is Map && r['amount'] is num)
          ? (r['amount'] as num).toDouble()
          : 0.0;
      final ts = (r is Map && r['ts'] is num) ? (r['ts'] as num).toInt() : 0;
      final source = (r is Map && r['source'] is String)
          ? r['source'] as String
          : 'manual';
      if (amount <= 0) continue;
      try {
        await ApiClient.instance.reportListener(
          amount: amount,
          ts: ts,
          source: source,
          deviceId: await _deviceId(),
        );
        success++;
      } catch (_) {
        // 网络抖动：进入本地重试队列，下次再上报，不丢数据
        await _pushRetry(
            {'amount': amount, 'ts': ts, 'source': source});
      }
    }
    return success;
  }

  /// 重试此前失败的上报记录。
  Future<void> retryPending() async {
    final t = ApiClient.instance.token;
    if (t == null) return;
    final raw = await AppDb.instance
        .getSetting(_retryKey);
    if (raw == null || raw.isEmpty) return;
    final List<dynamic> list;
    try {
      list = jsonDecode(raw) as List<dynamic>;
    } catch (_) {
      await AppDb.instance.setSetting(_retryKey, '');
      return;
    }
    final rest = <Map<String, dynamic>>[];
    for (final r in list) {
      if (r is! Map) continue;
      try {
        await ApiClient.instance.reportListener(
          amount: (r['amount'] as num).toDouble(),
          ts: (r['ts'] as num).toInt(),
          source: (r['source'] ?? 'manual').toString(),
          deviceId: await _deviceId(),
        );
      } catch (_) {
        rest.add(Map<String, dynamic>.from(r));
      }
    }
    await AppDb.instance
        .setSetting(_retryKey, jsonEncode(rest));
  }

  Future<void> _pushRetry(Map<String, dynamic> item) async {
    final raw = await AppDb.instance.getSetting(_retryKey);
    List<dynamic> list = [];
    if (raw != null && raw.isNotEmpty) {
      try {
        list = jsonDecode(raw) as List<dynamic>;
      } catch (_) {
        list = [];
      }
    }
    list.add(item);
    if (list.length > 200) list.removeAt(0);
    await AppDb.instance.setSetting(_retryKey, jsonEncode(list));
  }

  /// 本机设备标识（风控用，匿名稳定 ID）。首次生成后持久化，不采集任何隐私字段。
  Future<String> _deviceId() async {
    var id = await AppDb.instance.getSetting('device_id');
    if (id == null || id.isEmpty) {
      final now = DateTime.now().millisecondsSinceEpoch;
      id = 'jd_${now}_${_rand()}';
      await AppDb.instance.setSetting('device_id', id);
    }
    return id;
  }

  String _rand() {
    final r = DateTime.now().microsecondsSinceEpoch.toString();
    return r.substring(r.length - 6);
  }
}
