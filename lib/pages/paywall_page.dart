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
  bool _yearly = true; // 默认推荐年付
  bool _paying = false;

  Future<void> _buy() async {
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
    }

    setState(() => _paying = true);
    await AppState.instance.activatePro(months: _yearly ? 12 : 1);
    if (!mounted) return;
    setState(() => _paying = false);
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_yearly
            ? '已订阅专业版（年付·365天）'
            : '已订阅专业版（月付·30天）'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('升级专业版')),
      body: ListenableBuilder(
        listenable: AppState.instance,
        builder: (context, _) {
          final isPro = AppState.instance.isPro;
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
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _yearly = false),
                      child: _PlanCard(
                        name: '月付',
                        price: '¥${AppConfig.monthlyPrice}/月',
                        selected: !_yearly,
                        highlight: false,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _yearly = true),
                      child: _PlanCard(
                        name: '年付',
                        price: '¥${AppConfig.yearlyPrice}/年',
                        selected: _yearly,
                        highlight: true,
                      ),
                    ),
                  ),
                ],
              ),
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
                        : const Text('立即解锁')),
              ),
              const SizedBox(height: 12),
              const Center(
                child: Text(
                  'MVP 演示阶段：支付网关未接入，点击即解锁。\n正式版上线后将接入支付宝/微信支付。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppTheme.textSub, fontSize: 12),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  final String name;
  final String price;
  final bool selected;
  final bool highlight;
  const _PlanCard({
    required this.name,
    required this.price,
    required this.selected,
    required this.highlight,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: highlight ? AppTheme.primary : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected
              ? (highlight ? AppTheme.primary : AppTheme.primary)
              : const Color(0xFFE4E7EF),
          width: selected ? 1.8 : 1,
        ),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: AppTheme.primary.withValues(alpha: 0.15),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: Column(
        children: [
          Text(highlight ? '推荐' : name,
              style: TextStyle(
                fontSize: 13,
                color: highlight ? Colors.white70 : AppTheme.textSub,
              )),
          const SizedBox(height: 8),
          Text(price,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: highlight ? Colors.white : AppTheme.textMain,
              )),
          const SizedBox(height: 4),
          Text('无限全部功能',
              style: TextStyle(
                fontSize: 12,
                color: highlight ? Colors.white70 : AppTheme.textSub,
              )),
        ],
      ),
    );
  }
}
