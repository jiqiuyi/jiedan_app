import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../constants.dart';
import '../database.dart';
import '../models.dart';
import '../services/avatar_service.dart';
import '../services/device_info_reporter.dart';
import '../services/update_service.dart';
import '../state/ticker.dart';
import '../theme.dart';
import 'admin_page.dart';
import 'data_management_page.dart';
import 'feedback_page.dart';
import 'income_stats_page.dart';
import 'invite_page.dart';
import 'login_page.dart';
import 'pay_notice_guide_page.dart';
import 'payment_code_settings_page.dart';
import 'paywall_page.dart';
import 'privacy_policy_page.dart';
import 'reconciliation_page.dart';
import 'storage_mode_page.dart';
import 'wallet_page.dart';

/// 「我的」页（v1.38.0 改版）。
///
/// 版式参考主流社交/内容类 App 的个人中心：顶部渐变个人卡片（头像可自定义）
/// + 数据概览四列 + 订阅/额度卡 + 常用功能宫格 + 设置列表，
/// 功能入口全部沿用接单管家原有能力，未新增任何外部依赖。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final NumberFormat _fmt = NumberFormat('#,##0.00');

  int _customerCount = 0;
  int _projectCount = 0;
  int _monthIncome = 0;
  int _balance = 0;
  StreamSubscription<int>? _tickerSub;

  @override
  void initState() {
    super.initState();
    AvatarService.instance.load();
    _loadStats();
    // 业务数据变化（收款 / 新建项目等）后自动刷新概览数字
    _tickerSub = Ticker.counterStream.listen((_) => _loadStats());
  }

  @override
  void dispose() {
    _tickerSub?.cancel();
    super.dispose();
  }

  Future<void> _loadStats() async {
    final db = AppDb.instance;
    final now = DateTime.now();
    final totals = await Future.wait<int>([
      db.monthPaidTotal(now.year, now.month),
      db.withdrawableBalance(),
    ]);
    final customers = await db.getCustomers();
    final projects = await db.getProjects();
    if (!mounted) return;
    setState(() {
      _monthIncome = totals[0];
      _balance = totals[1];
      _customerCount = customers.length;
      _projectCount = projects.length;
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _push(Widget page) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => page));
    _loadStats();
  }

  Future<void> _goLogin() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LoginPage()),
    );
    _loadStats();
  }

  /// 更换头像：相册选择 / 恢复默认
  Future<void> _editAvatar() async {
    final hasCustom = AvatarService.instance.path.value != null;
    final action = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 6),
              child: Text('更换头像',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            ListTile(
              leading:
                  const Icon(Icons.photo_library_outlined, color: AppTheme.primary),
              title: const Text('从相册选择'),
              subtitle: const Text('图片仅保存在本机，不会上传',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSub)),
              onTap: () => Navigator.pop(ctx, 'pick'),
            ),
            if (hasCustom)
              ListTile(
                leading: const Icon(Icons.restart_alt, color: AppTheme.textSub),
                title: const Text('恢复默认头像'),
                onTap: () => Navigator.pop(ctx, 'reset'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (action == 'pick') {
      try {
        final p = await AvatarService.instance.pickFromGallery();
        if (p != null) _toast('头像已更新');
      } catch (_) {
        _toast('选择头像失败，请重试');
      }
    } else if (action == 'reset') {
      await AvatarService.instance.clear();
      _toast('已恢复默认头像');
    }
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
      _loadStats();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: ListenableBuilder(
        listenable: Listenable.merge(
            [AppState.instance, AvatarService.instance.path]),
        builder: (context, _) {
          final st = AppState.instance;
          final user = st.currentUser;
          return RefreshIndicator(
            onRefresh: _loadStats,
            child: ListView(
              padding: EdgeInsets.zero,
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                _ProfileHeader(
                  user: user,
                  isPro: st.isPro,
                  monthIncome: _monthIncome,
                  customerCount: _customerCount,
                  projectCount: _projectCount,
                  balance: _balance,
                  fmt: _fmt,
                  onAvatarTap: _editAvatar,
                  onAccountTap: user == null ? _goLogin : null,
                  onCheckUpdate: () =>
                      UpdateService.instance.checkManual(context),
                ),
                _SubscriptionCard(
                  isPro: st.isPro,
                  subText: _subText(st, st.isPro),
                  customerCount: _customerCount,
                  projectCount: _projectCount,
                  onTap: () => _push(PaywallPage(
                    title: '解锁接单管家的全部能力',
                    desc: '从此不限客户数、不限项目数，专心接单不再被工具卡住。',
                  )),
                ),
                _FunctionGrid(
                  items: [
                    _FuncItem(Icons.account_balance_wallet_outlined,
                        AppTheme.primary, '钱包', () => _push(const WalletPage())),
                    _FuncItem(Icons.qr_code_2, AppTheme.accent, '收款设置',
                        () => _push(const PaymentCodeSettingsPage())),
                    _FuncItem(Icons.bar_chart, AppTheme.warn, '收入统计',
                        () => _push(const IncomeStatsPage())),
                    _FuncItem(Icons.rule_outlined, const Color(0xFF7C5CF0),
                        '对账汇总', () => _push(const ReconciliationPage())),
                    _FuncItem(Icons.card_giftcard, const Color(0xFFE8437A),
                        '推广活动', () => _push(const InvitePage())),
                    _FuncItem(Icons.manage_search_outlined, AppTheme.success,
                        '数据管理', () => _push(const DataManagementPage())),
                    _FuncItem(Icons.cloud_outlined, const Color(0xFF2F80ED),
                        '数据存储', () => _push(const StorageModePage())),
                    _FuncItem(Icons.feedback_outlined, AppTheme.textSub,
                        '意见反馈', () => _push(const FeedbackPage())),
                  ],
                ),
                _SettingsCard(
                  isPro: st.isPro,
                  isAdmin: st.isCurrentAdmin,
                  loggedIn: user != null,
                  onCheckUpdate: () =>
                      UpdateService.instance.checkManual(context),
                  onPrivacy: () => _push(const PrivacyPolicyPage()),
                  onAdmin: () => _push(const AdminPage()),
                  onPayNotice: () => _push(const PayNoticeGuidePage()),
                  onLogout: _confirmLogout,
                  onLogin: _goLogin,
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    '接单管家 v${AppConfig.version}',
                    style: const TextStyle(color: AppTheme.textSub, fontSize: 12),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
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

// ============================ 顶部个人卡片 ============================

class _ProfileHeader extends StatelessWidget {
  final UserAccount? user;
  final bool isPro;
  final int monthIncome;
  final int customerCount;
  final int projectCount;
  final int balance;
  final NumberFormat fmt;
  final VoidCallback onAvatarTap;
  final VoidCallback? onAccountTap;
  final VoidCallback onCheckUpdate;

  const _ProfileHeader({
    required this.user,
    required this.isPro,
    required this.monthIncome,
    required this.customerCount,
    required this.projectCount,
    required this.balance,
    required this.fmt,
    required this.onAvatarTap,
    required this.onAccountTap,
    required this.onCheckUpdate,
  });

  @override
  Widget build(BuildContext context) {
    final nickname = user == null
        ? '未登录'
        : (user!.nickname.isNotEmpty ? user!.nickname : '接单管家用户');
    final subtitle = user == null ? '登录后订阅状态云端长期有效' : user!.maskedPhone;
    final idText = user?.id == null ? 'ID: —' : 'ID: ${user!.id}';

    return Container(
      padding: EdgeInsets.fromLTRB(
          18, MediaQuery.of(context).padding.top + 10, 10, 20),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF4A5AF0), Color(0xFF7C5CF0)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(22)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Text('我的',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700)),
              const Spacer(),
              IconButton(
                onPressed: onCheckUpdate,
                tooltip: '检查更新',
                icon: const Icon(Icons.system_update_alt,
                    color: Colors.white, size: 22),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              _AvatarView(
                path: AvatarService.instance.path.value,
                fallback: user == null
                    ? ''
                    : (user!.nickname.isNotEmpty
                        ? user!.nickname
                        : user!.maskedPhone),
                onEdit: onAvatarTap,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: GestureDetector(
                  onTap: onAccountTap,
                  behavior: HitTestBehavior.opaque,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              nickname,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 19,
                                  fontWeight: FontWeight.w700),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _LevelBadge(isPro: isPro),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(subtitle,
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.82),
                              fontSize: 12)),
                      const SizedBox(height: 3),
                      Text(idText,
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.62),
                              fontSize: 11)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              _MetricTile(
                  value: '¥${fmt.format(monthIncome / 100)}', label: '本月收入'),
              const _MetricDivider(),
              _MetricTile(value: '$customerCount', label: '客户'),
              const _MetricDivider(),
              _MetricTile(value: '$projectCount', label: '项目'),
              const _MetricDivider(),
              _MetricTile(value: '¥${fmt.format(balance / 100)}', label: '钱包余额'),
            ],
          ),
        ],
      ),
    );
  }
}

