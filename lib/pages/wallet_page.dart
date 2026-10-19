import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../theme.dart';
import 'payout_account_page.dart';

/// 钱包页：只展示推广返利佣金（可提现返佣 = 服务端「待打款返现」）。
/// 提现走模块 B 服务端申请打款（POST /api/payout/apply），
/// 项目收款（payments）到账不会进入钱包余额，也不可提现。
class WalletPage extends StatefulWidget {
  const WalletPage({super.key});

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
        title: const Text('申请打款'),
        content: Text(
          '将申请把待打款返现 ¥${_fmt.format(_balance / 100)} 打款至您配置的返现收款账户。\n\n'
          '提交后由管理员核对打款，到账后状态更新为「已打款」。',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认申请')),
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
              ? '已提交打款申请：${r.count} 笔，合计 ¥${_fmt.format(r.amount)}'
              : '暂无可申请的返现'),
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
      appBar: AppBar(title: const Text('钱包')),
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
                icon: const Icon(Icons.account_balance_wallet_outlined),
                label: Text(_busy ? '提交中…' : '申请打款'),
              ),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.credit_card, color: AppTheme.primary),
              title: const Text('返现收款账户'),
              subtitle: const Text('用于接收返现打款，申请打款时使用',
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
              '钱包仅累计推广返利佣金（邀请好友付费后返现其付款金额的 50%）。\n'
              '项目收款到账不会进入钱包余额，也不可提现。',
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
        gradient: const LinearGradient(
          colors: [Color(0xFF4A5AF0), Color(0xFF7C5CF0)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('可提现返佣',
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
                child: Text('累计返现\n¥${fmt.format(totalRebate / 100)}',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.75),
                        fontSize: 12,
                        height: 1.5)),
              ),
              Expanded(
                child: Text('已打款\n¥${fmt.format(paidRebate / 100)}',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.75),
                        fontSize: 12,
                        height: 1.5)),
              ),
              Expanded(
                child: Text('待打款\n¥${fmt.format(pendingRebate / 100)}',
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
