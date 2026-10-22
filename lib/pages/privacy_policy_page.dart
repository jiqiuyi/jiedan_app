import 'package:flutter/material.dart';
import '../l10n/l10n.dart';

import '../constants.dart';
import '../theme.dart';

/// 隐私政策页（独立页面，v1.15.0 扩写，v1.20.1 合规增强）。
/// 覆盖：信息收集 / 存储方式三选一 / 使用 / 权限使用说明 / 第三方共享与第三方服务 /
/// 安全 / 保留与删除 / 用户权利 / 未成年人 / 政策更新 / 联系我们（含反馈邮箱）。
class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(L10n.instance.t('settings_privacy'))),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _SectionTitle(L10n.instance.t('privacy_s1_title')),
          _Paragraph(L10n.instance.t('privacy_p1')),
          _Paragraph(L10n.instance.t('privacy_p2')),
          _Paragraph(L10n.instance.t('privacy_p3')),
          _Paragraph(L10n.instance.t('privacy_p4')),
          _SectionTitle(L10n.instance.t('privacy_s2_title')),
          _Paragraph(L10n.instance.t('privacy_p5')),
          _Paragraph(L10n.instance.t('privacy_p6')),
          _Paragraph(L10n.instance.t('privacy_p7')),
          _Paragraph(L10n.instance.t('privacy_p8')),
          _Paragraph(L10n.instance.t('privacy_p9')),
          _SectionTitle(L10n.instance.t('privacy_s3_title')),
          _Paragraph(L10n.instance.t('privacy_p10')),
          _SectionTitle(L10n.instance.t('privacy_s4_title')),
          _Paragraph(L10n.instance.t('privacy_p11')),
          _Paragraph(L10n.instance.t('privacy_p12')),
          _Paragraph(L10n.instance.t('privacy_p13')),
          _SectionTitle(L10n.instance.t('privacy_s5_title')),
          _Paragraph(L10n.instance.t('privacy_p14')),
          _Paragraph(L10n.instance.t('privacy_p15')),
          _Paragraph(L10n.instance.t('privacy_p16')),
          _SectionTitle(L10n.instance.t('privacy_s6_title')),
          _Paragraph(L10n.instance.t('privacy_p17')),
          _Paragraph(L10n.instance.t('privacy_p18')),
          _Paragraph(L10n.instance.t('privacy_p19')),
          _SectionTitle(L10n.instance.t('privacy_s7_title')),
          _Paragraph(L10n.instance.t('privacy_p20')),
          _Paragraph(L10n.instance.t('privacy_p21')),
          _Paragraph(L10n.instance.t('privacy_p22')),
          _SectionTitle(L10n.instance.t('privacy_s8_title')),
          _Paragraph(L10n.instance.t('privacy_p23')),
          _Paragraph(L10n.instance.t('privacy_p24')),
          _Paragraph(L10n.instance.t('privacy_p25')),
          _Paragraph(L10n.instance.t('privacy_p26')),
          _SectionTitle(L10n.instance.t('privacy_s9_title')),
          _Paragraph(L10n.instance.t('privacy_p27')),
          _SectionTitle(L10n.instance.t('privacy_s10_title')),
          _Paragraph(L10n.instance.t('privacy_p28')),
          _SectionTitle(L10n.instance.t('privacy_s11_title')),
          _Paragraph(L10n.instance.t('privacy_p29')),
          _Paragraph(L10n.instance.t('privacy_p30')),
          _Paragraph(L10n.instance.t('privacy_p31')),
          const SizedBox(height: 12),
          Text(
            L10n.instance.t('privacy_effective_note',
                args: {'v0': AppConfig.version}),
            style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Text(text,
          style: const TextStyle(
              fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textMain)),
    );
  }
}

class _Paragraph extends StatelessWidget {
  final String text;
  const _Paragraph(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text,
          style: const TextStyle(
              fontSize: 13.5, height: 1.6, color: AppTheme.textMain)),
    );
  }
}
