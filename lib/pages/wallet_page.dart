import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../constants.dart';
import '../database.dart';
import '../models.dart';
import '../state/ticker.dart';
import '../theme.dart';
import '../services/pay_service.dart';
import '../widgets/show_payment_code.dart';
import 'payment_code_settings_page.dart';

/// 钱包页：余额（收款 + 充值 - 提现）、充值、提现、往来记录。
/// MVP：收款码手动确认入账，真实通道接入后由回调自动处理。
class WalletPage extends StatefulWidget {
  const WalletPage({super.key});

  @override
  State<WalletPage> createState() => _WalletPageState();
}

class _WalletPageState extends State<WalletPage> {
  final _fmt = NumberFormat('#,##0.00');

  double _balance = 0; // 可提现余额
  double _totalPaid = 0; // 累计收款
  double _totalRecharged = 0; // 累计充值到账
  double _totalWithdrawn = 0; // 已提交提现
  List<Withdrawal> _withdrawals = [];
  List<Recharge> _recharges = [];
  WithdrawAccount _account = const WithdrawAccount();
  bool _busy = false; // 充值/提现执行中禁用，防重复提交

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = AppDb.instance;
    final results = await Future.wait([
      db.withdrawableBalance(),
      db.allPaidTotal(),
      db.totalRecharged(),
      db.totalWithdrawn(),
      db.getWithdrawals(),
      db.getRecharges(),
      db.getWithdrawAccount(),
    ]);
    if (!mounted) return;
    setState(() {
      _balance = results[0] as double;
      _totalPaid = results[1] as double;
      _totalRecharged = results[2] as double;
      _totalWithdrawn = results[3] as double;
      _withdrawals = results[4] as List<Withdrawal>;
      _recharges = results[5] as List<Recharge>;
      _account = results[6] as WithdrawAccount;
    });
  }

  // ---------- 充值 ----------

  Future<void> _startRecharge() async {
    if (_busy) return;
    // 预检：未配置收款码先引导去设置，不直接进充值流程
    final db = AppDb.instance;
    final wxPath = await db.getWxQrPath();
    final aliPath = await db.getAliQrPath();
    if ((wxPath == null || wxPath.isEmpty) &&
        (aliPath == null || aliPath.isEmpty)) {
      if (!mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('尚未配置收款码'),
          content: const Text('充值需向您的微信 / 支付宝收款码付款，请先到「我的 → 收款设置」上传收款码。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('暂不')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('去设置')),
          ],
        ),
      );
      if (go == true && mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const PaymentCodeSettingsPage()),
        );
      }
      return;
    }
    setState(() => _busy = true);
    try {
      await _startRechargeFlow();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startRechargeFlow() async {
    final amountCtrl = TextEditingController();
    final method = ValueNotifier<RechargeMethod>(RechargeMethod.wechat);
    const quickAmounts = <double>[10, 50, 100, 500];

    final ok = await showDialog<({double amount, RechargeMethod method})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('余额充值'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: amountCtrl,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: const InputDecoration(
                  labelText: '充值金额（元）',
                  hintText: '如 100',
                  prefixText: '¥ ',
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final q in quickAmounts)
                    ActionChip(
                      label: Text('¥${q.toStringAsFixed(0)}'),
                      onPressed: () {
                        amountCtrl.text = q.toStringAsFixed(0);
                        setDialogState(() {});
                      },
                    ),
                ],
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<RechargeMethod>(
                valueListenable: method,
                builder: (ctx, m, _) =>
                    DropdownButtonFormField<RechargeMethod>(
                  initialValue: m,
                  decoration: const InputDecoration(labelText: '充值方式'),
                  items: RechargeMethod.values
                      .map((e) =>
                          DropdownMenuItem(value: e, child: Text(e.label)))
                      .toList(),
                  onChanged: (v) => method.value = v!,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消')),
            FilledButton(
              onPressed: () {
                final amount = double.tryParse(amountCtrl.text.trim());
                if (amount == null || amount <= 0) return;
                Navigator.pop(ctx, (amount: amount, method: method.value));
              },
              child: const Text('下一步'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || ok == null) return;

    // 走充值通道（真实通道接入后自动拉起支付）
    final result = await Channels.recharge
        .createRecharge(PaymentRequest(
      orderId: 'RC${DateTime.now().millisecondsSinceEpoch}',
      amount: ok.amount,
      title: '余额充值',
    ));
    if (!mounted) return;
    if (!result.ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('充值失败：${result.message}')));
      return;
    }

    // 出示收款码，供扫码付款
    await showPaymentCodeSheet(context);
    if (!mounted) return;

    // 确认到账
    final arrived = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认到账'),
        content: Text(
          '请确认 ¥${_fmt.format(ok.amount)} 已通过'
          '${ok.method.label}支付成功。\n\n'
          '选「已到账」立即入账；选「未到账」可稍后在充值记录里标记到账。',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('未到账')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('已到账')),
        ],
      ),
    );
    if (!mounted) return;

    await AppDb.instance.insertRecharge(Recharge(
      amount: ok.amount,
      method: ok.method,
      status: arrived == true ? RechargeStatus.done : RechargeStatus.pending,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      note: arrived == true ? '手动确认到账' : '待确认',
    ));
    if (arrived == true) Ticker.ping();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(arrived == true
          ? '充值成功，¥${_fmt.format(ok.amount)} 已入账'
          : '已登记充值申请，到账后请在记录里标记到账'),
    ));
    await _load();
  }

  // ---------- 充值记录：标记到账 ----------

  Future<void> _markRechargeDone(Recharge r) async {
    await AppDb.instance
        .updateRecharge(r.copyWith(status: RechargeStatus.done));
    Ticker.ping();
    await _load();
  }

  // ---------- 提现 ----------

  Future<void> _startWithdraw() async {
    if (_busy) return;
    if (!_account.filled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先设置提现账户')),
      );
      _editAccount();
      return;
    }
    final amountCtrl = TextEditingController();
    final ok = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('申请提现'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: amountCtrl,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: const InputDecoration(
                labelText: '提现金额（元） *',
                hintText: '可提现 ¥',
              ),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '提现至【${_account.method.label}】${_account.name} ${_account.no}',
                style: const TextStyle(fontSize: 13, color: AppTheme.textMain),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消')),
          FilledButton(
            onPressed: () =>
                Navigator.pop(ctx, double.tryParse(amountCtrl.text.trim())),
            child: const Text('提交'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (ok == null || ok <= 0) return;
    if (ok > _balance) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('提现金额不能超过可提现余额')),
      );
      return;
    }
    // 走当前提现通道（真实通道接入后此处自动切换到自动打款）
    setState(() => _busy = true);
    try {
      final result = await Channels.withdraw.withdraw(WithdrawRequest(
        amount: ok,
        method: _account.method,
        accountName: _account.name,
        accountNo: _account.no,
      ));
      if (!mounted) return;
      if (result.ok) {
        await AppDb.instance.insertWithdrawal(Withdrawal(
          amount: ok,
          method: _account.method,
          accountName: _account.name,
          accountNo: _account.no,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          note: result.message,
        ));
        Ticker.ping();
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(result.message)));
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('提现失败：${result.message}')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _load();
  }

  // ---------- 提现账户设置 ----------

  Future<void> _editAccount() async {
    final methodCtrl = ValueNotifier<WithdrawMethod>(_account.method);
    final nameCtrl = TextEditingController(text: _account.name);
    final noCtrl = TextEditingController(text: _account.no);
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('提现账户',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            ValueListenableBuilder<WithdrawMethod>(
              valueListenable: methodCtrl,
              builder: (ctx, m, _) => DropdownButtonFormField<WithdrawMethod>(
                initialValue: m,
                decoration: const InputDecoration(labelText: '提现方式'),
                items: WithdrawMethod.values
                    .map((e) =>
                        DropdownMenuItem(value: e, child: Text(e.label)))
                    .toList(),
                onChanged: (v) => methodCtrl.value = v!,
              ),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<WithdrawMethod>(
              valueListenable: methodCtrl,
              builder: (ctx, m, _) => TextField(
                controller: noCtrl,
                decoration: InputDecoration(labelText: m.noHint),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: '收款人姓名'),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  final acc = WithdrawAccount(
                    method: methodCtrl.value,
                    name: nameCtrl.text.trim(),
                    no: noCtrl.text.trim(),
                  );
                  if (!acc.filled) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('请填写完整的收款人姓名与账号')),
                    );
                    return;
                  }
                  AppDb.instance.setWithdrawAccount(acc);
                  Navigator.pop(ctx);
                },
                child: const Text('保存'),
              ),
            ),
          ],
        ),
      ),
    );
    await _load();
  }

  // ---------- 标记已提现（人工打款完成后；真实通道接入后由回调自动处理） ----------

  Future<void> _markDone(Withdrawal w) async {
    await AppDb.instance.updateWithdrawal(
        w.copyWith(status: WithdrawStatus.done));
    Ticker.ping();
    await _load();
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
            totalPaid: _totalPaid,
            totalRecharged: _totalRecharged,
            totalWithdrawn: _totalWithdrawn,
            fmt: _fmt,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _busy ? null : _startRecharge,
                    icon: const Icon(Icons.add_card),
                    label: const Text('充值'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: (_busy || _balance <= 0) ? null : _startWithdraw,
                    icon: const Icon(Icons.account_balance_wallet_outlined),
                    label: const Text('申请提现'),
                  ),
                ),
              ],
            ),
          ),
          // 提现账户
          Card(
            child: ListTile(
              leading:
                  const Icon(Icons.credit_card, color: AppTheme.primary),
              title: const Text('提现账户'),
              subtitle: Text(
                _account.filled
                    ? '${_account.method.label} · ${_account.name} ${_account.no}'
                    : '未设置，点击配置收款账户',
                style: const TextStyle(fontSize: 12),
              ),
              trailing:
                  const Icon(Icons.chevron_right, color: AppTheme.textSub),
              onTap: _editAccount,
            ),
          ),
          // 收支说明
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
            child: Text(
              AppConfig.withdrawNotice,
              style: const TextStyle(
                  color: AppTheme.textSub, fontSize: 12, height: 1.5),
            ),
          ),
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            child: Text('充值记录',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textMain)),
          ),
          if (_recharges.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: Text('还没有充值记录',
                    style: TextStyle(color: AppTheme.textSub)),
              ),
            )
          else
            ..._recharges.map((r) => _RechargeTile(
                  r: r,
                  fmt: _fmt,
                  onMarkDone: r.status == RechargeStatus.done
                      ? null
                      : () => _markRechargeDone(r),
                )),
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            child: Text('提现记录',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textMain)),
          ),
          if (_withdrawals.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: Text('还没有提现记录\n收款到账后可在这里申请提现',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.textSub, height: 1.6)),
              ),
            )
          else
            ..._withdrawals.map((w) => _WithdrawTile(
                  w: w,
                  fmt: _fmt,
                  onMarkDone: w.status == WithdrawStatus.done
                      ? null
                      : () => _markDone(w),
                )),
        ],
      ),
    );
  }
}

