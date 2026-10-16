import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';

import '../database.dart';

/// 记账桌面小组件数据桥（v1.46.1）：
/// Flutter 侧在记账数据变更后把「本月支出/收入 + 最近 3 条」写入
/// home_widget 的 SharedPreferences 缓存并广播刷新小组件；
/// 同时负责向原生侧轮询「记一笔」拉起意图（QUICK_LEDGER）。
class LedgerWidgetBridge {
  LedgerWidgetBridge._();

  /// 原生侧写入 HomeWidgetPreferences 的键名（与 LedgerWidgetProvider.kt 一致）。
  static const String dataKey = 'ledger_widget_data';

  /// 与 MainActivity.kt 约定的意图 action。
  static const String actionQuickLedger = 'com.jiedan.guanjia.QUICK_LEDGER';

  /// 与 MainActivity.kt 约定的原生通道：查询「记一笔」拉起意图。
  static const MethodChannel _channel = MethodChannel('com.jiedan.guanjia/widget');

  /// 记账增删改成功后调用：重新汇总并刷新小组件。
  /// 失败静默（小组件保留上次数据），不阻塞记账主流程。
  static Future<void> refresh() async {
    try {
      final entries = await AppDb.instance.getLedgerEntries();
      final now = DateTime.now();
      final monthStart =
          DateTime(now.year, now.month, 1).millisecondsSinceEpoch;
      final monthEnd =
          DateTime(now.year, now.month + 1, 1).millisecondsSinceEpoch;
      var expenseFen = 0;
      var incomeFen = 0;
      final recent = <Map<String, Object>>[];
      for (final e in entries) {
        if (e.entryDate >= monthStart && e.entryDate < monthEnd) {
          if (e.kind == 0) {
            expenseFen += e.amount;
          } else {
            incomeFen += e.amount;
          }
        }
        if (recent.length < 3) {
          recent.add({
            'category': e.category,
            'amount': e.amount,
            'kind': e.kind,
          });
        }
      }
      final json = jsonEncode({
        'month_expense': expenseFen,
        'month_income': incomeFen,
        'recent': recent,
        'ts': now.millisecondsSinceEpoch,
      });
      await HomeWidget.saveWidgetData(dataKey, json);
      await HomeWidget.updateWidget(androidName: 'LedgerWidgetProvider');
    } catch (_) {
      // 静默：小组件数据刷新失败不影响记账主流程
    }
  }

  /// 消费原生侧缓存的「记一笔」拉起意图（冷启动/恢复时轮询）。
  /// 返回 true 表示用户从小组件点了「记一笔」，应由调用方弹出极速记账面板。
  static Future<bool> consumeQuickLedger() async {
    try {
      final v = await _channel.invokeMethod<bool>('consumeQuickLedger');
      return v ?? false;
    } catch (_) {
      return false;
    }
  }
}
