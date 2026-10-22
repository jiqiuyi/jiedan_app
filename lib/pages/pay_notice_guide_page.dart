import 'package:flutter/material.dart';
import '../l10n/l10n.dart';

import '../services/pay_notice_reporter.dart';
import '../theme.dart';

/// 付款到账自动核对引导页（普通用户可见的温和入口）。
/// 不暴露任何底层技术术语（通知监听 / 自动识别等一律隐藏），
/// 仅在用户主动进入时提示一次开启，未开启不影响付款确认流程。
class PayNoticeGuidePage extends StatefulWidget {
const   PayNoticeGuidePage({super.key});

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
    await Future.delayed(Duration(milliseconds: 600));
    if (!mounted) return;
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _enabled ?? false;
    return Scaffold(
      appBar: AppBar(title: Text(L10n.instance.t('paynotice_guide_title'))),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          SizedBox(height: 8),
          Center(
            child: Icon(
              enabled ? Icons.check_circle : Icons.notifications_none,
              size: 56,
              color: enabled ? const Color(0xFF07C160) : AppTheme.primary,
            ),
          ),
          SizedBox(height: 12),
          Center(
            child: Text(
              enabled ? L10n.instance.t('i18n_267') : L10n.instance.t('i18n_300'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
          SizedBox(height: 8),
          Text(
            L10n.instance.t('i18n_303') +
            L10n.instance.t('i18n_426') +
            L10n.instance.t('i18n_479') +
            L10n.instance.t('i18n_137') +
            L10n.instance.t('i18n_210') +
            L10n.instance.t('i18n_168'),
            style: TextStyle(height: 1.7, color: AppTheme.textSub, fontSize: 14),
          ),
          SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _openSetting,
            icon: Icon(Icons.settings),
            label: Text(enabled ? L10n.instance.t('paynotice_guide_settings') : L10n.instance.t('paynotice_guide_enable')),
          ),
          if (_enabled == null) ...[
            SizedBox(height: 12),
            Center(
              child: Text(L10n.instance.t('paynotice_guide_checking'),
                  style: TextStyle(fontSize: 12, color: AppTheme.textSub)),
            ),
          ],
        ],
      ),
    );
  }
}
