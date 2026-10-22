import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../theme.dart';
import 'payout_account_page.dart';

/// 钱包页：只展示推广返利佣金（可提现返佣 = 服务端「待打款返现」）。
/// 提现走模块 B 服务端申请打款（POST /api/payout/apply），
/// 项目收款（payments）到账不会进入钱包余额，也不可提现。
class WalletPage extends StatefulWidget {
const   WalletPage({super.key});

  @override
  State<WalletPage> createState() => _WalletPageState();
}

class _WalletPageState extends State<WalletPage> {
  final _fmt = NumberFormat('#,##0.00');

  int _balance = 0; // 可提现返佣（分，= 待打款返现）
  int _totalRebate = 0; // 累计返现（分）
  int _paidRebate = 0; // 已打款（分）
  int _pendingRebate = 0; // 待打款（分）
  bool _busy = false; // 申请打款中禁用，防重复提交

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final stats = await AppState.instance.inviteStats();
    if (!mounted) return;
    setState(() {
      _totalRebate = stats.totalRebate;
      _paidRebate = stats.paidRebate;
      _pendingRebate = stats.pendingRebate;
      _balance = stats.pendingRebate;
    });
  }

  // ---------- 申请打款（模块 B：服务端返现提现，按返现订单核销） ----------

  Future<void> _applyPayout() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.instance.t('invite_apply_payout')),
        content: Text(
          L10n.instance.t('i18n_244', args: {'v0': _fmt.format(_balance / 100)}) +
          L10n.instance.t('i18n_368'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(L10n.instance.t('common_cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(L10n.instance.t('wallet_confirm_request'))),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() => _busy = true);
    try {
      final r = await AppState.instance.applyPayout();
      if (!mounted) return;
      if (r.error != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(r.error!)));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(r.count > 0
              ? L10n.instance.t('i18n_279', args: {'v0':r.count.toString(), 'v1':_fmt.format(r.amount)})
              : L10n.instance.t('i18n_421')),
        ));
        await _load();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------- 视图 ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(L10n.instance.t('common_wallet'))),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 32),
        children: [
          _BalanceCard(
            balance: _balance,
            totalRebate: _totalRebate,
            paidRebate: _paidRebate,
            pendingRebate: _pendingRebate,
            fmt: _fmt,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: (_busy || _balance <= 0) ? null : _applyPayout,
                icon: Icon(Icons.account_balance_wallet_outlined),
                label: Text(_busy ? L10n.instance.t('common_submitting') : L10n.instance.t('invite_apply_payout')),
              ),
            ),
          ),
          Card(
            child: ListTile(
              leading: Icon(Icons.credit_card, color: AppTheme.primary),
              title: Text(L10n.instance.t('invite_payout_account')),
              subtitle: Text(L10n.instance.t('wallet_account_desc'),
                  style: TextStyle(fontSize: 12)),
              trailing:
                  const Icon(Icons.chevron_right, color: AppTheme.textSub),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const PayoutAccountPage()),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
            child: Text(
              L10n.instance.t('i18n_624') +
              L10n.instance.t('i18n_634'),
              style: const TextStyle(
                  color: AppTheme.textSub, fontSize: 12, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// 余额卡
class _BalanceCard extends StatelessWidget {
  final int balance;
  final int totalRebate;
  final int paidRebate;
  final int pendingRebate;
  final NumberFormat fmt;
const _BalanceCard({
    required this.balance,
    required this.totalRebate,
    required this.paidRebate,
    required this.pendingRebate,
    required this.fmt,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF4A5AF0), Color(0xFF7C5CF0)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(L10n.instance.t('wallet_withdrawable'),
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85), fontSize: 13)),
          const SizedBox(height: 8),
          Text('¥${fmt.format(balance / 100)}',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 34,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Text(L10n.instance.t('i18n_530', args: {'v0': fmt.format(totalRebate / 100)}),
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.75),
                        fontSize: 12,
                        height: 1.5)),
              ),
              Expanded(
                child: Text(L10n.instance.t('i18n_277', args: {'v0': fmt.format(paidRebate / 100)}),
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.75),
                        fontSize: 12,
                        height: 1.5)),
              ),
              Expanded(
                child: Text(L10n.instance.t('i18n_314', args: {'v0': fmt.format(pendingRebate / 100)}),
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.75),
                        fontSize: 12,
                        height: 1.5)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