class _AvatarView extends StatelessWidget {
  final String? path;
  final String fallback;
  final VoidCallback onEdit;

  const _AvatarView({
    required this.path,
    required this.fallback,
    required this.onEdit,
  });

  static const double _size = 66;

  @override
  Widget build(BuildContext context) {
    final file = (path == null || path!.isEmpty) ? null : File(path!);
    final hasImage = file != null && file.existsSync();

    return GestureDetector(
      onTap: onEdit,
      child: SizedBox(
        width: _size + 10,
        height: _size + 10,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.9),
                  shape: BoxShape.circle,
                ),
                child: hasImage
                    ? ClipOval(
                        child: Image.file(file,
                            width: _size, height: _size, fit: BoxFit.cover))
                    : Container(
                        width: _size,
                        height: _size,
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(
                          color: Color(0xFF6C7BF5),
                          shape: BoxShape.circle,
                        ),
                        child: fallback.isEmpty
                            ? const Icon(Icons.person_outline,
                                color: Colors.white, size: 32)
                            : Text(
                                fallback.characters.first,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 26,
                                    fontWeight: FontWeight.w700),
                              ),
                      ),
              ),
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 4,
                    ),
                  ],
                ),
                child: const Icon(Icons.edit, size: 13, color: AppTheme.primary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LevelBadge extends StatelessWidget {
  final bool isPro;
  const _LevelBadge({required this.isPro});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(isPro ? Icons.verified : Icons.lock_outline,
              size: 12, color: Colors.white),
          const SizedBox(width: 3),
          Text(
            isPro ? '专业版' : '免费版',
            style: const TextStyle(
                color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  final String value;
  final String label;
  const _MetricTile({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 4),
          Text(label,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.75), fontSize: 11)),
        ],
      ),
    );
  }
}

