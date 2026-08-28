import 'package:flutter/material.dart';

import '../app_state.dart';
import '../constants.dart';
import '../theme.dart';
import 'login_page.dart';
import 'paywall_page.dart';
import 'feedback_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Future<void> _goLogin() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LoginPage()),
    );
  }

  Future<void> _confirmLogout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('退出后本地数据仍会保留，下次登录同一账号即可继续使用。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await AppState.instance.logout();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListenableBuilder(
        listenable: AppState.instance,
        builder: (context, _) {
          final st = AppState.instance;
          final user = st.currentUser;
          final isPro = st.isPro;
          return ListView(
            padding: const EdgeInsets.only(top: 8, bottom: 32),
            children: [
              // ---- 账号卡片 ----
              Card(
                child: user == null
                    ? ListTile(
                        leading: const CircleAvatar(
                          backgroundColor: Color(0xFFE8EAFB),
                          child: Icon(Icons.person_outline,
                              color: AppTheme.primary),
                        ),
                        title: const Text('未登录',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: const Text('登录后可保存订阅状态'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _goLogin,
                      )
                    : ListTile(
                        leading: CircleAvatar(
                          backgroundColor:
                              AppTheme.primary.withValues(alpha: 0.12),
                          foregroundColor: AppTheme.primary,
                          child: Text(
                            (user.nickname.isNotEmpty
                                    ? user.nickname
                                    : user.maskedPhone)
                                .characters
                                .first,
                            style:
                                const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        title: Text(
                          user.nickname.isNotEmpty
                              ? user.nickname
                              : '接单管家用户',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          '${user.maskedPhone} · 本地账号',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: IconButton(
                          icon:
                              const Icon(Icons.logout, color: AppTheme.textSub),
                          tooltip: '退出登录',
                          onPressed: _confirmLogout,
                        ),
                      ),
              ),
              // ---- 订阅状态卡片 ----
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(isPro ? Icons.verified : Icons.lock_outline,
                          color: isPro ? AppTheme.accent : AppTheme.warn,
                          size: 32),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isPro ? '专业版 · 已解锁全部功能' : '免费版',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: isPro
                                    ? AppTheme.accent
                                    : AppTheme.textMain,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _subText(st, isPro),
                              style: const TextStyle(
                                  color: AppTheme.textSub, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // ---- 升级入口 ----
              Card(
                child: ListTile(
                  leading: const Icon(Icons.workspace_premium_outlined,
                      color: AppTheme.primary),
                  title: const Text('升级专业版'),
                  subtitle: const Text('无限客户 / 无限项目 / 全部功能'),
                  trailing: const Icon(Icons.chevron_right,
                      color: AppTheme.textSub),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PaywallPage(
                        title: '解锁接单管家的全部能力',
                        desc: '从此不限客户数、不限项目数，专心接单不再被工具卡住。',
                      ),
                    ),
                  ),
                ),
              ),
              // ---- 意见反馈入口 ----
              Card(
                child: ListTile(
                  leading: const Icon(Icons.feedback_outlined,
                      color: AppTheme.primary),
                  title: const Text('意见反馈'),
                  subtitle: const Text('提交 Bug 或更新建议'),
                  trailing: const Icon(Icons.chevron_right,
                      color: AppTheme.textSub),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const FeedbackPage()),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Center(
                child: Text(
                  '接单管家 v${AppConfig.version}',
                  style: TextStyle(color: AppTheme.textSub, fontSize: 12),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  String _subText(AppState st, bool isPro) {
    if (isPro) {
      final expire = st.currentUser?.proExpireAt;
      if (st.currentUser != null && expire != null) {
        final date = DateTime.fromMillisecondsSinceEpoch(expire);
        return '订阅有效期至 ${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      }
      return '感谢支持，欢迎持续使用';
    }
    if (st.currentUser == null) {
      return '登录后购买订阅，账号内长期有效';
    }
    return '免费版可管理 ${AppConfig.freeCustomerLimit} 个客户、${AppConfig.freeProjectLimit} 个进行中项目';
  }
}
