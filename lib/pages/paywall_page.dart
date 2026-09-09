import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api_client.dart';
import '../app_state.dart';
import '../constants.dart';
import '../theme.dart';
import 'login_page.dart';

class PaywallPage extends StatefulWidget {
  final String title;
  final String desc;
  const PaywallPage({super.key, required this.title, required this.desc});

  @override
  State<PaywallPage> createState() => _PaywallPageState();
}

class _PaywallPageState extends State<PaywallPage> {
  bool _paying = false;
  bool _firstMonthUsed = false; // 当前账号是否已用过首月特惠
  int _selected = 1; // 默认选中档位（年付）
  // ignore: prefer_final_fields // 保留可变开关，恢复永久档时改为 true
  bool _showForever = false; // 永久档展示开关：暂时隐藏，恢复时改 true

  /// 订阅档位（按展示顺序）
  List<_Plan> get _plans => [
        if (!_firstMonthUsed)
          const _Plan(
            name: '首月特惠',
            price: '¥${AppConfig.firstMonthPrice}',
            desc: '仅限首次开通，每人一次',
            months: 1,
            planKey: 'firstMonth',
            isFirstMonth: true,
            highlight: true,
          ),
        const _Plan(
          name: '月付',
          price: '¥${AppConfig.monthlyPrice}/月',
          desc: '按月订阅，随时可续',
          months: 1,
          planKey: 'month',
        ),
        const _Plan(
          name: '年付',
          price: '¥${AppConfig.yearlyPrice}/年',
          desc: '相当于每月不到 ¥6',
          months: 12,
          planKey: 'year',
        ),
        // 永久档暂时隐藏（代码保留，恢复展示把 _showForever 改为 true）
        if (_showForever)
          const _Plan(
            name: '永久',
            price: '¥${AppConfig.foreverPrice}',
            desc: '一次买断，永久使用',
            months: -1,
            planKey: 'forever',
            lifetime: true,
          ),
      ];

  @override
  void initState() {
    super.initState();
    _loadFirstMonthState();
  }

  Future<void> _loadFirstMonthState() async {
    final used = await AppState.instance.firstMonthOfferUsed();
    if (!mounted) return;
    setState(() => _firstMonthUsed = used);
  }

  // 立即解锁（在线支付）：调后端 POST /api/pay/create 拿 url（易支付跳转链接），
  // 手机端拉起 url 跳转；支付结果自动轮询 + 手动刷新。
  Future<void> _buyZpay() async {
    final plans = _plans;
    if (_selected >= plans.length) return;
    final plan = plans[_selected];

    // 未登录：先引导登录，登录成功后继续下单
    if (!AppState.instance.loggedIn) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('需要先登录'),
          content: const Text('购买订阅前请先登录账号，订阅将绑定到该账号上。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('暂不登录')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('去登录'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (ok != true) return;
      final logged = await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const LoginPage()),
      );
      if (logged != true || !mounted) return;
      await _loadFirstMonthState();
      if (!mounted) return;
    }

    setState(() => _paying = true);
    try {
      final json = await ApiClient.instance.payCreate(plan.planKey);
      if (!mounted) return;
      final granted = await showDialog<bool>(
        context: context,
        builder: (_) => _ZpayPayDialog(
          planName: plan.name,
          amount: (json['amount'] as num?)?.toDouble() ?? 0,
          payUrl: (json['url'] ?? '').toString(),
          qrUrl: (json['url_qrcode'] ?? '').toString(),
        ),
      );
      if (!mounted) return;
      if (granted == true) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(plan.successText)));
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('下单失败，请稍后重试')),
      );
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  // 兑换码开通弹窗（服务端核销）
  Future<void> _showRedeemDialog() async {
    final controller = TextEditingController();
    final messenger = ScaffoldMessenger.of(context);
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('兑换码开通'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('输入兑换码即可开通专业版，由系统后台核销。'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '请输入兑换码',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('兑换'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty || !mounted) return;
    final err = await AppState.instance.redeemVipCode(result);
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(content: Text(err ?? '兑换成功，已开通专业版')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('升级专业版')),
      body: ListenableBuilder(
        listenable: AppState.instance,
        builder: (context, _) {
          final isPro = AppState.instance.isPro;
          final plans = _plans;
          if (_selected >= plans.length) _selected = plans.length - 1;
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const SizedBox(height: 16),
              const Icon(Icons.workspace_premium, size: 64,
                  color: AppTheme.primary),
              const SizedBox(height: 16),
              Text(widget.title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(widget.desc,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppTheme.textSub)),
              const SizedBox(height: 24),
              ...List.generate(plans.length, (i) {
                final p = plans[i];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _PlanCard(
                    plan: p,
                    selected: _selected == i,
                    onTap: () => setState(() => _selected = i),
                  ),
                );
              }),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: (isPro || _paying) ? null : _buyZpay,
                child: isPro
                    ? const Text('已是专业版')
                    : (_paying
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.5, color: Colors.white),
                          )
                        : Text(plans[_selected].buyText)),
              ),
              const SizedBox(height: 12),
              const Center(
                child: Text(
                  '付款成功后由系统自动开通，无需等待人工确认。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppTheme.textSub, fontSize: 12),
                ),
              ),
              const SizedBox(height: 16),
              const Center(
                child: Text(
                  '兑换码由系统后台核销开通，请从可靠渠道获取',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppTheme.textSub, fontSize: 12),
                ),
              ),
              Center(
                child: TextButton.icon(
                  onPressed: _showRedeemDialog,
                  icon: const Icon(Icons.confirmation_number_outlined,
                      size: 18),
                  label: const Text('兑换码开通'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 订阅档位定义
class _Plan {
  final String name;
  final String price;
  final String desc;
  final int months; // 订阅月数（lifetime 时忽略）
  final String planKey; // 对应后端套餐标识
  final bool isFirstMonth; // 是否首月特惠档
  final bool lifetime; // 是否永久买断
  final bool highlight; // 是否高亮推荐

  const _Plan({
    required this.name,
    required this.price,
    required this.desc,
    required this.months,
    required this.planKey,
    this.isFirstMonth = false,
    this.lifetime = false,
    this.highlight = false,
  });

  String get buyText => isFirstMonth ? '¥${AppConfig.firstMonthPrice} 开通首月' : '立即解锁';

  String get successText {
    if (isFirstMonth) return '已开通专业版（首月特惠 · 30天）';
    if (lifetime) return '已开通专业版（永久买断）';
    if (months >= 24) return '已开通专业版（两年 · 730天）';
    if (months >= 12) return '已开通专业版（年付 · 365天）';
    return '已开通专业版（月付 · 30天）';
  }
}

class _PlanCard extends StatelessWidget {
  final _Plan plan;
  final bool selected;
  final VoidCallback onTap;
  const _PlanCard({
    required this.plan,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isHighlight = plan.highlight;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: selected
              ? (isHighlight
                  ? AppTheme.primary
                  : AppTheme.primary.withValues(alpha: 0.08))
              : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? AppTheme.primary
                : const Color(0xFFE4E7EF),
            width: selected ? 1.8 : 1,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: AppTheme.primary.withValues(alpha: 0.12),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off,
              size: 22,
              color: selected
                  ? (isHighlight ? Colors.white : AppTheme.primary)
                  : AppTheme.textSub,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(plan.name,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: selected && isHighlight
                                ? Colors.white
                                : AppTheme.textMain,
                          )),
                      if (isHighlight) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: selected
                                ? Colors.white.withValues(alpha: 0.2)
                                : AppTheme.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '限时',
                            style: TextStyle(
                              fontSize: 10,
                              color: selected
                                  ? Colors.white
                                  : AppTheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(plan.desc,
                      style: TextStyle(
                        fontSize: 12,
                        color: selected && isHighlight
                            ? Colors.white70
                            : AppTheme.textSub,
                      )),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(plan.price,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: selected && isHighlight
                      ? Colors.white
                      : AppTheme.textMain,
                )),
          ],
        ),
      ),
    );
  }
}

