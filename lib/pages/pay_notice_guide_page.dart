import 'package:flutter/material.dart';

import '../services/pay_notice_reporter.dart';
import '../theme.dart';

/// 付款到账自动核对引导页（普通用户可见的温和入口）。
/// 不暴露任何底层技术术语（通知监听 / 自动识别等一律隐藏），
/// 仅在用户主动进入时提示一次开启，未开启不影响付款确认流程。
class PayNoticeGuidePage extends StatefulWidget {
  const PayNoticeGuidePage({super.key});

  @override
  State<PayNoticeGuidePage> createState() => _PayNoticeGuidePageState();
}

class _PayNoticeGuidePageState extends State<PayNoticeGuidePage> {
  bool? _enabled; // null=未知

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final enabled = await PayNoticeReporter.instance.listenerEnabled();
    if (!mounted) return;
    setState(() => _enabled = enabled);
    // 已授权时尝试拉取一次暂存并上报
    if (enabled) {
      PayNoticeReporter.instance.uploadPending();
    }
  }

  Future<void> _openSetting() async {
    await PayNoticeReporter.instance.openListenerSettings();
    // 从系统页返回后刷新状态
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _enabled ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('付款到账核对')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 8),
          Center(
            child: Icon(
              enabled ? Icons.check_circle : Icons.notifications_none,
              size: 56,
              color: enabled ? const Color(0xFF07C160) : AppTheme.primary,
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              enabled ? '已开启到账核对' : '开启到账自动核对',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '开启后，当您向收款码完成付款，系统可以在后台自动识别到账信息，'
            '更快地为您核实并开通专业版，无需每次等待人工确认。\n\n'
            '此功能仅用于核对收款到账，不会读取任何聊天内容、也不会访问'
            '其他应用的数据，您的隐私始终受保护。\n\n'
            '如果暂不开启也没关系：付款后点击「我已完成付款」，管理员核实后'
            '同样会为您开通。',
            style: TextStyle(height: 1.7, color: AppTheme.textSub, fontSize: 14),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _openSetting,
            icon: const Icon(Icons.settings),
            label: Text(enabled ? '前往系统设置查看' : '立即开启'),
          ),
          if (_enabled == null) ...[
            const SizedBox(height: 12),
            const Center(
              child: Text('正在检测当前状态…',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSub)),
            ),
          ],
        ],
      ),
    );
  }
}
