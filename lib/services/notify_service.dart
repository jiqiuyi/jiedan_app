import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

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
}
