import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 头像服务（v1.38.0）：支持用户从相册自定义「我的」页头像。
///
/// 采用「相册选择 → 拷贝到应用私有目录 → SharedPreferences 记住路径」的方式，
/// 头像仅保存在本机、不上传服务器，也不额外申请存储权限（走系统相册选择器）。
class AvatarService {
  AvatarService._();
  static final AvatarService instance = AvatarService._();

  static const String _key = 'profile_avatar_path';

  /// 当前头像本地路径；null 表示未设置（使用默认头像）。
  final ValueNotifier<String?> path = ValueNotifier<String?>(null);

  /// 启动时载入已保存的头像；文件已被清理时自动回落默认头像。
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final p = prefs.getString(_key);
    if (p != null && p.isNotEmpty && File(p).existsSync()) {
      path.value = p;
    } else {
      path.value = null;
    }
  }

  /// 从相册选择并设置为头像。
  /// 返回 null 表示用户取消选择；选择/拷贝过程中的异常向上抛出由调用方提示。
  Future<String?> pickFromGallery() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 720,
      maxHeight: 720,
      imageQuality: 88,
    );
    if (picked == null) return null;

    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/avatar');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final dest =
        '${dir.path}/avatar_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await File(picked.path).copy(dest);

    // 清理上一张头像文件，避免应用目录里的垃圾图片越积越多
    final old = path.value;
    if (old != null && old.isNotEmpty && old != dest) {
      try {
        final f = File(old);
        if (await f.exists()) await f.delete();
      } catch (_) {
        // 旧头像清理失败不影响新头像使用
      }
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, dest);
    path.value = dest;
    return dest;
  }

  /// 恢复默认头像（清空路径并删除本地图片）。
  Future<void> clear() async {
    final old = path.value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    path.value = null;
    if (old != null && old.isNotEmpty) {
      try {
        final f = File(old);
        if (await f.exists()) await f.delete();
      } catch (_) {
        // 忽略
      }
    }
  }
}
