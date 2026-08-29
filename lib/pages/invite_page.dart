import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../constants.dart';
import '../database.dart';
import '../models.dart';
import '../theme.dart';
import 'login_page.dart';

/// 推广活动页（本地 MVP 版）
///
/// 规则：
/// - 每推荐 2 位真实好友 → 免费送 VIP 1 个月
/// - 拉来的新人真实付款开通 VIP → 返现 50%，上不封顶
class InvitePage extends StatefulWidget {
  const InvitePage({super.key});

  @override
  State<InvitePage> createState() => _InvitePageState();
}

class _InvitePageState extends State<InvitePage> {
  final _fmt = NumberFormat('#,##0.00');
  String _inviteCode = '';
  List<Invitee> _list = [];
  InviteStats _stats = const InviteStats(
      friendCount: 0, paidCount: 0, totalRebate: 0);
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final st = AppState.instance;
    // 检查是否触发"推荐送 VIP"
    final granted = await st.grantInviteVipIfEligible();
    final code = await st.myInviteCode();
    final stats = await st.inviteStats();
    final uid = st.currentUser?.id;
    final list =
        uid == null ? <Invitee>[] : await AppDb.instance.getInvitees(uid);
    if (!mounted) return;
    setState(() {
      _inviteCode = code;
      _stats = stats;
      _list = list;
      _loading = false;
    });
    if (granted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              '恭喜！已推荐 ${AppConfig.inviteFreeVipFriends} 位好友，免费获赠 VIP ${AppConfig.inviteRewardMonths.toStringAsFixed(0)} 个月'),
        ),
      );
    }
  }

  Future<void> _addInvitee() async {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('推荐了好友'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '好友昵称/称呼 *',
                hintText: '如：老张',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: phoneCtrl,
              keyboardType: TextInputType.phone,
              maxLength: 11,
              decoration: const InputDecoration(
                labelText: '好友手机号（选填）',
                counterText: '',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () {
              if (nameCtrl.text.trim().isEmpty) return;
              Navigator.pop(ctx, true);
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await AppState.instance.addInvitee(
          nameCtrl.text.trim(), phoneCtrl.text.trim());
      await _load();
    }
  }

  Future<void> _markPaid(Invitee e) async {
    // 选择付款方案（月付 / 年付 / 两年 / 永久）
    final plans = <({String label, double amount})>[
      (
        label:
            '月付 ¥${AppConfig.monthlyPrice.toStringAsFixed(0)} · 返现 ¥${(AppConfig.monthlyPrice * AppConfig.rebateRate).toStringAsFixed(2)}',
        amount: AppConfig.monthlyPrice,
      ),
      (
        label:
            '年付 ¥${AppConfig.yearlyPrice.toStringAsFixed(0)} · 返现 ¥${(AppConfig.yearlyPrice * AppConfig.rebateRate).toStringAsFixed(2)}',
        amount: AppConfig.yearlyPrice,
      ),
      (
        label:
            '两年 ¥${AppConfig.twoYearPrice.toStringAsFixed(0)} · 返现 ¥${(AppConfig.twoYearPrice * AppConfig.rebateRate).toStringAsFixed(2)}',
        amount: AppConfig.twoYearPrice,
      ),
      (
        label:
            '永久 ¥${AppConfig.foreverPrice.toStringAsFixed(0)} · 返现 ¥${(AppConfig.foreverPrice * AppConfig.rebateRate).toStringAsFixed(2)}',
        amount: AppConfig.foreverPrice,
      ),
    ];
    final planIndex = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('${e.name} 真实付款开通 VIP'),
        children: [
          for (var i = 0; i < plans.length; i++)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, i),
              child: Text(plans[i].label),
            ),
        ],
      ),
    );
    if (planIndex == null) return;
    final amount = plans[planIndex].amount;
    await AppState.instance.markInviteePaid(e.id!, amount);
    await _load();
  }

  Future<void> _remove(Invitee e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条推荐记录'),
        content: const Text('删除后该好友不再计入推荐进度。确定吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await AppState.instance.removeInvitee(e.id!);
      await _load();
    }
  }

  Future<void> _copyCode() async {
    await Clipboard.setData(ClipboardData(text: _inviteCode));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('邀请码已复制')));
  }

  @override
  Widget build(BuildContext context) {
    final st = AppState.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('推广活动')),
      body: ListenableBuilder(
        listenable: AppState.instance,
        builder: (context, _) {
          if (!st.loggedIn) {
            return _NotLoggedIn(onLogin: () async {
              final ok = await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const LoginPage()),
              );
              if (ok == true) await _load();
            });
          }
          if (_loading) {
            return const Center(child: CircularProgressIndicator());
          }
          final need = AppConfig.inviteFreeVipFriends;
          final progress = (_list.length / need).clamp(0.0, 1.0);
          return ListView(
            padding: const EdgeInsets.only(top: 8, bottom: 32),
            children: [
              // ---- 我的邀请码卡片 ----
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      const Text('我的邀请码',
                          style: TextStyle(
                              fontSize: 13, color: AppTheme.textSub)),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            _inviteCode,
                            style: const TextStyle(
                              fontSize: 32,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 3,
                              color: AppTheme.primary,
                            ),
                          ),
                          const SizedBox(width: 12),
                          IconButton(
                            onPressed: _copyCode,
                            icon: const Icon(Icons.copy_rounded,
                                size: 20, color: AppTheme.textSub),
                            tooltip: '复制邀请码',
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        '把邀请码发给朋友，朋友注册时填入即可完成邀请。',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: AppTheme.textSub),
                      ),
                    ],
                  ),
                ),
              ),
              // ---- 进度卡片 ----
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: _Stat(
                                label: '已推荐',
                                value: '${_list.length}',
                                unit: '人'),
                          ),
                          Expanded(
                            child: _Stat(
                                label: '已付款',
                                value: '${_stats.paidCount}',
                                unit: '人'),
                          ),
                          Expanded(
                            child: _Stat(
                                label: '累计返现',
                                value: _fmt.format(_stats.totalRebate),
                                unit: '元'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '推荐 ${_list.length}/$need 位好友，即可免费获得 VIP '
                        '${AppConfig.inviteRewardMonths.toStringAsFixed(0)} 个月'
                        '${_stats.bonusGranted ? '（已领取）' : ''}',
                        style: const TextStyle(
                            fontSize: 13, color: AppTheme.textSub),
                      ),
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 8,
                          backgroundColor:
                              AppTheme.primary.withValues(alpha: 0.12),
                          color: AppTheme.accent,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // ---- 添加好友 ----
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: FilledButton.icon(
                  onPressed: _addInvitee,
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const Text('推荐了好友'),
                ),
              ),
              // ---- 好友列表 ----
              if (_list.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(28),
                  child: Center(
                    child: Text('还没有推荐记录\n点击上方按钮登记推荐的好友',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppTheme.textSub)),
                  ),
                )
              else
                ..._list.map((e) => _InviteeTile(
                      e: e,
                      onMarkPaid: () => _markPaid(e),
                      onDelete: () => _remove(e),
                    )),
              const SizedBox(height: 12),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '活动规则（本地版说明）：\n'
                  '1. 每推荐 2 位真实好友，免费赠送 VIP 1 个月；\n'
                  '2. 好友真实付款开通 VIP，您获得其付款金额 50% 的返现，上不封顶；\n'
                  '3. 当前为 MVP 本地版，好友与付款需手动登记，接入云端后将自动核验。',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSub),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  const _Stat({required this.label, required this.value, required this.unit});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
              fontSize: 20, fontWeight: FontWeight.w800, color: AppTheme.textMain),
        ),
        Text('$label（$unit）',
            style: const TextStyle(fontSize: 12, color: AppTheme.textSub)),
      ],
    );
  }
}

