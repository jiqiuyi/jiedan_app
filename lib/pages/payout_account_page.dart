import 'dart:io';
import '../l10n/l10n.dart';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../app_state.dart';
import '../theme.dart';
import '../utils/qr_base64.dart';

/// 返现收款账户设置（模块 B）
///
/// 这里配置的是「邀请返现」的收款账户（微信 / 支付宝 + 姓名 + 账号 + 收款码），
/// 由服务端保存并在申请打款时写入订单快照。
/// 与钱包页的「本地余额提现」完全独立，互不影响。
class PayoutAccountPage extends StatefulWidget {
const   PayoutAccountPage({super.key});

  @override
  State<PayoutAccountPage> createState() => _PayoutAccountPageState();
}

class _PayoutAccountPageState extends State<PayoutAccountPage> {
  final _nameCtrl = TextEditingController();
  final _accountCtrl = TextEditingController();

  String _method = 'wechat';
  String _wxB64 = '';
  String _aliB64 = '';
  String? _wxPreview;
  String? _aliPreview;
  bool _hasWx = false;
  bool _hasAli = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _accountCtrl.dispose();
    super.dispose();
  }

  void _load() {
    final p = AppState.instance.payoutInfo();
    _method = (p['method'] ?? '').toString() == 'alipay' ? 'alipay' : 'wechat';
    _nameCtrl.text = (p['name'] ?? '').toString();
    _accountCtrl.text = (p['account'] ?? '').toString();
    _hasWx = p['hasWechatQrcode'] == true;
    _hasAli = p['hasAlipayQrcode'] == true;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _pick({required bool isWechat}) async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 92,
    );
    if (picked == null) return;
    setState(() => _busy = true);
    // 压缩为 ≤200KB 的 base64（服务端硬约束），超限自动降采样重编码
    final dataUrl = await qrImageToDataUrl(picked.path);
    if (!mounted) return;
    if (dataUrl == null) {
      setState(() => _busy = false);
      _toast(L10n.instance.t('i18n_188'));
      return;
    }
    setState(() {
      _busy = false;
      if (isWechat) {
        _wxB64 = dataUrl;
        _wxPreview = picked.path;
        _hasWx = true;
      } else {
        _aliB64 = dataUrl;
        _aliPreview = picked.path;
        _hasAli = true;
      }
    });
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    final account = _accountCtrl.text.trim();
    if (name.isEmpty) {
      _toast(L10n.instance.t('i18n_571'));
      return;
    }
    if (name.length > 20) {
      _toast(L10n.instance.t('i18n_211'));
      return;
    }
    if (account.isEmpty) {
      _toast(L10n.instance.t('i18n_572'));
      return;
    }
    if (account.length > 40) {
      _toast(L10n.instance.t('i18n_388'));
      return;
    }
    setState(() => _busy = true);
    final err = await AppState.instance.savePayoutAccount(
      method: _method,
      name: name,
      account: account,
      wechatQrcode: _wxB64,
      alipayQrcode: _aliB64,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      _toast(err);
      return;
    }
    _toast(L10n.instance.t('i18n_389'));
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(L10n.instance.t('invite_payout_account'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(4, 4, 4, 12),
            child: Text(
              L10n.instance.t('i18n_491'),
              style: TextStyle(fontSize: 12, color: AppTheme.textSub),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(L10n.instance.t('payout_method_title'),
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textMain)),
                  SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _MethodChip(
                          label: L10n.instance.t('common_wechat'),
                          icon: Icons.chat_bubble_outline,
                          selected: _method == 'wechat',
                          onTap: () => setState(() => _method = 'wechat'),
                        ),
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: _MethodChip(
                          label: L10n.instance.t('common_alipay'),
                          icon: Icons.account_balance_wallet_outlined,
                          selected: _method == 'alipay',
                          onTap: () => setState(() => _method = 'alipay'),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 16),
                  TextField(
                    controller: _nameCtrl,
                    maxLength: 20,
                    decoration: InputDecoration(
                      labelText: L10n.instance.t('i18n_380'),
                      hintText: L10n.instance.t('payout_name_hint'),
                      counterText: '',
                    ),
                  ),
                  SizedBox(height: 8),
                  TextField(
                    controller: _accountCtrl,
                    maxLength: 40,
                    decoration: InputDecoration(
                      labelText: L10n.instance.t('i18n_387'),
                      hintText: L10n.instance.t('payout_account_hint'),
                      counterText: '',
                    ),
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(L10n.instance.t('payout_account_page_qr_code'),
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textMain)),
                  SizedBox(height: 6),
                  Text(L10n.instance.t('payout_code_hint'),
                      style:
                          TextStyle(fontSize: 12, color: AppTheme.textSub)),
                  SizedBox(height: 12),
                  _QrRow(
                    label: L10n.instance.t('payment_code_wechat'),
                    hasImage: _hasWx,
                    previewPath: _wxPreview,
                    onPick: () => _pick(isWechat: true),
                  ),
                  SizedBox(height: 12),
                  _QrRow(
                    label: L10n.instance.t('payment_code_alipay'),
                    hasImage: _hasAli,
                    previewPath: _aliPreview,
                    onPick: () => _pick(isWechat: false),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: 8),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: _busy
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(L10n.instance.t('payout_save')),
          ),
        ],
      ),
    );
  }
}

class _MethodChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
const _MethodChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.primary.withValues(alpha: 0.10)
              : Colors.transparent,
          border: Border.all(
            color: selected ? AppTheme.primary : AppTheme.textSub.withValues(alpha: 0.3),
          ),
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                size: 18,
                color: selected ? AppTheme.primary : AppTheme.textSub),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: selected ? AppTheme.primary : AppTheme.textSub)),
          ],
        ),
      ),
    );
  }
}

class _QrRow extends StatelessWidget {
  final String label;
  final bool hasImage;
  final String? previewPath;
  final VoidCallback onPick;
const _QrRow({
    required this.label,
    required this.hasImage,
    required this.previewPath,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final path = previewPath;
    return Row(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: AppTheme.textSub.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(AppRadius.xs),
          ),
          clipBehavior: Clip.antiAlias,
          child: path != null
              ? Image.file(File(path), fit: BoxFit.cover)
              : Icon(
                  hasImage ? Icons.check_circle_outline : Icons.qr_code_2,
                  color: hasImage ? AppTheme.accent : AppTheme.textSub,
                ),
        ),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textMain)),
              const SizedBox(height: 2),
              Text(
                path != null
                    ? L10n.instance.t('i18n_289')
                    : (hasImage ? L10n.instance.t('i18n_287') : L10n.instance.t('i18n_446')),
                style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
              ),
            ],
          ),
        ),
        TextButton(
          onPressed: onPick,
          child: Text(hasImage ? L10n.instance.t('common_change') : L10n.instance.t('common_pick_image')),
        ),
      ],
    );
  }
}
