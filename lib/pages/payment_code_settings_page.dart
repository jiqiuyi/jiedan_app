import 'dart:io';
import '../l10n/l10n.dart';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app_state.dart';
import '../database.dart';
import '../theme.dart';
import '../widgets/app_ui.dart';

/// 收款设置：配置微信 / 支付宝个人收款码图片。
/// 配置后可在项目收款时一键"出示收款码"给客户扫码。
class PaymentCodeSettingsPage extends StatefulWidget {
const   PaymentCodeSettingsPage({super.key});

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
      SnackBar(content: Text(isWx ? L10n.instance.t('payment_code_wechat_updated') : L10n.instance.t('payment_code_alipay_updated'))),
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
      appBar: AppBar(title: Text(L10n.instance.t('payment_code_settings_title'))),
      body: _loading
          ? AppLoading()
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _QrCard(
                  title: L10n.instance.t('payment_code_wechat'),
                  subtitle: L10n.instance.t('payment_code_settings_page_customers_scan'),
                  icon: Icons.wechat,
                  iconColor: Color(0xFF07C160),
                  path: _wxPath,
                  onPick: () => _pickAndSave(isWx: true),
                  onClear: () => _clear(isWx: true),
                ),
                SizedBox(height: 16),
                _QrCard(
                  title: L10n.instance.t('payment_code_alipay'),
                  subtitle: L10n.instance.t('payment_code_settings_page_customers_scan_2'),
                  icon: Icons.account_balance_wallet_outlined,
                  iconColor: Color(0xFF1677FF),
                  path: _aliPath,
                  onPick: () => _pickAndSave(isWx: false),
                  onClear: () => _clear(isWx: false),
                ),
                SizedBox(height: 24),
                Text(
                  L10n.instance.t('i18n_114') +
                  L10n.instance.t('i18n_029') +
                  L10n.instance.t('i18n_032') +
                  L10n.instance.t('i18n_033') +
                  L10n.instance.t('i18n_036'),
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
const 
  _QrCard({
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
                style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(subtitle),
            trailing: TextButton(
              onPressed: onPick,
              child: Text(hasImage ? L10n.instance.t('common_change') : L10n.instance.t('payment_code_go_settings')),
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
                  errorBuilder: (_, _, _) => SizedBox(
                    height: 100,
                    child: Center(
                      child: Text(L10n.instance.t('common_image_load_failed'),
                          style: TextStyle(color: AppTheme.textSub)),
                    ),
                  ),
                ),
                Positioned(
                  right: 8,
                  top: 8,
                  child: IconButton.filledTonal(
                    onPressed: onClear,
                    tooltip: L10n.instance.t('payment_code_remove'),
                    icon: Icon(Icons.close, size: 18),
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
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add_photo_alternate_outlined,
                        color: AppTheme.textSub),
                    SizedBox(height: 6),
                    Text(L10n.instance.t('payment_code_pick'),
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
