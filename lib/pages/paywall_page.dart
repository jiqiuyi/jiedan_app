import 'dart:async';
import '../l10n/l10n.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:gal/gal.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api_client.dart';
import '../app_state.dart';
import '../constants.dart';
import '../theme.dart';
import 'login_page.dart';
import '../widgets/app_ui.dart';

class PaywallPage extends StatefulWidget {
  final String title;
  final String desc;
const   PaywallPage({super.key, required this.title, required this.desc});

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
          _Plan(
            name: L10n.instance.t('i18n_637'),
            price: '¥${AppConfig.firstMonthPrice}',
            desc: L10n.instance.t('i18n_104'),
            months: 1,
            planKey: 'firstMonth',
            isFirstMonth: true,
            highlight: true,
          ),
        _Plan(
          name: L10n.instance.t('i18n_433'),
          price: L10n.instance.t('i18n_050', args: {'v0':'${AppConfig.monthlyPrice}'}),
          desc: L10n.instance.t('i18n_359'),
          months: 1,
          planKey: 'month',
        ),
        _Plan(
          name: L10n.instance.t('i18n_292'),
          price: L10n.instance.t('i18n_051', args: {'v0':'${AppConfig.yearlyPrice}'}),
          desc: L10n.instance.t('i18n_500'),
          months: 12,
          planKey: 'year',
        ),
        // 永久档暂时隐藏（代码保留，恢复展示把 _showForever 改为 true）
        if (_showForever)
          _Plan(
            name: L10n.instance.t('i18n_481'),
            price: '¥${AppConfig.foreverPrice}',
            desc: L10n.instance.t('i18n_058'),
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

  // 立即解锁：先选支付方式（微信 / 支付宝），再走简付收银台扫码支付；
  // 付款成功由服务端回调自动开通，弹层内轮询 + 手动刷新兜底。
  Future<void> _startBuy() async {
    final plans = _plans;
    if (_selected >= plans.length) return;
    final plan = plans[_selected];
    if (!await _ensureLoggedIn()) return;
    final method = await _choosePayMethod(plan);
    if (!mounted) return;
    if (method == null) return;
    if (method == 'other') {
      await _buyZpay();
      return;
    }

    setState(() => _paying = true);
    try {
      final json = await ApiClient.instance.jianpayCreate(plan.planKey, method);
      if (!mounted) return;
      final granted = await showDialog<bool>(
        context: context,
        builder: (_) => _JianpayPayDialog(
          planName: plan.name,
          amount: (json['amount'] as num?)?.toDouble() ?? 0,
          orderNo: (json['orderNo'] ?? '').toString(),
          payMethod: method,
          payUrl: (json['payUrl'] ?? '').toString(),
          qrUrl: (json['payQrcodeUrl'] ?? '').toString(),
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
        SnackBar(content: Text(L10n.instance.t('paywall_order_failed'))),
      );
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  /// 支付方式选择：微信 / 支付宝走扫码支付，其他方式走网页支付页面。
  Future<String?> _choosePayMethod(_Plan plan) {
    return showAppSheet<String>(
      context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(L10n.instance.t('paywall_choose_method'),
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700)),
                  ),
                  Text(plan.price,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            SizedBox(height: 4),
            ListTile(
              leading: Icon(Icons.chat_bubble,
                  color: Color(0xFF07C160)),
              title: Text(L10n.instance.t('paywall_wechat')),
              subtitle: Text(L10n.instance.t('paywall_scan_tip')),
              onTap: () => Navigator.pop(ctx, 'wx'),
            ),
            ListTile(
              leading: Icon(Icons.account_balance_wallet,
                  color: Color(0xFF1677FF)),
              title: Text(L10n.instance.t('common_alipay')),
              subtitle: Text(L10n.instance.t('paywall_scan_tip')),
              onTap: () => Navigator.pop(ctx, 'alipay'),
            ),
            SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  /// 未登录时先引导登录，返回是否可继续下单。
  Future<bool> _ensureLoggedIn() async {
    if (AppState.instance.loggedIn) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.instance.t('common_login_required')),
        content: Text(L10n.instance.t('paywall_login_desc')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(L10n.instance.t('paywall_skip_login'))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(L10n.instance.t('common_go_login')),
          ),
        ],
      ),
    );
    if (!mounted) return false;
    if (ok != true) return false;
    final logged = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => LoginPage()),
    );
    if (logged != true || !mounted) return false;
    await _loadFirstMonthState();
    return mounted;
  }

  // 其他支付方式：调后端 POST /api/pay/create 拿 url（跳转链接），
  // 手机端拉起 url 跳转；支付结果自动轮询 + 手动刷新。
  Future<void> _buyZpay() async {
    final plans = _plans;
    if (_selected >= plans.length) return;
    final plan = plans[_selected];
    if (!await _ensureLoggedIn()) return;

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
        SnackBar(content: Text(L10n.instance.t('paywall_order_failed'))),
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
        title: Text(L10n.instance.t('paywall_redeem_title')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(L10n.instance.t('paywall_redeem_desc')),
            SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: L10n.instance.t('paywall_redeem_hint'),
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(L10n.instance.t('common_cancel'))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(L10n.instance.t('paywall_redeem')),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty || !mounted) return;
    final err = await AppState.instance.redeemVipCode(result);
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(content: Text(err ?? L10n.instance.t('paywall_redeem_ok'))));
  }

  // 6h 退款入口：先查退款资格（开通 6h 内、每账号 1 次），再提交退款。
  // 退款原路退回，退款成功后专业版权益立即收回。
  Future<void> _showRefundDialog() async {
    final messenger = ScaffoldMessenger.of(context);
    Map<String, dynamic> st;
    setState(() => _paying = true);
    try {
      st = await ApiClient.instance.jianpayRefundStatus();
    } on ApiException catch (e) {
      if (mounted) setState(() => _paying = false);
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    } catch (_) {
      if (mounted) setState(() => _paying = false);
      messenger.showSnackBar(SnackBar(content: Text(L10n.instance.t('paywall_query_failed'))));
      return;
    }
    if (!mounted) return;
    setState(() => _paying = false);

    final can = st['canRefund'] == true;
    final reason = (st['reason'] ?? '').toString();
    final orderNo = (st['orderNo'] ?? '').toString();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.instance.t('paywall_refund')),
        content: Text(can
            ? L10n.instance.t('i18n_601')
            : L10n.instance.t('i18n_308', args: {'v0': reason})),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(L10n.instance.t('common_close'))),
          if (can)
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(L10n.instance.t('paywall_confirm_refund')),
            ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _paying = true);
    try {
      final r = await ApiClient.instance.jianpayRefund(orderNo);
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
          content: Text((r['message'] ?? L10n.instance.t('paywall_refund_done')).toString())));
      try {
        await AppState.instance.refreshCloud();
      } catch (_) {
        // 订阅状态刷新失败不阻塞提示，下次进入页面会重新拉取
      }
    } on ApiException catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(L10n.instance.t('paywall_refund_failed'))));
      }
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(L10n.instance.t('paywall_upgrade_pro'))),
      body: ListenableBuilder(
        listenable: AppState.instance,
        builder: (context, _) {
          final isPro = AppState.instance.isPro;
          final plans = _plans;
          if (_selected >= plans.length) _selected = plans.length - 1;
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              SizedBox(height: 16),
              Icon(Icons.workspace_premium, size: 64,
                  color: AppTheme.primary),
              SizedBox(height: 16),
              Text(widget.title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700)),
              SizedBox(height: 8),
              Text(widget.desc,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppTheme.textSub)),
              SizedBox(height: 24),
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
              SizedBox(height: 20),
              FilledButton(
                onPressed: (isPro || _paying) ? null : _startBuy,
                child: isPro
                    ? Text(L10n.instance.t('paywall_already_pro'))
                    : (_paying
                        ? SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.5, color: Colors.white),
                          )
                        : Text(plans[_selected].buyText)),
              ),
              SizedBox(height: 12),
              // 两行说明小字：起点对齐（同一左边缘），整体在页面内水平居中
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      L10n.instance.t('i18n_111'),
                      style: TextStyle(color: AppTheme.textSub, fontSize: 12),
                    ),
                    SizedBox(height: 6),
                    Text(
                      L10n.instance.t('i18n_126'),
                      style: TextStyle(color: AppTheme.textSub, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Center(
                child: TextButton.icon(
                  onPressed: _showRedeemDialog,
                  icon: Icon(Icons.confirmation_number_outlined,
                      size: 18),
                  label: Text(L10n.instance.t('paywall_redeem_title')),
                ),
              ),
              if (isPro)
                Center(
                  child: TextButton.icon(
                    onPressed: _paying ? null : _showRefundDialog,
                    icon: Icon(Icons.assignment_return_outlined,
                        size: 18),
                    label: Text(L10n.instance.t('paywall_refund_window')),
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

  _Plan({
    required this.name,
    required this.price,
    required this.desc,
    required this.months,
    required this.planKey,
    this.isFirstMonth = false,
    this.lifetime = false,
    this.highlight = false,
  });

  String get buyText => isFirstMonth ? L10n.instance.t('i18n_049', args: {'v0':'${AppConfig.firstMonthPrice}'}) : L10n.instance.t('i18n_517');

  String get successText {
    if (isFirstMonth) return L10n.instance.t('i18n_274');
    if (lifetime) return L10n.instance.t('i18n_273');
    if (months >= 24) return L10n.instance.t('i18n_270');
    if (months >= 12) return L10n.instance.t('i18n_271');
    return L10n.instance.t('i18n_272');
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
        duration: Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: selected
              ? (isHighlight
                  ? AppTheme.primary
                  : AppTheme.primary.withValues(alpha: 0.08))
              : Colors.white,
          borderRadius: BorderRadius.circular(AppRadius.lg),
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
            SizedBox(width: 14),
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
                            borderRadius: BorderRadius.circular(AppRadius.xs),
                          ),
                          child: Text(
                            L10n.instance.t('i18n_628'),
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
            SizedBox(width: 12),
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
    _timer = Timer.periodic(Duration(seconds: 3), (_) async {
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
          SnackBar(content: Text(L10n.instance.t('paywall_cannot_open'))),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.instance.t('paywall_page_could_not'))),
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
        SnackBar(content: Text(L10n.instance.t('paywall_not_active'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasQr = widget.qrUrl.isNotEmpty;
    final hasUrl = widget.payUrl.isNotEmpty;
    return AlertDialog(
      title: Text(L10n.instance.t('paywall_online_title', args: {'widget.planName': widget.planName})),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(L10n.instance.t('paywall_amount_line', args: {'widget.amount.toStringAsFixed(2)': widget.amount.toStringAsFixed(2)})),
            SizedBox(height: 12),
            if (!hasUrl && !hasQr)
              Text(L10n.instance.t('paywall_channel_not_ready'),
                  style: TextStyle(color: AppTheme.warn)),
            if (hasUrl) ...[
              Text(L10n.instance.t('paywall_open_tip')),
              SizedBox(height: 8),
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
            icon: Icon(Icons.open_in_browser, size: 18),
            label: Text(L10n.instance.t('paywall_open_page')),
          ),
        TextButton(
          onPressed: _checking ? null : _manualRefresh,
          child: Text(_checking ? L10n.instance.t('common_refreshing') : L10n.instance.t('paywall_paid')),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(L10n.instance.t('common_close')),
        ),
      ],
    );
  }
}

/// 简付收银台扫码支付弹层：
/// 展示支付二维码，按支付方式提供「打开微信 / 打开支付宝 / 保存二维码」；
/// 每 3s 向后端查单（最多 10 次）+「我已支付，刷新」兜底，开通后自动关闭。
class _JianpayPayDialog extends StatefulWidget {
  final String planName;
  final double amount;
  final String orderNo;
  final String payMethod; // wx / alipay
  final String payUrl;
  final String qrUrl;
const _JianpayPayDialog({
    required this.planName,
    required this.amount,
    required this.orderNo,
    required this.payMethod,
    required this.payUrl,
    required this.qrUrl,
  });

  @override
  State<_JianpayPayDialog> createState() => _JianpayPayDialogState();
}

class _JianpayPayDialogState extends State<_JianpayPayDialog> {
  Timer? _timer;
  int _ticks = 0;
  bool _checking = false;
  bool _saving = false;

  bool get _isWx => widget.payMethod == 'wx';

  String get _methodName => _isWx ? L10n.instance.t('paywall_page_wechat') : L10n.instance.t('paywall_page_alipay');

  @override
  void initState() {
    super.initState();
    // 轮询后端查单补偿（最多 10 次 × 3s），确认支付成功后自动关闭
    _timer = Timer.periodic(Duration(seconds: 3), (_) async {
      if (_ticks >= 10) {
        _timer?.cancel();
        return;
      }
      _ticks++;
      final paid = await _syncOnce();
      if (!mounted) return;
      if (paid) {
        _timer?.cancel();
        Navigator.of(context).pop(true);
      } else {
        setState(() {});
      }
    });
    // 支付宝小微可走 H5：弹层打开即自动拉起收银台 payUrl（跳支付宝 App），无需扫码
    if (!_isWx && widget.payUrl.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openPayPage());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 向后端查单一次；已开通返回 true（并刷新云端订阅状态）。
  Future<bool> _syncOnce() async {
    try {
      final j = await ApiClient.instance.jianpaySyncOrder(widget.orderNo);
      if (j['paid'] == true) {
        try {
          await AppState.instance.refreshCloud();
        } catch (_) {
          // 云端刷新失败不阻塞开通判定，后续进入页面会重新拉取
        }
        return true;
      }
    } catch (_) {
      // 网络波动忽略，下一轮再试
    }
    return false;
  }

  Future<void> _manualRefresh() async {
    if (_checking) return;
    setState(() => _checking = true);
    final paid = await _syncOnce();
    if (!mounted) return;
    setState(() => _checking = false);
    if (paid) {
      _timer?.cancel();
      Navigator.of(context).pop(true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.instance.t('paywall_not_paid'))),
      );
    }
  }

  /// 打开对应 App：微信 weixin:// / 支付宝 alipays://
  Future<void> _openPayApp() async {
    final scheme = _isWx ? 'weixin://' : 'alipays://';
    try {
      final ok = await launchUrl(Uri.parse(scheme),
          mode: LaunchMode.externalApplication);
      if (!ok && mounted) _hintOpenManually();
    } catch (_) {
      if (mounted) _hintOpenManually();
    }
  }

  void _hintOpenManually() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L10n.instance.t('paywall_open_method_fail', args: {'_methodName':_methodName}))),
    );
  }

  /// 保存二维码：下载二维码图片后直接写入系统相册（Android MediaStore / iOS Photos）。
  Future<void> _saveQr() async {
    if (_saving || widget.qrUrl.isEmpty) return;
    setState(() => _saving = true);
    try {
      final resp = await http.get(Uri.parse(widget.qrUrl));
      if (resp.statusCode != 200) throw Exception(L10n.instance.t('i18n_074'));
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/pay_qr_${widget.orderNo}.png');
      await f.writeAsBytes(resp.bodyBytes);
      // Android 10+ 通过 MediaStore 写入无需申请权限，低版本需存储权限
      if (!await Gal.hasAccess()) {
        await Gal.requestAccess();
      }
      await Gal.putImage(f.path);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.instance.t('paywall_qr_saved'))),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.instance.t('paywall_qr_save_fail'))),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openPayPage() async {
    final url = widget.payUrl;
    if (url.isEmpty) return;
    try {
      final ok = await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.instance.t('paywall_cannot_open_scan'))),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.instance.t('paywall_page_could_not_2'))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasQr = widget.qrUrl.isNotEmpty;
    final h5 = !_isWx; // 支付宝小微走 H5 直接拉起，微信走扫码
    return AlertDialog(
      title: Text(h5 ? L10n.instance.t('paywall_alipay_title', args: {'widget.planName': widget.planName}) : L10n.instance.t('paywall_scan_title', args: {'widget.planName': widget.planName})),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(L10n.instance.t('paywall_amount_line', args: {'widget.amount.toStringAsFixed(2)': widget.amount.toStringAsFixed(2)})),
            SizedBox(height: 6),
            Text(
              h5
                  ? L10n.instance.t('i18n_476')
                  : L10n.instance.t('i18n_579', args: {'v0': _methodName}),
              style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
            ),
            SizedBox(height: 12),
            if (!h5)
              if (hasQr)
                Center(
                  child: Image.network(
                    widget.qrUrl,
                    width: 200,
                    height: 200,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Icon(Icons.qr_code,
                        size: 120, color: AppTheme.textSub),
                  ),
                )
              else
                Text(L10n.instance.t('paywall_qr_fetch_fail'),
                    style: TextStyle(color: AppTheme.warn)),
            SizedBox(height: 8),
            Center(
              child: Text(
                _ticks >= 10 ? L10n.instance.t('i18n_439') : L10n.instance.t('i18n_475', args: {'v0':'$_ticks'}),
                style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
              ),
            ),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      actions: [
        // 三个操作按钮等宽排成一行（微信 / 支付宝一致）；「关闭」按钮已移除，
        // 用户可点弹层遮罩或按系统返回键关闭。
        Row(
          children: [
            Expanded(
              child: AppButton(
                label: h5 ? L10n.instance.t('paywall_open_alipay') : L10n.instance.t('paywall_open_method', args: {'_methodName':_methodName}),
                kind: AppButtonKind.primary,
                size: AppButtonSize.small,
                expand: false,
                onPressed: h5 ? _openPayPage : _openPayApp,
              ),
            ),
            if (hasQr) ...[
              SizedBox(width: 8),
              Expanded(
                child: AppButton(
                  label: _saving ? L10n.instance.t('paywall_page_saving') : L10n.instance.t('paywall_save_qr'),
                  kind: AppButtonKind.secondary,
                  size: AppButtonSize.small,
                  expand: false,
                  onPressed: _saving ? null : _saveQr,
                ),
              ),
            ],
            SizedBox(width: 8),
            Expanded(
              child: AppButton(
                label: _checking ? L10n.instance.t('common_refreshing') : L10n.instance.t('paywall_refresh'),
                kind: AppButtonKind.secondary,
                size: AppButtonSize.small,
                expand: false,
                onPressed: _checking ? null : _manualRefresh,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
