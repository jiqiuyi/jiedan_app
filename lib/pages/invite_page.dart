import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import '../constants.dart';
import '../models.dart';
import '../theme.dart';
import 'login_page.dart';
import 'payout_account_page.dart';

/// 推广活动页（第15批过渡期：本地自动核验版）
///
/// 规则：
/// - 好友注册时填写你的邀请码，自动绑定邀请关系
/// - 好友真实付款开通 VIP → 返现 50%
/// - 每 2 位有效好友 → 免费送 VIP 1 个月（过渡期本地发放，正式版切云端）
class InvitePage extends StatefulWidget {
  const InvitePage({super.key});

  @override
  State<InvitePage> createState() => _InvitePageState();
}

class _InvitePageState extends State<InvitePage> {
  final _fmt = NumberFormat('#,##0.00');
  String _inviteCode = '';
  String _inviteLink = '';
  bool _applying = false;
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
    // 第15批过渡期：本地自动核验满 2 位有效好友并发放 VIP（云端就绪时由服务端发放）
    final granted = await st.grantInviteVipIfEligible();
    final code = await st.myInviteCode();
    final stats = await st.inviteStats();
    final list = await st.cloudInvitees();
    if (!mounted) return;
    final rawLink = st.cloudMe?['inviteLink'];
    setState(() {
      _inviteCode = code;
      _inviteLink = (rawLink is String && rawLink.isNotEmpty)
          ? rawLink
          : 'https://yurouyun.cn/?ic=$code';
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

  Future<void> _copyLink() async {
    await Clipboard.setData(ClipboardData(text: _inviteLink));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('专属邀请链接已复制')));
  }

  Future<void> _share() async {
    try {
      await Share.share(
        '我在用「接单管家」管报价、客户和项目，注册时填邀请码 $_inviteCode 即可：\n$_inviteLink',
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('分享失败，可复制链接后手动发送')));
    }
  }

  /// 收款账户脱敏摘要（模块 B）
  String _accountSummary() {
    final p = AppState.instance.payoutInfo();
    final method = (p['method'] ?? '').toString();
    final name = (p['name'] ?? '').toString();
    final account = (p['account'] ?? '').toString();
    final wx = p['hasWechatQrcode'] == true;
    final ali = p['hasAlipayQrcode'] == true;
    if (method.isEmpty && name.isEmpty && account.isEmpty && !wx && !ali) {
      return '尚未设置，设置后才能申请打款';
    }
    final label = method == 'alipay'
        ? '支付宝'
        : (method == 'wechat' ? '微信' : '未选方式');
    final masked = account.length <= 4
        ? account
        : '${account.substring(0, 2)}****${account.substring(account.length - 2)}';
    final codes = <String>[
      if (wx) '已传微信码',
      if (ali) '已传支付宝码',
    ].join('、');
    return '$label · ${name.isEmpty ? '未填姓名' : name} · ${masked.isEmpty ? '未填账号' : masked}'
        '${codes.isEmpty ? ' · 未传收款码' : ' · $codes'}';
  }

  String _applyTimeText(int ts) => DateFormat('yyyy-MM-dd HH:mm')
      .format(DateTime.fromMillisecondsSinceEpoch(ts));

  Future<void> _openPayoutAccount() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const PayoutAccountPage()),
    );
    if (!mounted) return;
    await _load();
  }

  Future<void> _applyPayout() async {
    if (_applying) return;
    setState(() => _applying = true);
    final r = await AppState.instance.applyPayout();
    if (!mounted) return;
    setState(() => _applying = false);
    if (r.error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(r.error!)));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
          '已提交 ${r.count} 笔、合计 ¥${_fmt.format(r.amount)}，打款后会更新状态'),
    ));
    await _load();
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
                                value: _fmt.format(_stats.totalRebate / 100),
                                unit: '元'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: _Stat(
                                label: '已打款',
                                value: _fmt.format(_stats.paidRebate / 100),
                                unit: '元'),
                          ),
                          Expanded(
                            child: _Stat(
                                label: '待打款',
                                value: _fmt.format(_stats.pendingRebate / 100),
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
              // ---- 专属邀请链接卡片 ----
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('专属邀请链接',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textMain)),
                      const SizedBox(height: 6),
                      Text(_inviteLink,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, color: AppTheme.textSub)),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          TextButton.icon(
                            onPressed: _copyLink,
                            icon: const Icon(Icons.link_rounded, size: 16),
                            label: const Text('复制链接'),
                          ),
                          const Spacer(),
                          FilledButton.tonalIcon(
                            onPressed: _share,
                            icon: const Icon(Icons.ios_share_rounded, size: 16),
                            label: const Text('分享给好友'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              // ---- 返现收款账户 & 申请打款（模块 B）----
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text('返现收款账户',
                                style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.textMain)),
                          ),
                          TextButton(
                            onPressed: _openPayoutAccount,
                            child: Text(
                                AppState.instance.payoutInfo().isEmpty
                                    ? '去设置'
                                    : '修改'),
                          ),
                        ],
                      ),
                      Text(_accountSummary(),
                          style: const TextStyle(
                              fontSize: 12, color: AppTheme.textSub)),
                      const SizedBox(height: 8),
                      Text(
                        _stats.applyAt != null
                            ? '已申请，等待打款（${_applyTimeText(_stats.applyAt!)}）'
                            : '待打款 ¥${_fmt.format(_stats.pendingRebate / 100)}，可随时申请',
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.textSub),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: (_stats.pendingRebate <= 0 || _applying)
                              ? null
                              : _applyPayout,
                          child: Text(_applying ? '提交中…' : '申请打款'),
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
                  '活动规则（第15批过渡期 · 本地核验）：\n'
                  '1. 好友注册时填写你的邀请码，系统自动绑定邀请关系；\n'
                  '2. 好友付款开通专业版后自动返现其付款金额的 50%；\n'
                  '3. 每 2 位有效好友自动免费赠送 VIP 1 个月；\n'
                  '4. VIP 赠送当前在本地发放并记录（卸载重装 / 换机后将丢失），'
                  '正式版切云端后由服务器统一赠送，可跨设备保留。',
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
              ? '已付款 ¥${fmt.format(e.payAmount / 100)} · 返现 ¥${fmt.format(e.rebate / 100)}'
              : (e.phone.isNotEmpty ? e.phone : '已注册 · 待付款'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: e.paid
            ? Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: (e.payoutAt != null
                          ? AppTheme.accent
                          : AppTheme.primary)
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  e.payoutAt != null ? '已打款' : '待打款',
                  style: TextStyle(
                      fontSize: 11,
                      color: e.payoutAt != null
                          ? AppTheme.accent
                          : AppTheme.primary,
                      fontWeight: FontWeight.w600),
                ),
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
            const Text('推荐好友得 VIP，返现 50%',
                style: TextStyle(color: AppTheme.textSub)),
            const SizedBox(height: 20),
            FilledButton(onPressed: onLogin, child: const Text('去登录')),
          ],
        ),
      ),
    );
  }
}