/// 在线支付确认弹层：
/// 展示「打开支付页面」（易支付跳转链接），后端配置支付渠道后可用；
/// 支付结果自动轮询云端订阅状态，用户亦可手动点「已完成支付」刷新。
class _ZpayPayDialog extends StatefulWidget {
  final String planName;
  final double amount;
  final String payUrl;
  final String qrUrl;

  const _ZpayPayDialog({
    required this.planName,
    required this.amount,
    required this.payUrl,
    required this.qrUrl,
  });

  @override
  State<_ZpayPayDialog> createState() => _ZpayPayDialogState();
}

class _ZpayPayDialogState extends State<_ZpayPayDialog> {
  Timer? _timer;
  int _ticks = 0;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    // 轮询后端订阅状态（最多 10 次 × 3s），检测到开通后自动关闭
    _timer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (_ticks >= 10) {
        _timer?.cancel();
        return;
      }
      _ticks++;
      try {
        await AppState.instance.refreshCloud();
      } catch (_) {
        // 网络波动忽略，下一轮再试
      }
      if (!mounted) return;
      if (AppState.instance.isPro) {
        _timer?.cancel();
        Navigator.of(context).pop(true);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _openPayPage() async {
    final url = widget.payUrl;
    if (url.isEmpty) return;
    try {
      final ok = await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法拉起支付页面，请手动复制链接或扫码')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法拉起支付页面')),
        );
      }
    }
  }

  Future<void> _manualRefresh() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      await AppState.instance.refreshCloud();
    } catch (_) {
      // 忽略，弹层内提示
    } finally {
      if (mounted) setState(() => _checking = false);
    }
    if (!mounted) return;
    if (AppState.instance.isPro) {
      Navigator.of(context).pop(true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('尚未检测到开通，可稍后再次刷新')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasQr = widget.qrUrl.isNotEmpty;
    final hasUrl = widget.payUrl.isNotEmpty;
    return AlertDialog(
      title: Text('在线支付 · ${widget.planName}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('应付金额：¥${widget.amount.toStringAsFixed(2)}'),
            const SizedBox(height: 12),
            if (!hasUrl && !hasQr)
              const Text('支付渠道暂未开通，请稍后再试或使用兑换码。',
                  style: TextStyle(color: AppTheme.warn)),
            if (hasUrl) ...[
              const Text('点击下方按钮打开支付页面完成付款。'),
              const SizedBox(height: 8),
            ],
            if (hasQr)
              Center(
                child: Image.network(
                  widget.qrUrl,
                  width: 200,
                  height: 200,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Icon(
                      Icons.qr_code, size: 120, color: AppTheme.textSub),
                ),
              ),
          ],
        ),
      ),
      actions: [
        if (hasUrl)
          FilledButton.icon(
            onPressed: _openPayPage,
            icon: const Icon(Icons.open_in_browser, size: 18),
            label: const Text('打开支付页面'),
          ),
        TextButton(
          onPressed: _checking ? null : _manualRefresh,
          child: Text(_checking ? '刷新中…' : '已完成支付'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
