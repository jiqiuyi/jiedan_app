import 'package:flutter/material.dart';

import '../app_state.dart';
import '../constants.dart';
import '../theme.dart';

/// 登录 / 注册页
/// MVP 阶段为本地账号体系：账号仅保存在本机 SQLite，无云端。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _phoneCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final _inviteCtrl = TextEditingController();

  bool _isRegister = false; // 登录 / 注册切换
  bool _obscurePwd = true;
  bool _obscureConfirm = true;
  bool _agree = true;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _pwdCtrl.dispose();
    _nameCtrl.dispose();
    _confirmCtrl.dispose();
    _inviteCtrl.dispose();
    super.dispose();
  }

  String? _validate() {
    final phone = _phoneCtrl.text.trim();
    if (!RegExp(r'^1\d{10}$').hasMatch(phone)) {
      return '请输入 11 位手机号';
    }
    if (_pwdCtrl.text.length < 6) {
      return '密码至少 6 位';
    }
    if (_isRegister) {
      if (_pwdCtrl.text.length > 20) return '密码最多 20 位';
      if (_pwdCtrl.text != _confirmCtrl.text) return '两次输入的密码不一致';
      if (!_agree) return '请先阅读并同意服务条款';
    }
    return null;
  }

  Future<void> _submit() async {
    final err = _validate();
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
    });

    String? result;
    if (_isRegister) {
      result = await AppState.instance.register(
        _phoneCtrl.text.trim(),
        _pwdCtrl.text,
        _nameCtrl.text.trim(),
        inviteCode: _inviteCtrl.text.trim(),
      );
      // 注册成功即已自动登录（云端返回 token 与用户信息）
    } else {
      result = await AppState.instance.login(
        _phoneCtrl.text.trim(),
        _pwdCtrl.text,
      );
    }

    if (!mounted) return;
    if (result == null) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _loading = false;
        _error = result;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 20),
                  Center(
                    child: Container(
                      width: 68,
                      height: 68,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [AppTheme.primary, AppTheme.primaryDark],
                        ),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Icon(Icons.work_outline,
                          color: Colors.white, size: 36),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    AppConfig.appName,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '自由职业者的接单记账工具箱',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: AppTheme.textSub),
                  ),
                  const SizedBox(height: 28),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('登录'), icon: Icon(Icons.login)),
                      ButtonSegment(value: true, label: Text('注册'), icon: Icon(Icons.person_add_alt_1)),
                    ],
                    selected: {_isRegister},
                    onSelectionChanged: (s) => setState(() {
                      _isRegister = s.first;
                      _error = null;
                    }),
                    style: SegmentedButton.styleFrom(
                      selectedBackgroundColor: AppTheme.primary.withValues(alpha: 0.12),
                      selectedForegroundColor: AppTheme.primary,
                      foregroundColor: AppTheme.textSub,
                      textStyle: const TextStyle(fontWeight: FontWeight.w600),
                      side: const BorderSide(color: Color(0xFFE4E7EF)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (_isRegister) ...[
                    TextField(
                      controller: _nameCtrl,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: '昵称（选填）',
                        prefixIcon: Icon(Icons.badge_outlined),
                        hintText: '怎么称呼你',
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  TextField(
                    controller: _phoneCtrl,
                    keyboardType: TextInputType.phone,
                    maxLength: 11,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: '手机号',
                      counterText: '',
                      prefixIcon: Icon(Icons.phone_android),
                      hintText: '请输入 11 位手机号',
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _pwdCtrl,
                    obscureText: _obscurePwd,
                    maxLength: 20,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: '密码',
                      counterText: '',
                      prefixIcon: const Icon(Icons.lock_outline),
                      hintText: '至少 6 位',
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePwd ? Icons.visibility_off : Icons.visibility,
                          size: 20,
                          color: AppTheme.textSub,
                        ),
                        onPressed: () =>
                            setState(() => _obscurePwd = !_obscurePwd),
                      ),
                    ),
                  ),
                  if (_isRegister) ...[
                    const SizedBox(height: 14),
                    TextField(
                      controller: _confirmCtrl,
                      obscureText: _obscureConfirm,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: '确认密码',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscureConfirm
                                ? Icons.visibility_off
                                : Icons.visibility,
                            size: 20,
                            color: AppTheme.textSub,
                          ),
                          onPressed: () => setState(
                              () => _obscureConfirm = !_obscureConfirm),
                        ),
                      ),
                    ),
                  ],
                  if (_isRegister) ...[
                    const SizedBox(height: 14),
                    TextField(
                      controller: _inviteCtrl,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                      decoration: const InputDecoration(
                        labelText: '邀请码（选填）',
                        prefixIcon: Icon(Icons.redeem_outlined),
                        hintText: '填写好友邀请码，自动绑定推广关系',
                      ),
                    ),
                  ],
                  if (_isRegister) ...[
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Checkbox(
                          value: _agree,
                          activeColor: AppTheme.primary,
                          onChanged: (v) => setState(() => _agree = v ?? false),
                        ),
                        Expanded(
                          child: GestureDetector(
                            onTap: () => showDialog(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('账号与数据说明'),
                                content: const Text(
                                  '账号、订阅与推广数据保存在云端服务器，支持跨设备登录同步。\n\n客户、项目、收款等业务数据仍只保存在本机，不上传服务器。\n\n注册即表示同意《用户协议》与《隐私政策》。',
                                  style: TextStyle(fontSize: 13),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx),
                                    child: const Text('知道了'),
                                  ),
                                ],
                              ),
                            ),
                            child: const Text(
                              '我已阅读并同意《用户协议》与《隐私政策》',
                              style: TextStyle(fontSize: 12, color: AppTheme.textSub),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppTheme.danger.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline,
                              size: 18, color: AppTheme.danger),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _error!,
                              style: const TextStyle(
                                  fontSize: 13, color: AppTheme.danger),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  SizedBox(
                    height: 48,
                    child: FilledButton(
                      onPressed: _loading ? null : _submit,
                      child: _loading
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2.5, color: Colors.white),
                            )
                          : Text(_isRegister ? '注册并登录' : '登录'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Center(
                    child: Text(
                      '账号云端同步 · 业务数据仅存本机',
                      style: TextStyle(fontSize: 12, color: AppTheme.textSub),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
