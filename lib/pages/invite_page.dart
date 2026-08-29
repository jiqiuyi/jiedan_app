import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../constants.dart';
import '../models.dart';
import '../theme.dart';
import 'login_page.dart';

/// 推广活动页（云端自动核验版）
///
/// 规则：
/// - 好友注册时填写你的邀请码，自动绑定邀请关系
/// - 好友真实付款开通 VIP → 返现 50%，上不封顶
/// - 每 2 位有效好友 → 免费送 VIP 1 个月（云端自动发放）
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
    // 云端模式下 VIP 赠送由后端自动发放，本地兜底逻辑直接返回 false
    final granted = await st.grantInviteVipIfEligible();
    final code = await st.myInviteCode();
    final stats = await st.inviteStats();
    final list = await st.cloudInvitees();
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
                        '把邀请码发给朋友，朋友注册时填入即可自动完成邀请，无需手动登记。',
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
                        '推荐 ${_list.length}/$need 位有效好友，即可免费获得 VIP '
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
              // ---- 好友列表 ----
              if (_list.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(28),
                  child: Center(
                    child: Text('还没有好友通过你的邀请码注册\n把邀请码发给朋友，注册后自动出现在这里',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppTheme.textSub)),
                  ),
                )
              else
                ..._list.map((e) => _InviteeTile(e: e)),
              const SizedBox(height: 12),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '活动规则（云端自动核验）：\n'
                  '1. 好友注册时填写你的邀请码，系统自动绑定邀请关系；\n'
                  '2. 好友付款开通专业版后自动返现其付款金额的 50%，上不封顶；\n'
                  '3. 每 2 位有效好友自动免费赠送 VIP 1 个月；\n'
                  '4. 邀请关系与返现均由云端自动结算，无需手动登记与标记。',
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
  const _InviteeTile({required this.e});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat('#,##0.00');
    final name = e.name.trim().isEmpty ? '好友${e.id ?? ''}' : e.name;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: AppTheme.primary.withValues(alpha: 0.1),
          foregroundColor: AppTheme.primary,
          child: Text(
            name.characters.first,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        title: Text(name,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          e.paid
              ? '已付款 ¥${fmt.format(e.payAmount)} · 返现 ¥${fmt.format(e.rebate)}'
              : (e.phone.isNotEmpty ? e.phone : '已注册 · 待付款'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: e.paid
            ? Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTheme.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('已返现',
                    style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.accent,
                        fontWeight: FontWeight.w600)),
              )
            : Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTheme.textSub.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text('待付款',
                    style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.textSub,
                        fontWeight: FontWeight.w600)),
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
