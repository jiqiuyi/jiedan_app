import 'dart:io';

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
  const PayoutAccountPage({super.key});

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
      _toast('图片过大或无法读取，请换一张更小的收款码截图');
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
      _toast('请填写收款人姓名');
      return;
    }
    if (name.length > 20) {
      _toast('姓名不能超过 20 个字');
      return;
    }
    if (account.isEmpty) {
      _toast('请填写收款账号');
      return;
    }
    if (account.length > 40) {
      _toast('收款账号不能超过 40 个字符');
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
    _toast('收款账户已保存');
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('返现收款账户')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 4, 4, 12),
            child: Text(
              '用于接收邀请返现打款，仅在申请打款时使用；与钱包余额提现相互独立。',
              style: TextStyle(fontSize: 12, color: AppTheme.textSub),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('收款方式',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textMain)),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _MethodChip(
                          label: '微信',
                          icon: Icons.chat_bubble_outline,
                          selected: _method == 'wechat',
                          onTap: () => setState(() => _method = 'wechat'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _MethodChip(
                          label: '支付宝',
                          icon: Icons.account_balance_wallet_outlined,
                          selected: _method == 'alipay',
                          onTap: () => setState(() => _method = 'alipay'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _nameCtrl,
                    maxLength: 20,
                    decoration: const InputDecoration(
                      labelText: '收款人姓名',
                      hintText: '用于打款核对，如「张三」',
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _accountCtrl,
                    maxLength: 40,
                    decoration: const InputDecoration(
                      labelText: '收款账号',
                      hintText: '微信号 / 支付宝账号',
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
                  const Text('收款码',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textMain)),
                  const SizedBox(height: 6),
                  const Text('选填，建议上传以便后台扫码转账；单张压缩后不超过 200KB。',
                      style:
                          TextStyle(fontSize: 12, color: AppTheme.textSub)),
                  const SizedBox(height: 12),
                  _QrRow(
                    label: '微信收款码',
                    hasImage: _hasWx,
                    previewPath: _wxPreview,
                    onPick: () => _pick(isWechat: true),
                  ),
                  const SizedBox(height: 12),
                  _QrRow(
                    label: '支付宝收款码',
                    hasImage: _hasAli,
                    previewPath: _aliPreview,
                    onPick: () => _pick(isWechat: false),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存收款账户'),
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
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.primary.withValues(alpha: 0.10)
              : Colors.transparent,
          border: Border.all(
            color: selected ? AppTheme.primary : AppTheme.textSub.withValues(alpha: 0.3),
          ),
          borderRadius: BorderRadius.circular(10),
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
            borderRadius: BorderRadius.circular(8),
          ),
          clipBehavior: Clip.antiAlias,
          child: path != null
              ? Image.file(File(path), fit: BoxFit.cover)
              : Icon(
                  hasImage ? Icons.check_circle_outline : Icons.qr_code_2,
                  color: hasImage ? AppTheme.accent : AppTheme.textSub,
                ),
        ),
        const SizedBox(width: 12),
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
                    ? '已选择新图片，保存后生效'
                    : (hasImage ? '已设置' : '未设置'),
                style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
              ),
            ],
          ),
        ),
        TextButton(
          onPressed: onPick,
          child: Text(hasImage ? '更换' : '选择图片'),
        ),
      ],
    );
  }
}
