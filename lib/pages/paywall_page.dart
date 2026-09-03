import 'package:flutter/material.dart';

import '../constants.dart';
import '../theme.dart';
import '../app_state.dart';
import 'login_page.dart';

class PaywallPage extends StatefulWidget {
  final String title;
  final String desc;
  const PaywallPage({super.key, required this.title, required this.desc});

  @override
  State<PaywallPage> createState() => _PaywallPageState();
}

class _PaywallPageState extends State<PaywallPage> {
  final bool _paying = false;
  bool _firstMonthUsed = false; // 当前账号是否已用过首月特惠
  int _selected = 1; // 默认选中档位（年付）

  /// 订阅档位（按展示顺序）
  List<_Plan> get _plans => [
        if (!_firstMonthUsed)
          const _Plan(
            name: '首月特惠',
            price: '¥${AppConfig.firstMonthPrice}',
            desc: '仅限首次开通，每人一次',
            months: 1,
            isFirstMonth: true,
            highlight: true,
          ),
        const _Plan(
          name: '月付',
          price: '¥${AppConfig.monthlyPrice}/月',
          desc: '按月订阅，随时可续',
          months: 1,
        ),
        const _Plan(
          name: '年付',
          price: '¥${AppConfig.yearlyPrice}/年',
          desc: '相当于每月不到 ¥6',
          months: 12,
        ),
        const _Plan(
          name: '永久',
          price: '¥${AppConfig.foreverPrice}',
          desc: '一次买断，永久使用',
          months: -1,
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

  Future<void> _buy() async {
    final plans = _plans;
    if (_selected >= plans.length) return;
    final plan = plans[_selected];

    // 未登录：先引导登录，登录成功后自动完成解锁
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
      // 登录成功后刷新首月特惠状态与套餐列表
      await _loadFirstMonthState();
      if (!mounted) return;
    }

    // 确认下单
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('开通专业版'),
        content: Text(
          '${plan.name} · ${plan.price}\n'
          '${plan.desc}\n\n'
          '支付功能待接入，当前无法完成购买。正式版将接入支付宝 / 微信支付。',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('知道了')),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
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
                onPressed: (isPro || _paying) ? null : _buy,
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
                  '支付功能正在接入中，暂不支持在线开通。\n正式版上线后将接入支付宝/微信支付。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppTheme.textSub, fontSize: 12),
                ),
              ),
              const SizedBox(height: 20),
              if (AppState.instance.testPro)
                Column(
                  children: [
                    const Center(
                      child: Text(
                        '当前处于「体验专业版」（开发测试解锁），全部免费版限制已解除',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppTheme.warn, fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        await AppState.instance.clearTestPro();
                      },
                      child: const Text('退出体验，恢复免费版'),
                    ),
                  ],
                )
              else
                Center(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('体验专业版'),
                          content: const Text(
                            '开发测试用：在本机直接解锁免费版全部限制（无限客户 / 项目）。\n\n'
                            '正式支付接入后此入口将移除，请放心用于功能验收与作品集演示。',
                          ),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('取消')),
                            FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('立即体验'),
                            ),
                          ],
                        ),
                      );
                      if (ok == true) {
                        await AppState.instance.unlockTestPro();
                        messenger.showSnackBar(
                          const SnackBar(
                              content:
                                  Text('已解锁专业版，可自由管理多个客户与项目')),
                        );
                      }
                    },
                    icon: const Icon(Icons.science_outlined, size: 18),
                    label: const Text('体验专业版（开发测试）'),
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
  final bool isFirstMonth; // 是否首月特惠档
  final bool lifetime; // 是否永久买断
  final bool highlight; // 是否高亮推荐

  const _Plan({
    required this.name,
    required this.price,
    required this.desc,
    required this.months,
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
