import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import '../database.dart';
import '../constants.dart';

/// 本地催款提醒通知服务（v9 新增）。
/// 业务数据仅存本机，通知同样完全本地化，不上传任何信息。
class NotifyService {
  NotifyService._();
  static final NotifyService instance = NotifyService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _inited = false;

  /// 应用启动时初始化（main 调用）。
  Future<void> init() async {
    if (_inited) return;
    // 初始化时区数据库（用于精确时间调度）
    tz.initializeTimeZones();
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();
    const settings =
        InitializationSettings(android: androidInit, iOS: iosInit);
    await _plugin.initialize(settings);
    _inited = true;
    // 请求通知权限（Android 13+ 运行时权限）
    await _requestPermission();
  }

  Future<void> _requestPermission() async {
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    await _plugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  }

  static const int _idBase = 10000;

  /// 立即展示一条提醒（用于兜底 / 手动触发）。
  Future<void> showReminder({
    required String title,
    required String body,
  }) async {
    await _plugin.show(
      _idBase + DateTime.now().millisecondsSinceEpoch % 1000,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'collection_remind',
          '收款提醒',
          channelDescription: '项目待收金额到期提醒',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
    );
  }

  /// 为指定项目安排到期提醒（scheduleAt 指定时间触发）。
  /// projectId 用于生成稳定通知 id，重复调度会覆盖旧提醒。
  Future<void> scheduleProjectReminder({
    required int projectId,
    required String projectName,
    required String amountYuan,
    required DateTime when,
  }) async {
    final now = DateTime.now();
    // 过期时间不调度（直接忽略），避免无意义通知
    if (!when.isAfter(now)) return;
    await _plugin.zonedSchedule(
      _idBase + projectId,
      '待收款提醒',
      '$projectName 还有 $amountYuan 元待收款，记得跟进~',
      tz.TZDateTime.from(when, tz.local),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'collection_remind',
          '收款提醒',
          channelDescription: '项目待收金额到期提醒',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  /// 取消某项目的提醒（清除已调度的通知）。
  Future<void> cancelProjectReminder(int projectId) async {
    await _plugin.cancel(_idBase + projectId);
  }

  /// 应用启动巡检本地待办提醒（v1.24.0 消息本地提醒）：
  /// 1) 回款到期：收款计划（pending_collections）未收且到期日已到/逾期 → 立即提醒一次；
  /// 2) 报价待确认：报价状态为「已发送」且发出超过 72 小时仍未确认 → 提醒一次。
  /// 全部基于本地 SQLite 数据触发，不依赖服务器；已提醒的条目写入 settings 去重，
  /// 同一收款/报价只提醒一次，避免每天重复打扰。
  Future<void> checkLocalReminders() async {
    if (!_inited) return;
    final db = AppDb.instance;
    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    final todayStart =
        DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    // 1) 回款到期（未收 & 到期日 <= 今天）
    try {
      final pcs = await db.getPendingCollections(onlyPending: true);
      for (final pc in pcs) {
        if (pc.dueDate <= 0 || pc.dueDate > nowMs) continue;
        final key = 'remind_pc_due_${pc.id}';
        if (await db.getSetting(key) != null) continue;
        final overdueDays =
            ((todayStart - pc.dueDate) / (24 * 3600 * 1000)).floor();
        await showReminder(
          title: '回款到期提醒',
          body:
              '「${pc.title}」应收 ¥${(pc.amount / 100).toStringAsFixed(2)} 已${overdueDays <= 0 ? '今日到期' : '逾期 $overdueDays 天'}，请及时收款。',
        );
        await db.setSetting(key, nowMs.toString());
      }
    } catch (_) {
      // 巡检失败不阻断启动
    }
    // 2) 报价待确认（已发送超 72h 未确认）
    try {
      final quotes = await db.getQuotes();
      for (final q in quotes) {
        if (q.status != QuoteStatus.sent || q.updatedAt <= 0) continue;
        final elapsed = nowMs - q.updatedAt;
        if (elapsed < 72 * 3600 * 1000) continue;
        final key = 'remind_quote_sent_${q.id}';
        if (await db.getSetting(key) != null) continue;
        await showReminder(
          title: '报价待客户确认',
          body: '「${q.title}」报价已发出超 72 小时仍未确认，记得跟进客户。',
        );
        await db.setSetting(key, nowMs.toString());
      }
    } catch (_) {
      // 巡检失败不阻断启动
    }
  }
}
