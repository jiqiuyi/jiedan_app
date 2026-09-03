import 'package:flutter/material.dart';

import '../app_state.dart';
import '../constants.dart';
import '../services/sync_service.dart';
import '../theme.dart';
import 'login_page.dart';
import 'paywall_page.dart';
import 'feedback_page.dart';
import 'invite_page.dart';
import 'admin_page.dart';
import 'pay_notice_guide_page.dart';
import 'payment_code_settings_page.dart';
import 'data_management_page.dart';
import 'storage_mode_page.dart';
import 'wallet_page.dart';
import 'privacy_policy_page.dart';
import 'income_stats_page.dart';
import 'reconciliation_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Future<void> _goLogin() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LoginPage()),
    );
  }

  Future<void> _confirmLogout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('退出后本地数据仍会保留，下次登录同一账号即可继续使用。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await AppState.instance.logout();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListenableBuilder(
        listenable: AppState.instance,
        builder: (context, _) {
          final st = AppState.instance;
          final user = st.currentUser;
          final isPro = st.isPro;
          return ListView(
            padding: const EdgeInsets.only(top: 8, bottom: 32),
            children: [
              // ---- 账户与订阅 ----
              const _SectionHeader(title: '账户与订阅'),
              // ---- 账号卡片 ----
              Card(
                child: user == null
                    ? ListTile(
                        leading: const CircleAvatar(
                          backgroundColor: Color(0xFFE8EAFB),
                          child: Icon(Icons.person_outline,
                              color: AppTheme.primary),
                        ),
                        title: const Text('未登录',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: const Text('登录后可保存订阅状态'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _goLogin,
                      )
                    : ListTile(
                        leading: CircleAvatar(
                          backgroundColor:
                              AppTheme.primary.withValues(alpha: 0.12),
                          foregroundColor: AppTheme.primary,
                          child: Text(
                            (user.nickname.isNotEmpty
                                    ? user.nickname
                                    : user.maskedPhone)
                                .characters
                                .first,
                            style:
                                const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        title: Text(
                          user.nickname.isNotEmpty
                              ? user.nickname
                              : '接单管家用户',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          '${user.maskedPhone} · 本地账号',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: IconButton(
                          icon:
                              const Icon(Icons.logout, color: AppTheme.textSub),
                          tooltip: '退出登录',
                          onPressed: _confirmLogout,
                        ),
                      ),
              ),
              // ---- 订阅状态 + 升级 ----
              Card(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Icon(isPro ? Icons.verified : Icons.lock_outline,
                              color: isPro ? AppTheme.accent : AppTheme.warn,
                              size: 32),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  isPro ? '专业版 · 已解锁全部功能' : '免费版',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: isPro
                                        ? AppTheme.accent
                                        : AppTheme.textMain,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _subText(st, isPro),
                                  style: const TextStyle(
                                      color: AppTheme.textSub, fontSize: 13),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      leading: const Icon(Icons.workspace_premium_outlined,
                          color: AppTheme.primary),
                      title: const Text('升级专业版'),
                      subtitle: const Text('无限客户 / 无限项目 / 全部功能'),
                      trailing: const Icon(Icons.chevron_right,
                          color: AppTheme.textSub),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => PaywallPage(
                            title: '解锁接单管家的全部能力',
                            desc: '从此不限客户数、不限项目数，专心接单不再被工具卡住。',
                          ),
                        ),
                      ),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      leading: const Icon(Icons.card_giftcard,
                          color: AppTheme.primary),
                      title: const Text('推广活动'),
                      subtitle: const Text('推荐好友送 VIP，新人付款返现 50%'),
                      trailing: const Icon(Icons.chevron_right,
                          color: AppTheme.textSub),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const InvitePage()),
                      ),
                    ),
                  ],
                ),
              ),
              // ---- 资金 ----
              const _SectionHeader(title: '资金'),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.account_balance_wallet_outlined,
                          color: AppTheme.primary),
                      title: const Text('钱包'),
                      subtitle: const Text('收款余额、提现到账'),
                      trailing: const Icon(Icons.chevron_right,
                          color: AppTheme.textSub),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const WalletPage()),
                      ),
                    ),
                    const Divider(height: 1, indent: 56, endIndent: 16),
                    ListTile(
                      leading: const Icon(Icons.qr_code_2,
                          color: AppTheme.primary),
                      title: const Text('收款设置'),
                      subtitle: const Text('配置微信 / 支付宝收款码，收款时一键出示'),
                      trailing: const Icon(Icons.chevron_right,
                          color: AppTheme.textSub),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const PaymentCodeSettingsPage()),
                      ),
                    ),
                  ],
                ),
              ),
              // ---- 管理员（仅 role=admin 可见） ----
              if (st.isCurrentAdmin) ...[
                const _SectionHeader(title: '管理'),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.admin_panel_settings,
                            color: AppTheme.primary),
                        title: const Text('后台管理'),
                        subtitle: const Text('待确认 / 抽查 / 返现 / 收款配置'),
                        trailing: const Icon(Icons.chevron_right,
                            color: AppTheme.textSub),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const AdminPage()),
                        ),
                      ),
                      const Divider(height: 1, indent: 56, endIndent: 16),
                      ListTile(
                        leading: const Icon(Icons.notifications_active_outlined,
                            color: AppTheme.primary),
                        title: const Text('到账监听状态'),
                        subtitle: const Text('仅运维：查看本机通知监听是否生效'),
                        trailing: const Icon(Icons.chevron_right,
                            color: AppTheme.textSub),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const PayNoticeGuidePage()),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              // ---- 经营分析 ----
              const _SectionHeader(title: '经营分析'),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.bar_chart,
                          color: AppTheme.primary),
                      title: const Text('收入统计'),
                      subtitle: const Text('近 12 个月收入曲线、客户贡献排行'),
                      trailing: const Icon(Icons.chevron_right,
                          color: AppTheme.textSub),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const IncomeStatsPage()),
                      ),
                    ),
                    const Divider(height: 1, indent: 56, endIndent: 16),
                    ListTile(
                      leading: const Icon(Icons.rule_outlined,
                          color: AppTheme.primary),
                      title: const Text('对账汇总'),
                      subtitle: const Text('每项目约定 / 已收 / 待收一览'),
                      trailing: const Icon(Icons.chevron_right,
                          color: AppTheme.textSub),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const ReconciliationPage()),
                      ),
                    ),
                  ],
                ),
              ),
              // ---- 数据与存储 ----
              const _SectionHeader(title: '数据与存储'),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.cloud_outlined,
                          color: AppTheme.primary),
                      title: const Text('数据存储方式'),
                      subtitle: Text(
                        '${SyncService.instance.mode.label} · '
                        '${SyncService.instance.mode.summary}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right,
                          color: AppTheme.textSub),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const StorageModePage()),
                      ),
                    ),
                    const Divider(height: 1, indent: 56, endIndent: 16),
                    ListTile(
                      leading: const Icon(Icons.manage_search_outlined,
                          color: AppTheme.primary),
                      title: const Text('数据管理'),
                      subtitle: const Text('导出备份 / 导入恢复，可配合云端同步使用'),
                      trailing: const Icon(Icons.chevron_right,
                          color: AppTheme.textSub),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const DataManagementPage()),
                      ),
                    ),
                  ],
                ),
              ),
              // ---- 服务与支持 ----
              const _SectionHeader(title: '服务与支持'),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.feedback_outlined,
                          color: AppTheme.primary),
                      title: const Text('意见反馈'),
                      subtitle: const Text('在线提交 Bug 或更新建议，实时收到'),
                      trailing: const Icon(Icons.chevron_right,
                          color: AppTheme.textSub),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const FeedbackPage()),
                      ),
                    ),
                    const Divider(height: 1, indent: 56, endIndent: 16),
                    ListTile(
                      leading: const Icon(Icons.privacy_tip_outlined,
                          color: AppTheme.primary),
                      title: const Text('隐私政策'),
                      subtitle: const Text('数据存储说明 · 数据存放方式与隐私保护'),
                      trailing: const Icon(Icons.chevron_right,
                          color: AppTheme.textSub),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const PrivacyPolicyPage()),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Center(
                child: Text(
                  '接单管家 v${AppConfig.version}',
                  style: TextStyle(color: AppTheme.textSub, fontSize: 12),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  String _subText(AppState st, bool isPro) {
    if (isPro) {
      final expire = st.currentUser?.proExpireAt;
      if (st.currentUser != null && expire != null) {
        final date = DateTime.fromMillisecondsSinceEpoch(expire);
        return '订阅有效期至 ${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      }
      return '感谢支持，欢迎持续使用';
    }
    if (st.currentUser == null) {
      return '登录后购买订阅，账号内长期有效';
    }
    return '免费版可管理 ${AppConfig.freeCustomerLimit} 个客户、${AppConfig.freeProjectLimit} 个进行中项目';
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: AppTheme.textSub,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