/// 余额卡
class _BalanceCard extends StatelessWidget {
  final double balance;
  final double totalPaid;
  final double totalRecharged;
  final double totalWithdrawn;
  final NumberFormat fmt;
  const _BalanceCard({
    required this.balance,
    required this.totalPaid,
    required this.totalRecharged,
    required this.totalWithdrawn,
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
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('可提现余额',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85), fontSize: 13)),
          const SizedBox(height: 8),
          Text('¥${fmt.format(balance)}',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 34,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Text('累计收款\n¥${fmt.format(totalPaid)}',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.75),
                        fontSize: 12,
                        height: 1.5)),
              ),
              Expanded(
                child: Text('累计充值\n¥${fmt.format(totalRecharged)}',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.75),
                        fontSize: 12,
                        height: 1.5)),
              ),
              Expanded(
                child: Text('已提现\n¥${fmt.format(totalWithdrawn)}',
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

/// 充值记录项
class _RechargeTile extends StatelessWidget {
  final Recharge r;
  final NumberFormat fmt;
  final VoidCallback? onMarkDone;
  const _RechargeTile(
      {required this.r, required this.fmt, this.onMarkDone});

  @override
  Widget build(BuildContext context) {
    final dt = DateTime.fromMillisecondsSinceEpoch(r.createdAt);
    final pending = r.status == RechargeStatus.pending;
    final statusColor = pending ? AppTheme.warn : AppTheme.accent;
    return Card(
      child: ListTile(
        leading: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: AppTheme.accent.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: Icon(r.method == RechargeMethod.wechat
              ? Icons.wechat
              : Icons.account_balance_wallet_outlined,
              size: 22, color: AppTheme.accent),
        ),
        title: Text('+¥${fmt.format(r.amount)}',
            style: const TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.accent)),
        subtitle: Text(
          '${r.method.label} · ${r.note}\n'
          '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              color: AppTheme.textSub, fontSize: 12, height: 1.5),
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(r.status.label,
                  style: TextStyle(
                      fontSize: 11,
                      color: statusColor,
                      fontWeight: FontWeight.w600)),
            ),
            if (onMarkDone != null)
              TextButton(
                onPressed: onMarkDone,
                style: TextButton.styleFrom(
                    minimumSize: const Size(0, 28),
                    padding: const EdgeInsets.symmetric(horizontal: 8)),
                child: const Text('标记到账', style: TextStyle(fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }
}

/// 提现记录项
class _WithdrawTile extends StatelessWidget {
  final Withdrawal w;
  final NumberFormat fmt;
  final VoidCallback? onMarkDone;
  const _WithdrawTile(
      {required this.w, required this.fmt, this.onMarkDone});

  @override
  Widget build(BuildContext context) {
    final dt = DateTime.fromMillisecondsSinceEpoch(w.createdAt);
    final statusColor = switch (w.status) {
      WithdrawStatus.pending => AppTheme.warn,
      WithdrawStatus.processing => AppTheme.primary,
      WithdrawStatus.done => AppTheme.accent,
    };
    return Card(
      child: ListTile(
        leading: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: Text(w.method.label.characters.first,
              style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.primary)),
        ),
        title: Text('-¥${fmt.format(w.amount)}',
            style: const TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700)),
        subtitle: Text(
          '${w.method.label} · ${w.accountName} ${w.accountNo}\n'
          '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              color: AppTheme.textSub, fontSize: 12, height: 1.5),
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(w.status.label,
                  style: TextStyle(
                      fontSize: 11,
                      color: statusColor,
                      fontWeight: FontWeight.w600)),
            ),
            if (onMarkDone != null)
              TextButton(
                onPressed: onMarkDone,
                style: TextButton.styleFrom(
                    minimumSize: const Size(0, 28),
                    padding: const EdgeInsets.symmetric(horizontal: 8)),
                child: const Text('标记到账', style: TextStyle(fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }
}