class _InviteeTile extends StatelessWidget {
  final Invitee e;
  final VoidCallback onMarkPaid;
  final VoidCallback onDelete;
  const _InviteeTile(
      {required this.e, required this.onMarkPaid, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat('#,##0.00');
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: AppTheme.primary.withValues(alpha: 0.1),
          foregroundColor: AppTheme.primary,
          child: Text(
            e.name.characters.first,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        title: Text(e.name,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(e.paid
            ? '已付款 ¥${fmt.format(e.payAmount)} · 返现 ¥${fmt.format(e.rebate)}'
            : (e.phone.isNotEmpty ? e.phone : '待付款')),
        trailing: e.paid
            ? IconButton(
                icon: const Icon(Icons.delete_outline,
                    size: 20, color: AppTheme.textSub),
                onPressed: onDelete,
              )
            : TextButton(
                onPressed: onMarkPaid,
                child: const Text('标记付款'),
              ),
      ),
    );
  }
}

class _NotLoggedIn extends StatelessWidget {
  final VoidCallback onLogin;
  const _NotLoggedIn({required this.onLogin});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.card_giftcard, size: 64, color: AppTheme.primary),
            const SizedBox(height: 16),
            const Text('登录后参与推广活动',
                style:
                    TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            const Text('推荐好友得 VIP，返现 50% 上不封顶',
                style: TextStyle(color: AppTheme.textSub)),
            const SizedBox(height: 20),
            FilledButton(onPressed: onLogin, child: const Text('去登录')),
          ],
        ),
      ),
    );
  }
}
