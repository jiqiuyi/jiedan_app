import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app_state.dart';
import '../database.dart';
import '../theme.dart';

/// 收款设置：配置微信 / 支付宝个人收款码图片。
/// 配置后可在项目收款时一键"出示收款码"给客户扫码。
class PaymentCodeSettingsPage extends StatefulWidget {
  const PaymentCodeSettingsPage({super.key});

  @override
  State<PaymentCodeSettingsPage> createState() =>
      _PaymentCodeSettingsPageState();
}

class _PaymentCodeSettingsPageState extends State<PaymentCodeSettingsPage> {
  String? _wxPath;
  String? _aliPath;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = AppDb.instance;
    final wx = await db.getWxQrPath();
    final ali = await db.getAliQrPath();
    if (!mounted) return;
    setState(() {
      _wxPath = wx;
      _aliPath = ali;
      _loading = false;
    });
  }

  Future<void> _pickAndSave({required bool isWx}) async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1200,
      maxHeight: 1200,
      imageQuality: 90,
    );
    if (picked == null) return;
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory(p.join(dir.path, 'qr_codes'));
    if (!await folder.exists()) await folder.create(recursive: true);
    final destFile = File(p.join(folder.path, isWx ? 'wx_qr.png' : 'ali_qr.png'));
    await File(picked.path).copy(destFile.path);

    final db = AppDb.instance;
    if (isWx) {
      await db.setWxQrPath(destFile.path);
    } else {
      await db.setAliQrPath(destFile.path);
    }
    AppState.instance.notifyChange(); // 通知收款页刷新
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(isWx ? '微信收款码已更新' : '支付宝收款码已更新')),
    );
  }

  Future<void> _clear({required bool isWx}) async {
    final db = AppDb.instance;
    if (isWx) {
      await db.setWxQrPath('');
    } else {
      await db.setAliQrPath('');
    }
    AppState.instance.notifyChange();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('收款设置')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _QrCard(
                  title: '微信收款码',
                  subtitle: '客户扫码后用微信付款',
                  icon: Icons.wechat,
                  iconColor: const Color(0xFF07C160),
                  path: _wxPath,
                  onPick: () => _pickAndSave(isWx: true),
                  onClear: () => _clear(isWx: true),
                ),
                const SizedBox(height: 16),
                _QrCard(
                  title: '支付宝收款码',
                  subtitle: '客户扫码后用支付宝付款',
                  icon: Icons.account_balance_wallet_outlined,
                  iconColor: const Color(0xFF1677FF),
                  path: _aliPath,
                  onPick: () => _pickAndSave(isWx: false),
                  onClear: () => _clear(isWx: false),
                ),
                const SizedBox(height: 24),
                const Text(
                  '使用说明：\n'
                  '1. 先在微信/支付宝 App 里打开「收款码」，截图保存到相册；\n'
                  '2. 点上方卡片从相册选择该截图；\n'
                  '3. 收款时在项目页点「出示收款码」，客户扫码付款即可；\n'
                  '4. 到账后回来点「登记收款」入账。',
                  style: TextStyle(fontSize: 13, color: AppTheme.textSub),
                ),
              ],
            ),
    );
  }
}

class _QrCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color iconColor;
  final String? path;
  final VoidCallback onPick;
  final VoidCallback onClear;

  const _QrCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.iconColor,
    required this.path,
    required this.onPick,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final hasImage = path != null && path!.isNotEmpty;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ListTile(
            leading: Icon(icon, color: iconColor, size: 32),
            title: Text(title,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(subtitle),
            trailing: TextButton(
              onPressed: onPick,
              child: Text(hasImage ? '更换' : '去设置'),
            ),
          ),
          if (hasImage)
            Stack(
              children: [
                Image.file(
                  File(path!),
                  height: 220,
                  width: double.infinity,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const SizedBox(
                    height: 100,
                    child: Center(
                      child: Text('图片加载失败',
                          style: TextStyle(color: AppTheme.textSub)),
                    ),
                  ),
                ),
                Positioned(
                  right: 8,
                  top: 8,
                  child: IconButton.filledTonal(
                    onPressed: onClear,
                    tooltip: '移除收款码',
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ),
              ],
            )
          else
            InkWell(
              onTap: onPick,
              child: Container(
                height: 100,
                alignment: Alignment.center,
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add_photo_alternate_outlined,
                        color: AppTheme.textSub),
                    SizedBox(height: 6),
                    Text('从相册选择收款码截图',
                        style: TextStyle(
                            fontSize: 13, color: AppTheme.textSub)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
