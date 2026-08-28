import 'package:flutter/foundation.dart';

import 'database.dart';
import 'models.dart';

/// 全局应用状态（登录账号 + 订阅状态 + 数据变更通知）
class AppState extends ChangeNotifier {
  AppState._();
  static final AppState instance = AppState._();

  UserAccount? _currentUser;
  UserAccount? get currentUser => _currentUser;
  bool get loggedIn => _currentUser != null;

  bool _isPro = false;
  bool get isPro => _isPro;

  Future<void> load() async {
    _currentUser = await AppDb.instance.getCurrentUser();
    if (_currentUser != null) {
      // 订阅状态以账号为准（含到期校验）
      _isPro = _currentUser!.proActive;
    } else {
      // 兼容旧版本：无账号版本地 is_pro 标记
      final v = await AppDb.instance.getSetting('is_pro');
      _isPro = v == '1';
    }
    notifyListeners();
  }

  /// 注册：手机号 + 密码
  /// 返回 null 表示成功，否则为错误提示文案
  Future<String?> register(
      String phone, String password, String nickname) async {
    final exist = await AppDb.instance.getUserByPhone(phone);
    if (exist != null) return '该手机号已注册，请直接登录';
    final now = DateTime.now().millisecondsSinceEpoch;
    await AppDb.instance.insertUser(UserAccount(
      phone: phone,
      passHash: hashPassword(phone, password),
      nickname: nickname,
      createdAt: now,
    ));
    return null;
  }

  /// 登录：校验手机号 + 密码
  /// 返回 null 表示成功，否则为错误提示文案
  Future<String?> login(String phone, String password) async {
    final user = await AppDb.instance.getUserByPhone(phone);
    if (user == null) return '该手机号尚未注册';
    if (user.passHash != hashPassword(phone, password)) return '密码不正确，请重试';
    await AppDb.instance.setCurrentUser(user.id);
    _currentUser = user;
    _isPro = user.proActive;
    notifyListeners();
    return null;
  }

  Future<void> logout() async {
    await AppDb.instance.setCurrentUser(null);
    _currentUser = null;
    _isPro = false;
    notifyListeners();
  }

  /// 解锁专业版并绑定当前账号。
  /// [months] 订阅时长（月）；未登录时回落旧版本地标记（兼容老用户）。
  Future<void> activatePro({int months = 1}) async {
    if (_currentUser != null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final expireAt = DateTime.fromMillisecondsSinceEpoch(now)
          .add(Duration(days: 30 * months))
          .millisecondsSinceEpoch;
      final updated = _currentUser!.copyWith(isPro: true, proExpireAt: expireAt);
      await AppDb.instance.updateUser(updated);
      _currentUser = updated;
    } else {
      await AppDb.instance.setSetting('is_pro', '1');
    }
    _isPro = true;
    notifyListeners();
  }
}
