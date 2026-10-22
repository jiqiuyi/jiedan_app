import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import '../constants.dart';
import '../models.dart';
import '../theme.dart';
import 'login_page.dart';
import 'payout_account_page.dart';
import '../widgets/app_ui.dart';

/// 推广活动页（第15批过渡期：本地自动核验版）
///
/// 规则：
/// - 好友注册时填写你的邀请码，自动绑定邀请关系
/// - 好友真实付款开通 VIP → 返现 50%
/// - 每 2 位有效好友 → 免费送 VIP 1 个月（过渡期本地发放，正式版切云端）
class InvitePage extends StatefulWidget {
const   InvitePage({super.key});

  @override
  State<InvitePage> createState() => _InvitePageState();
}

class _InvitePageState extends State<InvitePage> {
  final _fmt = NumberFormat('#,##0.00');
  String _inviteCode = '';
  String _inviteLink = '';
  bool _applying = false;
  List<Invitee> _list = [];
  InviteStats _stats = InviteStats(
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
              L10n.instance.t('i18n_330', args: {'v0':AppConfig.inviteFreeVipFriends.toString(), 'v1':AppConfig.inviteRewardMonths.toStringAsFixed(0)})),
        ),
      );
    }
  }

  Future<void> _copyCode() async {
    await Clipboard.setData(ClipboardData(text: _inviteCode));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(L10n.instance.t('invite_code_copied'))));
  }

  Future<void> _copyLink() async {
    await Clipboard.setData(ClipboardData(text: _inviteLink));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(L10n.instance.t('invite_link_copied'))));
  }

  Future<void> _share() async {
    try {
      await Share.share(
        L10n.instance.t('i18n_336', args: {'v0': _inviteCode, 'v1': _inviteLink}),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.instance.t('invite_share_failed'))));
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
      return L10n.instance.t('i18n_249');
    }
    final label = method == 'alipay'
        ? L10n.instance.t('invite_page_alipay')
        : (method == 'wechat' ? L10n.instance.t('invite_page_wechat') : L10n.instance.t('invite_no_method'));
    final masked = account.length <= 4
        ? account
        : '${account.substring(0, 2)}****${account.substring(account.length - 2)}';
    final codes = <String>[
      if (wx) L10n.instance.t('i18n_254'),
      if (ali) L10n.instance.t('i18n_255'),
    ].join('、');
    return '$label · ${name.isEmpty ? L10n.instance.t('invite_no_name') : name} · ${masked.isEmpty ? L10n.instance.t('invite_no_account') : masked}'
        '${codes.isEmpty ? L10n.instance.t('invite_no_qr_code') : ' · $codes'}';
  }

  String _applyTimeText(int ts) => DateFormat('yyyy-MM-dd HH:mm')
      .format(DateTime.fromMillisecondsSinceEpoch(ts));

  Future<void> _openPayoutAccount() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PayoutAccountPage()),
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
          L10n.instance.t('i18n_278', args: {'v0':r.count.toString(), 'v1':_fmt.format(r.amount)})),
    ));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final st = AppState.instance;
    return Scaffold(
      appBar: AppBar(title: Text(L10n.instance.t('invite_title'))),
      body: ListenableBuilder(
        listenable: AppState.instance,
        builder: (context, _) {
          if (!st.loggedIn) {
            return _NotLoggedIn(onLogin: () async {
              final ok = await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => LoginPage()),
              );
              if (ok == true) await _load();
            });
          }
          if (_loading) {
            return AppLoading();
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
                      Text(L10n.instance.t('invite_my_code'),
                          style: TextStyle(
                              fontSize: 13, color: AppTheme.textSub)),
                      SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            _inviteCode,
                            style: TextStyle(
                              fontSize: 32,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 3,
                              color: AppTheme.primary,
                            ),
                          ),
                          SizedBox(width: 12),
                          IconButton(
                            onPressed: _copyCode,
                            icon: Icon(Icons.copy_rounded,
                                size: 20, color: AppTheme.textSub),
                            tooltip: L10n.instance.t('invite_copy_code'),
                          ),
                        ],
                      ),
                      SizedBox(height: 12),
                      Text(
                        L10n.instance.t('i18n_344'),
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
                                label: L10n.instance.t('invite_referred'),
                                value: '${_list.length}',
                                unit: L10n.instance.t('i18n_098')),
                          ),
                          Expanded(
                            child: _Stat(
                                label: L10n.instance.t('invite_paid'),
                                value: '${_stats.paidCount}',
                                unit: L10n.instance.t('i18n_098')),
                          ),
                          Expanded(
                            child: _Stat(
                                label: L10n.instance.t('invite_total_rebate'),
                                value: _fmt.format(_stats.totalRebate / 100),
                                unit: L10n.instance.t('i18n_119')),
                          ),
                        ],
                      ),
                      SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: _Stat(
                                label: L10n.instance.t('invite_paid_out'),
                                value: _fmt.format(_stats.paidRebate / 100),
                                unit: L10n.instance.t('i18n_119')),
                          ),
                          Expanded(
                            child: _Stat(
                                label: L10n.instance.t('admin_payout_tab'),
                                value: _fmt.format(_stats.pendingRebate / 100),
                                unit: L10n.instance.t('i18n_119')),
                          ),
                        ],
                      ),
                      SizedBox(height: 16),
                      Text(
                        '${L10n.instance.t('i18n_366', args: {'v0': _list.length.toString(), 'v1': need.toString()})}'
                        '${L10n.instance.t('i18n_014', args: {'v0': AppConfig.inviteRewardMonths.toStringAsFixed(0)})}'
                        '${_stats.bonusGranted ? L10n.instance.t('invite_claimed') : ''}',
                        style: TextStyle(
                            fontSize: 13, color: AppTheme.textSub),
                      ),
                      SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadius.xxs),
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
                      Text(L10n.instance.t('invite_my_link'),
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textMain)),
                      SizedBox(height: 6),
                      Text(_inviteLink,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: AppTheme.textSub)),
                      SizedBox(height: 4),
                      Row(
                        children: [
                          TextButton.icon(
                            onPressed: _copyLink,
                            icon: Icon(Icons.link_rounded, size: 16),
                            label: Text(L10n.instance.t('invite_copy_link')),
                          ),
                          Spacer(),
                          FilledButton.tonalIcon(
                            onPressed: _share,
                            icon: Icon(Icons.ios_share_rounded, size: 16),
                            label: Text(L10n.instance.t('invite_share')),
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
                          Expanded(
                            child: Text(L10n.instance.t('invite_payout_account'),
                                style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.textMain)),
                          ),
                          TextButton(
                            onPressed: _openPayoutAccount,
                            child: Text(
                                AppState.instance.payoutInfo().isEmpty
                                    ? L10n.instance.t('invite_page_settings')
                                    : L10n.instance.t('i18n_118')),
                          ),
                        ],
                      ),
                      Text(_accountSummary(),
                          style: TextStyle(
                              fontSize: 12, color: AppTheme.textSub)),
                      SizedBox(height: 8),
                      Text(
                        _stats.applyAt != null
                            ? L10n.instance.t('invite_apply_pending_desc', args: {'_applyTimeText(_stats.applyAt!)': _applyTimeText(_stats.applyAt!)})
                            : L10n.instance.t('i18n_312', args: {'v0': _fmt.format(_stats.pendingRebate / 100)}),
                        style: TextStyle(
                            fontSize: 12, color: AppTheme.textSub),
                      ),
                      SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: (_stats.pendingRebate <= 0 || _applying)
                              ? null
                              : _applyPayout,
                          child: Text(_applying ? L10n.instance.t('common_submitting') : L10n.instance.t('invite_apply_payout')),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // ---- 好友列表 ----
              if (_list.isEmpty)
                AppEmpty(
                  icon: Icons.group_add_outlined,
                  title: L10n.instance.t('i18n_596'),
                )
              else
                ..._list.map((e) => _InviteeTile(e: e)),
              SizedBox(height: 12),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  L10n.instance.t('i18n_484') +
                  L10n.instance.t('i18n_030') +
                  L10n.instance.t('i18n_031') +
                  L10n.instance.t('i18n_034') +
                  L10n.instance.t('i18n_035') +
                  L10n.instance.t('i18n_478'),
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
          style: TextStyle(
              fontSize: 20, fontWeight: FontWeight.w800, color: AppTheme.textMain),
        ),
        Text('$label（$unit）',
            style: TextStyle(fontSize: 12, color: AppTheme.textSub)),
      ],
    );
  }
}

