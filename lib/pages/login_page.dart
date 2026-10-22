import 'package:flutter/material.dart';
import '../l10n/l10n.dart';

import '../app_state.dart';
import '../constants.dart';
import '../services/error_reporter.dart';
import '../theme.dart';
import 'privacy_policy_page.dart';

/// 登录 / 注册页
/// MVP 阶段为本地账号体系：账号仅保存在本机 SQLite，无云端。
class LoginPage extends StatefulWidget {
const   LoginPage({super.key});

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
  bool _agree = false;
  bool _loading = false;
  bool _detectedInvite = false; // 邀请码来自剪贴板 / 官网落地页
  bool _inviteDialogShown = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prefillInvite();
  }

  /// 模块 A：自动预填邀请码（官网 ?ic= 落地页写入剪贴板 / 本地暂存）
  Future<void> _prefillInvite() async {
    final st = AppState.instance;
    await st.restorePendingInviteCode();
    var code = st.pendingInviteCode;
    if (code.isEmpty) {
      await st.captureClipboardInviteCode();
      code = st.pendingInviteCode;
    }
    if (!mounted || code.isEmpty) return;
    setState(() {
      _inviteCtrl.text = code;
      _detectedInvite = true;
      _isRegister = true; // 带邀请码时默认落在注册页
    });
    _showInviteDialog(code);
  }

  void _showInviteDialog(String code) {
    if (_inviteDialogShown || !mounted) return;
    _inviteDialogShown = true;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.instance.t('login_inviter_detected')),
        content: Text(L10n.instance.t('login_invite_code_desc', args: {'code':code})),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                _inviteCtrl.clear();
                _detectedInvite = false;
              });
            },
            child: Text(L10n.instance.t('login_skip_bind')),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() => _inviteCtrl.text = code);
            },
            child: Text(L10n.instance.t('login_confirm_bind')),
          ),
        ],
      ),
    );
  }

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
      return L10n.instance.t('login_page_enter_an');
    }
    if (_pwdCtrl.text.length < 6) {
      return L10n.instance.t('i18n_236');
    }
    if (!_agree) {
      return L10n.instance.t('i18n_568');
    }
    if (_isRegister) {
      if (_pwdCtrl.text.length > 20) return L10n.instance.t('i18n_235');
      if (_pwdCtrl.text != _confirmCtrl.text) return L10n.instance.t('i18n_083');
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
    try {
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
    } catch (e, st) {
      // 兜底：登录/注册链路任何未预期异常（三星 Keystore/加密存储、
      // 数据库迁移失败、SharedPreferences 写入等）一律转成登录页局部错误，
      // 绝不冒泡到 runZonedGuarded 触发全局「操作未能完成，请稍后重试」误导文案。
      ErrorReporter.instance.logError(
          _isRegister ? 'register_submit' : 'login_submit', e, st);
      if (mounted) {
        setState(() {
          _loading = false;
          _error = L10n.instance.t('i18n_374');
        });
      }
      return;
    }

    if (!mounted) return;
    if (result == null) {
      if (_isRegister) {
        try {
          await AppState.instance.clearPendingInviteCode();
        } catch (e, st) {
          // 清理暂存邀请码失败不阻断注册成功（仅留日志）。
          ErrorReporter.instance.logError('clear_pending_invite', e, st);
        }
      }
      if (!mounted) return;
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
              constraints: BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(height: 20),
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
                        borderRadius: BorderRadius.circular(AppRadius.sheet),
                      ),
                      child: Icon(Icons.work_outline,
                          color: Colors.white, size: 36),
                    ),
                  ),
                  SizedBox(height: 16),
                  Text(
                    AppConfig.appName,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                  ),
                  SizedBox(height: 6),
                  Text(
                    L10n.instance.t('i18n_547'),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: AppTheme.textSub),
                  ),
                  SizedBox(height: 28),
                  SegmentedButton<bool>(
                    segments: [
                      ButtonSegment(value: false, label: Text(L10n.instance.t('common_login')), icon: Icon(Icons.login)),
                      ButtonSegment(value: true, label: Text(L10n.instance.t('common_signup')), icon: Icon(Icons.person_add_alt_1)),
                    ],
                    selected: {_isRegister},
                    onSelectionChanged: (s) => setState(() {
                      _isRegister = s.first;
                      _error = null;
                      if (s.first &&
                          _inviteCtrl.text.isEmpty &&
                          AppState.instance.pendingInviteCode.isNotEmpty) {
                        _inviteCtrl.text =
                            AppState.instance.pendingInviteCode;
                        _detectedInvite = true;
                      }
                    }),
                    style: SegmentedButton.styleFrom(
                      selectedBackgroundColor: AppTheme.primary.withValues(alpha: 0.12),
                      selectedForegroundColor: AppTheme.primary,
                      foregroundColor: AppTheme.textSub,
                      textStyle: TextStyle(fontWeight: FontWeight.w600),
                      side: BorderSide(color: Color(0xFFE4E7EF)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                    ),
                  ),
                  SizedBox(height: 24),
                  if (_isRegister) ...[
                    TextField(
                      controller: _nameCtrl,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: L10n.instance.t('i18n_419'),
                        prefixIcon: Icon(Icons.badge_outlined),
                        hintText: L10n.instance.t('login_nickname_title'),
                      ),
                    ),
                    SizedBox(height: 14),
                  ],
                  TextField(
                    controller: _phoneCtrl,
                    keyboardType: TextInputType.phone,
                    maxLength: 11,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: L10n.instance.t('i18n_343'),
                      counterText: '',
                      prefixIcon: Icon(Icons.phone_android),
                      hintText: L10n.instance.t('login_phone_hint'),
                    ),
                  ),
                  SizedBox(height: 14),
                  TextField(
                    controller: _pwdCtrl,
                    obscureText: _obscurePwd,
                    maxLength: 20,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: L10n.instance.t('i18n_234'),
                      counterText: '',
                      prefixIcon: Icon(Icons.lock_outline),
                      hintText: L10n.instance.t('login_pwd_hint'),
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
                    SizedBox(height: 14),
                    TextField(
                      controller: _confirmCtrl,
                      obscureText: _obscureConfirm,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: L10n.instance.t('i18n_510'),
                        prefixIcon: Icon(Icons.lock_outline),
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
                    SizedBox(height: 14),
                    TextField(
                      controller: _inviteCtrl,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: L10n.instance.t('i18n_615'),
                        prefixIcon: Icon(Icons.redeem_outlined),
                        hintText: L10n.instance.t('login_invite_hint'),
                        helperText: _detectedInvite
                            ? L10n.instance.t('i18n_286')
                            : null,
                      ),
                    ),
                  ],
                  SizedBox(height: 14),
                  Row(
                    children: [
                      Checkbox(
                        value: _agree,
                        activeColor: AppTheme.primary,
                        onChanged: (v) => setState(() => _agree = v ?? false),
                      ),
                      Expanded(
                        child: GestureDetector(
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const PrivacyPolicyPage()),
                          ),
                          child: Text(
                            L10n.instance.t('i18n_337'),
                            style: TextStyle(
                                fontSize: 12, color: AppTheme.textSub),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_error != null) ...[
                    SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppTheme.danger.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline,
                              size: 18, color: AppTheme.danger),
                          SizedBox(width: 8),
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
                  SizedBox(height: 24),
                  SizedBox(
                    height: 48,
                    child: FilledButton(
                      onPressed: _loading ? null : _submit,
                      child: _loading
                          ? SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2.5, color: Colors.white),
                            )
                          : Text(_isRegister ? L10n.instance.t('login_signup_login') : L10n.instance.t('common_login')),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: Text(
                      L10n.instance.t('i18n_587'),
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
