import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants.dart';
import 'error_reporter.dart';

/// 远端版本清单字段
class UpdateInfo {
  final String version; // 版本名，如 1.35.0
  final int build; // 构建号
  final List<String> changelog; // 更新内容
  final String url; // 安装包地址
  final bool force; // 是否强制更新

  const UpdateInfo({
    required this.version,
    required this.build,
    required this.changelog,
    required this.url,
    required this.force,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    final rawLog = json['changelog'];
    return UpdateInfo(
      version: (json['version'] ?? '').toString(),
      build: (json['build'] as num?)?.toInt() ?? 0,
      changelog: rawLog is List
          ? rawLog.map((e) => e.toString()).toList()
          : const <String>[],
      url: (json['url'] ?? '').toString(),
      force: json['force'] == true,
    );
  }
}

/// 版本更新检查：启动时静默检查一次（非强制、可忽略）；设置页可手动检查。
class UpdateService {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  // 用户选择“以后再说”的版本号，同一版本不再自动弹出
  static const String _skipKey = 'update_skip_version';
  // 最近一次自动检查时间，避免短时间重复请求
  static const String _lastCheckKey = 'update_last_check_at';
  static const Duration _autoInterval = Duration(hours: 4);

  /// 拉取远端清单并与本地版本比较；无新版 / 请求失败均返回 null。
  Future<UpdateInfo?> _fetchLatest({bool ignoreInterval = false}) async {
    final prefs = await SharedPreferences.getInstance();
    if (!ignoreInterval) {
      final last = prefs.getInt(_lastCheckKey) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - last < _autoInterval.inMilliseconds) return null;
    }

    try {
      final resp = await http
          .get(Uri.parse(AppConfig.updateManifestUrl))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      // 仅在成功拿到清单后才记录检查时间：请求失败不更新，下次启动可自动重试，
      // 避免一次断网把自动检查「锁」在间隔期内不再尝试。
      await prefs.setInt(
          _lastCheckKey, DateTime.now().millisecondsSinceEpoch);
      final info = UpdateInfo.fromJson(
          jsonDecode(resp.body) as Map<String, dynamic>);
      if (info.version.isEmpty || info.url.isEmpty) return null;

      final local = await PackageInfo.fromPlatform();
      final localBuild = int.tryParse(local.buildNumber) ?? 0;
      return _isNewer(info, local.version, localBuild) ? info : null;
    } catch (_) {
      // 断网 / 超时 / 解析失败：检查更新不应影响正常使用
      return null;
    }
  }

  /// 启动后自动检查：发现新版且未被跳过则弹窗（非强制，可关闭）。
  Future<void> checkAuto(BuildContext context) async {
    final info = await _fetchLatest();
    if (info == null || !context.mounted) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_skipKey) == info.version) return;
    if (!context.mounted) return;
    _showDialog(context, info);
  }

  /// 手动检查：带 loading，并明确反馈“已是最新版本”。
  Future<void> checkManual(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5)),
                SizedBox(width: 14),
                Text('正在检查更新…'),
              ],
            ),
          ),
        ),
      ),
    );
    final info = await _fetchLatest(ignoreInterval: true);
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // 关闭 loading

    if (info == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('当前已是最新版本')),
      );
      return;
    }
    if (!context.mounted) return;
    _showDialog(context, info);
  }

  void _showDialog(BuildContext context, UpdateInfo info) {
    showDialog<void>(
      context: context,
      barrierDismissible: !info.force,
      builder: (ctx) {
        return AlertDialog(
          title: Text('发现新版本 v${info.version}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (info.changelog.isEmpty)
                const Text('优化了一些体验问题，建议更新。')
              else ...[
                const Text('更新内容：'),
                const SizedBox(height: 6),
                ...info.changelog.map((e) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text('· $e'),
                    )),
              ],
            ],
          ),
          actions: [
            // 非强制更新才提供“以后再说”
            if (!info.force)
              TextButton(
                onPressed: () async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString(_skipKey, info.version);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: const Text('以后再说'),
              ),
            FilledButton.icon(
              onPressed: () {
                _openDownload(info.url);
                Navigator.pop(ctx);
              },
              icon: const Icon(Icons.download_outlined, size: 18),
              label: const Text('立即更新'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openDownload(String url) async {
    try {
      final ok = await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
      if (!ok) {
        appMessengerKey.currentState?.showSnackBar(
          const SnackBar(content: Text('无法打开下载地址，请稍后重试')),
        );
      }
    } catch (_) {
      appMessengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('无法打开下载地址')),
      );
    }
  }

  /// 远端是否比本地新：先比版本名各段，相同再比构建号。
  bool _isNewer(UpdateInfo info, String localVersion, int localBuild) {
    final cmp = _compareVersion(info.version, localVersion);
    if (cmp != 0) return cmp > 0;
    return info.build > localBuild;
  }

  int _compareVersion(String a, String b) {
    List<int> parts(String s) => s
        .split('.')
        .map((e) => int.tryParse(e.trim()) ?? 0)
        .toList();
    final pa = parts(a);
    final pb = parts(b);
    final n = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < n; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x > y ? 1 : -1;
    }
    return 0;
  }
}