class _InviteeTile extends StatelessWidget {
  final Invitee e;
const   _InviteeTile({required this.e});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat('#,##0.00');
    final name = e.name.trim().isEmpty ? L10n.instance.t('invite_friend_id', args: {'v0':'${e.id ?? ''}'}) : e.name;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: AppTheme.primary.withValues(alpha: 0.1),
          foregroundColor: AppTheme.primary,
          child: Text(
            name.characters.first,
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        title: Text(name,
            style: TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          e.paid
              ? L10n.instance.t('i18n_253', args: {'v0': fmt.format(e.payAmount / 100), 'v1': fmt.format(e.rebate / 100)})
              : (e.phone.isNotEmpty ? e.phone : L10n.instance.t('i18n_285')),
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
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                ),
                child: Text(
                  e.payoutAt != null ? L10n.instance.t('invite_page_paid_out') : L10n.instance.t('invite_page_pending_payout'),
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
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                ),
                child: Text(L10n.instance.t('invite_pending_payment'),
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
const   _NotLoggedIn({required this.onLogin});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.card_giftcard, size: 64, color: AppTheme.primary),
            SizedBox(height: 16),
            Text(L10n.instance.t('invite_login_tip'),
                style:
                    TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            SizedBox(height: 8),
            Text(L10n.instance.t('invite_banner'),
                style: TextStyle(color: AppTheme.textSub)),
            SizedBox(height: 20),
            FilledButton(onPressed: onLogin, child: Text(L10n.instance.t('common_go_login'))),
          ],
        ),
      ),
    );
  }
}