class _MetricDivider extends StatelessWidget {
  const _MetricDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 26,
      color: Colors.white.withValues(alpha: 0.25),
    );
  }
}

// ============================ 订阅 / 额度卡 ============================

class _SubscriptionCard extends StatelessWidget {
  final bool isPro;
  final String subText;
  final int customerCount;
  final int projectCount;
  final VoidCallback onTap;

  const _SubscriptionCard({
    required this.isPro,
    required this.subText,
    required this.customerCount,
    required this.projectCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ratio = isPro
        ? 1.0
        : (customerCount / AppConfig.freeCustomerLimit).clamp(0.0, 1.0);
    final overLimit = !isPro && customerCount >= AppConfig.freeCustomerLimit;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                children: [
                  Icon(isPro ? Icons.verified : Icons.lock_outline,
                      color: isPro ? AppTheme.accent : AppTheme.warn, size: 26),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isPro ? '专业版 · 已解锁全部功能' : '免费版',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: isPro ? AppTheme.accent : AppTheme.textMain,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(subText,
                            style: const TextStyle(
                                color: AppTheme.textSub, fontSize: 12)),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      isPro ? '续费' : '升级',
                      style: const TextStyle(
                          color: AppTheme.primary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: ratio,
                  minHeight: 6,
                  backgroundColor: AppTheme.bgCard,
                  valueColor: AlwaysStoppedAnimation<Color>(
                      overLimit ? AppTheme.warn : AppTheme.primary),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(
                    isPro
                        ? '订阅权益已全部生效'
                        : '客户额度 $customerCount/${AppConfig.freeCustomerLimit} · 项目额度 $projectCount/${AppConfig.freeProjectLimit}',
                    style: const TextStyle(
                        color: AppTheme.textSub, fontSize: 11),
                  ),
                  const Spacer(),
                  const Icon(Icons.chevron_right,
                      size: 16, color: AppTheme.textSub),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================ 常用功能宫格 ============================

class _FuncItem {
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;
  const _FuncItem(this.icon, this.color, this.label, this.onTap);
}

class _FunctionGrid extends StatelessWidget {
  final List<_FuncItem> items;
  const _FunctionGrid({required this.items});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 16, 8, 6),
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Text('常用功能',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textMain)),
                ],
              ),
            ),
            const SizedBox(height: 10),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: items.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: 14,
                crossAxisSpacing: 4,
                childAspectRatio: 0.88,
              ),
              itemBuilder: (context, i) {
                final it = items[i];
                return InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: it.onTap,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: it.color.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(it.icon, size: 22, color: it.color),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        it.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.textMain),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ============================ 设置列表 ============================

