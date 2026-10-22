import 'dart:async';
import '../l10n/l10n.dart';
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
import 'error_log_page.dart';
import '../theme.dart';
import 'admin_page.dart';
import 'data_management_page.dart';
import 'feedback_page.dart';
import 'income_stats_page.dart';
import 'invite_page.dart';
import 'ledger_page.dart';
import 'login_page.dart';
import 'pay_notice_guide_page.dart';
import 'payment_code_settings_page.dart';
import 'paywall_page.dart';
import 'privacy_policy_page.dart';
import 'reconciliation_page.dart';
import 'storage_mode_page.dart';
import 'tag_management_page.dart';
import 'wallet_page.dart';
import '../widgets/app_ui.dart';

/// 「我的」页（v1.38.0 改版）。
///
/// 版式参考主流社交/内容类 App 的个人中心：顶部渐变个人卡片（头像可自定义）
/// + 数据概览四列 + 订阅/额度卡 + 常用功能宫格 + 设置列表，
/// 功能入口全部沿用接单管家原有能力，未新增任何外部依赖。
class SettingsPage extends StatefulWidget {
const   SettingsPage({super.key});

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
    final monthIncome = await db.monthPaidTotal(now.year, now.month);
    // 钱包只累计推广返利佣金：余额 = 服务端待打款返现（云端权威）
    final stats = await AppState.instance.inviteStats();
    final customers = await db.getCustomers();
    final projects = await db.getProjects();
    if (!mounted) return;
    setState(() {
      _monthIncome = monthIncome;
      _balance = stats.pendingRebate;
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
      MaterialPageRoute(builder: (_) => LoginPage()),
    );
    _loadStats();
  }