class _SettingsCard extends StatelessWidget {
  final bool isPro;
  final bool isAdmin;
  final bool loggedIn;
  final VoidCallback onCheckUpdate;
  final VoidCallback onPrivacy;
  final VoidCallback onAdmin;
  final VoidCallback onPayNotice;
  final VoidCallback onLogout;
  final VoidCallback onLogin;

  const _SettingsCard({
    required this.isPro,
    required this.isAdmin,
    required this.loggedIn,
    required this.onCheckUpdate,
    required this.onPrivacy,
    required this.onAdmin,
    required this.onPayNotice,
    required this.onLogout,
    required this.onLogin,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.system_update, color: AppTheme.primary),
            title: const Text('检查更新'),
            subtitle: const Text('点击检查是否有新版本',
                style: TextStyle(fontSize: 12, color: AppTheme.textSub)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('v${AppConfig.version.split('+').first}',
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSub)),
                const Icon(Icons.chevron_right, color: AppTheme.textSub),
              ],
            ),
            onTap: onCheckUpdate,
          ),
          const _CardDivider(),
          const _FeedbackReportSwitch(),
          const _CardDivider(),
          ListTile(
            leading:
                const Icon(Icons.privacy_tip_outlined, color: AppTheme.primary),
            title: const Text('隐私政策'),
            subtitle: const Text('数据存储说明 · 数据存放方式与隐私保护',
                style: TextStyle(fontSize: 12, color: AppTheme.textSub)),
            trailing:
                const Icon(Icons.chevron_right, color: AppTheme.textSub),
            onTap: onPrivacy,
          ),
          if (isAdmin) ...[
            const _CardDivider(),
            ListTile(
              leading: const Icon(Icons.admin_panel_settings,
                  color: AppTheme.primary),
              title: const Text('后台管理'),
              subtitle: const Text('待确认 / 抽查 / 返现 / 收款配置',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSub)),
              trailing:
                  const Icon(Icons.chevron_right, color: AppTheme.textSub),
              onTap: onAdmin,
            ),
            const _CardDivider(),
            ListTile(
              leading: const Icon(Icons.notifications_active_outlined,
                  color: AppTheme.primary),
              title: const Text('到账监听状态'),
              subtitle: const Text('仅运维：查看本机通知监听是否生效',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSub)),
              trailing:
                  const Icon(Icons.chevron_right, color: AppTheme.textSub),
              onTap: onPayNotice,
            ),
          ],
          const _CardDivider(),
          if (loggedIn)
            ListTile(
              leading: const Icon(Icons.logout, color: AppTheme.danger),
              title: const Text('退出登录',
                  style: TextStyle(
                      color: AppTheme.danger, fontWeight: FontWeight.w600)),
              onTap: onLogout,
            )
          else
            ListTile(
              leading: const Icon(Icons.login, color: AppTheme.primary),
              title: const Text('登录账号',
                  style: TextStyle(
                      color: AppTheme.primary, fontWeight: FontWeight.w600)),
              subtitle: const Text('登录后可保存订阅状态、支持多设备同步',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSub)),
              onTap: onLogin,
            ),
        ],
      ),
    );
  }
}

class _CardDivider extends StatelessWidget {
  const _CardDivider();

  @override
  Widget build(BuildContext context) {
    return const Divider(height: 1, indent: 16, endIndent: 16);
  }
}

/// 反馈信息上报开关（v1.26.0）：默认开启；关闭后提交反馈不再附带设备信息，
/// 仅影响本次提交的可选载荷，不影响反馈功能本身。
class _FeedbackReportSwitch extends StatefulWidget {
  const _FeedbackReportSwitch();

  @override
  State<_FeedbackReportSwitch> createState() => _FeedbackReportSwitchState();
}

class _FeedbackReportSwitchState extends State<_FeedbackReportSwitch> {
  bool _enabled = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v = await DeviceInfoReporter.instance.reportingEnabled();
    if (!mounted) return;
    setState(() => _enabled = v);
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: const Icon(Icons.devices_outlined, color: AppTheme.primary),
      title: const Text('反馈信息上报'),
      subtitle: const Text(
          '提交反馈时附带设备型号/系统版本/App版本（仅用于排查问题，不采集隐私数据，可随时关闭）'),
      value: _enabled,
      onChanged: (v) async {
        setState(() => _enabled = v);
        await DeviceInfoReporter.instance.setReportingEnabled(v);
      },
    );
  }
}