  /// 更换头像：相册选择 / 恢复默认
  Future<void> _editAvatar() async {
    final hasCustom = AvatarService.instance.path.value != null;
    final action = await showAppSheet<String>(
      context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 6),
              child: AppSheetHeader(title: L10n.instance.t('settings_avatar_change')),
            ),
            ListTile(
              leading:
                  Icon(Icons.photo_library_outlined, color: AppTheme.primary),
              title: Text(L10n.instance.t('settings_avatar_pick')),
              subtitle: Text(L10n.instance.t('settings_avatar_pick_sub'),
                  style: TextStyle(fontSize: 12, color: AppTheme.textSub)),
              onTap: () => Navigator.pop(ctx, 'pick'),
            ),
            if (hasCustom)
              ListTile(
                leading: Icon(Icons.restart_alt, color: AppTheme.textSub),
                title: Text(L10n.instance.t('settings_avatar_reset')),
                onTap: () => Navigator.pop(ctx, 'reset'),
              ),
            SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (action == 'pick') {
      try {
        final p = await AvatarService.instance.pickFromGallery();
        if (p != null) _toast(L10n.instance.t('settings_avatar_updated'));
      } catch (_) {
        _toast(L10n.instance.t('settings_avatar_failed'));
      }
    } else if (action == 'reset') {
      await AvatarService.instance.clear();
      _toast(L10n.instance.t('settings_avatar_reset_done'));
    }
  }

  Future<void> _confirmLogout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.instance.t('common_logout')),
        content: Text(L10n.instance.t('settings_logout_confirm')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(L10n.instance.t('common_cancel'))),
          AppButton(
            label: L10n.instance.t('settings_logout_btn'),
            kind: AppButtonKind.danger,
            size: AppButtonSize.medium,
            expand: false,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (ok == true) {
      await AppState.instance.logout();
      _loadStats();
    }
  }

  /// 语言切换：三选一底部弹窗（跟随系统 / 中文 / English）
  Future<void> _pickLanguage() async {
    final current = L10n.instance.pref;
    final choice = await showModalBottomSheet<LangPref>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
              child: AppSheetHeader(
                  title: L10n.instance.t('settings_language')),
            ),
            ListTile(
              leading: Icon(Icons.settings_suggest_outlined,
                  color: current == LangPref.system
                      ? AppTheme.primary
                      : AppTheme.textSub),
              title: Text(L10n.instance.t('settings_lang_system')),
              trailing: current == LangPref.system
                  ? const Icon(Icons.check, color: AppTheme.primary)
                  : null,
              onTap: () => Navigator.pop(ctx, LangPref.system),
            ),
            ListTile(
              leading: Icon(Icons.translate,
                  color: current == LangPref.zh
                      ? AppTheme.primary
                      : AppTheme.textSub),
              title: Text(L10n.instance.t('settings_lang_zh')),
              trailing: current == LangPref.zh
                  ? const Icon(Icons.check, color: AppTheme.primary)
                  : null,
              onTap: () => Navigator.pop(ctx, LangPref.zh),
            ),
            ListTile(
              leading: Icon(Icons.language,
                  color: current == LangPref.en
                      ? AppTheme.primary
                      : AppTheme.textSub),
              title: Text(L10n.instance.t('settings_lang_en')),
              trailing: current == LangPref.en
                  ? const Icon(Icons.check, color: AppTheme.primary)
                  : null,
              onTap: () => Navigator.pop(ctx, LangPref.en),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice != null && choice != current) {
      await L10n.instance.setPref(choice);
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
              physics: AlwaysScrollableScrollPhysics(),
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
                    title: L10n.instance.t('settings_upgrade_paywall_title'),
                    desc: L10n.instance.t('settings_upgrade_paywall_desc'),
                  )),
                ),
                _FunctionGrid(
                  items: [
                    _FuncItem(Icons.receipt_long_outlined, AppTheme.accent, L10n.instance.t('settings_page_ledger'),
                        () => _push(const LedgerPage())),
                    _FuncItem(Icons.account_balance_wallet_outlined,
                        AppTheme.primary, L10n.instance.t('settings_func_wallet'), () => _push(const WalletPage())),
                    _FuncItem(Icons.qr_code_2, AppTheme.accent, L10n.instance.t('settings_page_payment_codes'),
                        () => _push(const PaymentCodeSettingsPage())),
                    _FuncItem(Icons.bar_chart, AppTheme.warn, L10n.instance.t('settings_func_income'),
                        () => _push(const IncomeStatsPage())),
                    _FuncItem(Icons.rule_outlined, Color(0xFF7C5CF0),
                        L10n.instance.t('reconciliation_page_reconciliation'), () => _push(const ReconciliationPage())),
                    _FuncItem(Icons.card_giftcard, Color(0xFFE8437A),
                        L10n.instance.t('invite_title'), () => _push(const InvitePage())),
                    _FuncItem(Icons.manage_search_outlined, AppTheme.success,
                        L10n.instance.t('data_management_title'), () => _push(const DataManagementPage())),
                    _FuncItem(Icons.cloud_outlined, Color(0xFF2F80ED),
                        L10n.instance.t('settings_func_storage'), () => _push(const StorageModePage())),
                    _FuncItem(Icons.label_outline, Color(0xFF00A67E),
                        L10n.instance.t('tags_title'), () => _push(const TagManagementPage())),
                    _FuncItem(Icons.feedback_outlined, AppTheme.textSub,
                        L10n.instance.t('settings_func_feedback'), () => _push(const FeedbackPage())),
                  ],
                ),
                _SettingsCard(
                  isPro: st.isPro,
                  isAdmin: st.isCurrentAdmin,
                  loggedIn: user != null,
                  onCheckUpdate: () =>
                      UpdateService.instance.checkManual(context),
                  onLanguage: _pickLanguage,
                  onPrivacy: () => _push(PrivacyPolicyPage()),
                  onAdmin: () => _push(AdminPage()),
                  onPayNotice: () => _push(PayNoticeGuidePage()),
                  onLogout: _confirmLogout,
                ),
                SizedBox(height: 8),
                Card(
                  margin: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  child: ListTile(
                    leading: Icon(Icons.bug_report_outlined),
                    title: Text(L10n.instance.t('settings_error_log')),
                    subtitle: Text(L10n.instance.t('settings_error_log_sub')),
                    trailing: const Icon(Icons.chevron_right, size: 20),
                    onTap: () => _push(const ErrorLogPage()),
                  ),
                ),
                Center(
                  child: Column(
                    children: [
                      Text(
                        L10n.instance.t('i18n_361', args: {'v0': AppConfig.version}),
                        style: const TextStyle(
                            color: AppTheme.textSub, fontSize: 12),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        AppConfig.icpCode,
                        style: const TextStyle(
                            color: AppTheme.textSub, fontSize: 12),
                      ),
                    ],
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
        return L10n.instance.t('settings_subscription_until', args: {'v0':date.year.toString(), 'v1':date.month.toString().padLeft(2, '0'), 'v2':date.day.toString().padLeft(2, '0')});
      }
      return L10n.instance.t('settings_sub_thanks');
    }
    if (st.currentUser == null) {
      return L10n.instance.t('settings_sub_login_tip');
    }
    return L10n.instance.t('i18n_123', args: {'v0':'${AppConfig.freeCustomerLimit}', 'v1':'${AppConfig.freeProjectLimit}'});
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
const 
  _ProfileHeader({
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
        ? L10n.instance.t('common_not_logged_in')
        : (user!.nickname.isNotEmpty ? user!.nickname : L10n.instance.t('settings_default_nickname'));
    final subtitle = user == null ? L10n.instance.t('settings_login_sub') : user!.maskedPhone;
    final idText = user?.id == null ? 'ID: —' : 'ID: ${user!.id}';

    return Container(
      padding: EdgeInsets.fromLTRB(
          18, MediaQuery.of(context).padding.top + 10, 10, 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF4A5AF0), Color(0xFF7C5CF0)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(AppRadius.sheet)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(L10n.instance.t('settings_title'),
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700)),
              Spacer(),
              IconButton(
                onPressed: onCheckUpdate,
                tooltip: L10n.instance.t('settings_check_update'),
                icon: const Icon(Icons.system_update_alt,
                    color: Colors.white, size: 22),
              ),
            ],
          ),
          SizedBox(height: 2),
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
              SizedBox(width: 14),
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
          SizedBox(height: 18),
          Row(
            children: [
              _MetricTile(
                  value: '¥${fmt.format(monthIncome / 100)}', label: L10n.instance.t('dashboard_month_income')),
              _MetricDivider(),
              _MetricTile(value: '$customerCount', label: L10n.instance.t('common_customer')),
              _MetricDivider(),
              _MetricTile(value: '$projectCount', label: L10n.instance.t('common_project')),
              _MetricDivider(),
              _MetricTile(value: '¥${fmt.format(balance / 100)}', label: L10n.instance.t('settings_rebate_balance')),
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
        borderRadius: BorderRadius.circular(AppRadius.sheet),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(isPro ? Icons.verified : Icons.lock_outline,
              size: 12, color: Colors.white),
          SizedBox(width: 3),
          Text(
            isPro ? L10n.instance.t('common_pro') : L10n.instance.t('settings_free'),
            style: TextStyle(
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
          SizedBox(height: 4),
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
const 
  _SubscriptionCard({
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
        borderRadius: BorderRadius.circular(AppRadius.lg),
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
                          isPro ? L10n.instance.t('settings_pro_unlocked') : L10n.instance.t('settings_free'),
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
                      borderRadius: BorderRadius.circular(AppRadius.sheet),
                    ),
                    child: Text(
                      isPro ? L10n.instance.t('settings_renew') : L10n.instance.t('settings_upgrade'),
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
                borderRadius: BorderRadius.circular(AppRadius.xxs),
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
                        ? L10n.instance.t('settings_sub_active')
                        : L10n.instance.t('i18n_230', args: {'v0':'$customerCount', 'v1':'${AppConfig.freeCustomerLimit}', 'v2':'$projectCount', 'v3':'${AppConfig.freeProjectLimit}'}),
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
  _FuncItem(this.icon, this.color, this.label, this.onTap);
}

class _FunctionGrid extends StatelessWidget {
  final List<_FuncItem> items;
const _FunctionGrid({required this.items});

  @override
  Widget build(BuildContext context) {
    // 响应式列数：宽屏（平板等宽度 >= 600）时 9 个入口合并为一行；
    // 窄屏（手机竖屏）保持 4 列三行。
    final double screenWidth = MediaQuery.sizeOf(context).width;
    final int columns = screenWidth >= 600 ? 9 : 4;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 16, 8, 6),
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Text(L10n.instance.t('settings_common_func'),
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textMain)),
                ],
              ),
            ),
            SizedBox(height: 10),
            GridView.builder(
              shrinkWrap: true,
              // 显式清零 padding：否则 ScrollView 会隐式套用 MediaQuery 的系统栏内边距，
              // 在本页（无 SafeArea 包裹）表现为标题与宫格之间多出一大段空白。
              padding: EdgeInsets.zero,
              primary: false,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: items.length,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisSpacing: 14,
                crossAxisSpacing: 4,
                childAspectRatio: 0.88,
              ),
              itemBuilder: (context, i) {
                final it = items[i];
                return InkWell(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  onTap: it.onTap,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: it.color.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(AppRadius.md),
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
  final VoidCallback onLanguage;
  final VoidCallback onPrivacy;
  final VoidCallback onAdmin;
  final VoidCallback onPayNotice;
  final VoidCallback onLogout;
const 
  _SettingsCard({
    required this.isPro,
    required this.isAdmin,
    required this.loggedIn,
    required this.onCheckUpdate,
    required this.onLanguage,
    required this.onPrivacy,
    required this.onAdmin,
    required this.onPayNotice,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: Icon(Icons.system_update, color: AppTheme.primary),
            title: Text(L10n.instance.t('settings_check_update')),
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
          _CardDivider(),
          ListTile(
            leading: Icon(Icons.language, color: AppTheme.primary),
            title: Text(L10n.instance.t('settings_language')),
            subtitle: Text(L10n.instance.t('settings_language_sub'),
                style: TextStyle(fontSize: 12, color: AppTheme.textSub)),
            trailing:
                const Icon(Icons.chevron_right, color: AppTheme.textSub),
            onTap: onLanguage,
          ),
          _CardDivider(),
          _FeedbackReportSwitch(),
          _CardDivider(),
          ListTile(
            leading:
                Icon(Icons.privacy_tip_outlined, color: AppTheme.primary),
            title: Text(L10n.instance.t('settings_privacy')),
            trailing:
                const Icon(Icons.chevron_right, color: AppTheme.textSub),
            onTap: onPrivacy,
          ),
          if (isAdmin) ...[
            const _CardDivider(),
            ListTile(
              leading: const Icon(Icons.admin_panel_settings,
                  color: AppTheme.primary),
              title: Text(L10n.instance.t('settings_admin')),
              subtitle: Text(L10n.instance.t('settings_admin_sub'),
                  style: TextStyle(fontSize: 12, color: AppTheme.textSub)),
              trailing:
                  const Icon(Icons.chevron_right, color: AppTheme.textSub),
              onTap: onAdmin,
            ),
            const _CardDivider(),
            ListTile(
              leading: const Icon(Icons.notifications_active_outlined,
                  color: AppTheme.primary),
              title: Text(L10n.instance.t('settings_paynotice_status')),
              subtitle: Text(L10n.instance.t('settings_paynotice_status_sub'),
                  style: TextStyle(fontSize: 12, color: AppTheme.textSub)),
              trailing:
                  const Icon(Icons.chevron_right, color: AppTheme.textSub),
              onTap: onPayNotice,
            ),
          ],
          if (loggedIn) ...[
            const _CardDivider(),
            ListTile(
              leading: const Icon(Icons.logout, color: AppTheme.danger),
              title: Text(L10n.instance.t('common_logout'),
                  style: TextStyle(
                      color: AppTheme.danger, fontWeight: FontWeight.w600)),
              onTap: onLogout,
            ),
          ],
        ],
      ),
    );
  }
}

class _CardDivider extends StatelessWidget {
const _CardDivider();

  @override
  Widget build(BuildContext context) {
    return const AppCardDivider();
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
      title: Text(L10n.instance.t('settings_feedback_report')),
      value: _enabled,
      onChanged: (v) async {
        setState(() => _enabled = v);
        await DeviceInfoReporter.instance.setReportingEnabled(v);
      },
    );
  }
}
