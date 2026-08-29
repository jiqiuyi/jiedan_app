import 'package:flutter/foundation.dart';

import 'constants.dart';
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
  /// [inviteCode] 选填：邀请码（推广活动）
  /// 返回 null 表示成功，否则为错误提示文案
  Future<String?> register(
      String phone, String password, String nickname,
      {String inviteCode = ''}) async {
    final exist = await AppDb.instance.getUserByPhone(phone);
    if (exist != null) return '该手机号已注册，请直接登录';
    final now = DateTime.now().millisecondsSinceEpoch;
    await AppDb.instance.insertUser(UserAccount(
      phone: phone,
      passHash: hashPassword(phone, password),
      nickname: nickname,
      createdAt: now,
    ));
    // 推广活动：记住我来自谁的邀请（本地记录）
    if (inviteCode.trim().isNotEmpty) {
      await AppDb.instance.setMyInviterCode(inviteCode.trim().toUpperCase());
    }
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
  /// [months] 订阅时长（月）；[lifetime] 为 true 时一次性买断（proExpireAt=null 永久），
  /// 未登录时回落旧版本地标记（兼容老用户）。
  Future<void> activatePro({int months = 1, bool lifetime = false}) async {
    if (_currentUser != null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final int? expireAt = lifetime
          ? null
          : DateTime.fromMillisecondsSinceEpoch(now)
              .add(Duration(days: 30 * months))
              .millisecondsSinceEpoch;
      // 永久订阅需把 proExpireAt 置为 null，copyWith 的 null 表示保持原值，故直接构造
      final updated = UserAccount(
        id: _currentUser!.id,
        phone: _currentUser!.phone,
        passHash: _currentUser!.passHash,
        nickname: _currentUser!.nickname,
        createdAt: _currentUser!.createdAt,
        isPro: true,
        proExpireAt: expireAt,
      );
      await AppDb.instance.updateUser(updated);
      _currentUser = updated;
    } else {
      await AppDb.instance.setSetting('is_pro', '1');
    }
    _isPro = true;
    notifyListeners();
  }

  // ==================== 首月特惠（1 元，每人仅一次） ====================

  /// 当前账号是否已使用过「首月特惠 1 元」
  Future<bool> firstMonthOfferUsed() async {
    final uid = _currentUser?.id;
    if (uid == null) return false;
    final v = await AppDb.instance.getSetting('first_month_offer_used_$uid');
    return v == '1';
  }

  /// 标记当前账号已使用首月特惠（购买成功后调用）
  Future<void> markFirstMonthOfferUsed() async {
    final uid = _currentUser?.id;
    if (uid == null) return;
    await AppDb.instance
        .setSetting('first_month_offer_used_$uid', '1');
  }

  // ==================== 推广活动（本地 MVP 版） ====================

  /// 我的邀请码（无则自动生成并落库）
  Future<String> myInviteCode() async {
    final uid = _currentUser?.id;
    if (uid == null) return 'JD1000'; // 未登录兜底
    return AppDb.instance.getOrCreateInviteCode(uid);
  }

  /// 我的推广统计
  Future<InviteStats> inviteStats() async {
    final uid = _currentUser?.id;
    if (uid == null) {
      return const InviteStats(friendCount: 0, paidCount: 0, totalRebate: 0);
    }
    final list = await AppDb.instance.getInvitees(uid);
    final paidCount = list.where((e) => e.paid).length;
    final totalRebate =
        list.where((e) => e.paid).fold<double>(0, (s, e) => s + e.rebate);
    final bonusGranted = await AppDb.instance.inviteBonusGranted(uid);
    return InviteStats(
      friendCount: list.length,
      paidCount: paidCount,
      totalRebate: totalRebate,
      bonusGranted: bonusGranted,
    );
  }

  /// 登记一位被邀请人（推荐了好友）
  Future<void> addInvitee(String name, String phone) async {
    final uid = _currentUser?.id;
    if (uid == null) return;
    await AppDb.instance.insertInvitee(Invitee(
      inviterUserId: uid,
      name: name,
      phone: phone.trim(),
      invitedAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  /// 标记被邀请人真实付款开通 VIP，并按比例计算返现
  Future<void> markInviteePaid(int inviteeId, double payAmount) async {
    final uid = _currentUser?.id;
    if (uid == null) return;
    final list = await AppDb.instance.getInvitees(uid);
    final target = list.where((e) => e.id == inviteeId).firstOrNull;
    if (target == null) return;
    final rebate = payAmount * AppConfig.rebateRate;
    await AppDb.instance.updateInvitee(target.copyWith(
      paid: true,
      payAmount: payAmount,
      rebate: rebate,
      paidAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  /// 删除一条被邀请人记录
  Future<void> removeInvitee(int inviteeId) async {
    await AppDb.instance.deleteInvitee(inviteeId);
  }

  /// 满 N 位真实好友 → 免费送 VIP 1 个月（仅一次）。
  /// 返回是否本次触发了赠送。
  Future<bool> grantInviteVipIfEligible() async {
    final uid = _currentUser?.id;
    if (uid == null) return false;
    final granted = await AppDb.instance.inviteBonusGranted(uid);
    if (granted) return false;
    final list = await AppDb.instance.getInvitees(uid);
    if (list.length < AppConfig.inviteFreeVipFriends) return false;
    // 送 VIP 1 个月（叠加在当前到期时间之后）
    if (_currentUser != null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final base = _currentUser!.proExpireAt != null &&
              _currentUser!.proExpireAt! > now
          ? _currentUser!.proExpireAt!
          : now;
      final expireAt = DateTime.fromMillisecondsSinceEpoch(base)
          .add(Duration(days: 30 * AppConfig.inviteRewardMonths.toInt()))
          .millisecondsSinceEpoch;
      final updated = _currentUser!.copyWith(isPro: true, proExpireAt: expireAt);
      await AppDb.instance.updateUser(updated);
      _currentUser = updated;
    } else {
      await AppDb.instance.setSetting('is_pro', '1');
    }
    await AppDb.instance.markInviteBonusGranted(uid);
    _isPro = true;
    notifyListeners();
    return true;
  }
  /// 通知全局刷新（供页面层在数据变化后触发重建）
  void notifyChange() => notifyListeners();
}

/// 推广活动统计
class InviteStats {
  final int friendCount; // 已登记好友数
  final int paidCount; // 已真实付款人数
  final double totalRebate; // 累计返现金额
  final bool bonusGranted; // 是否已触发过"推荐送 VIP"

  const InviteStats({
    required this.friendCount,
    required this.paidCount,
    required this.totalRebate,
    this.bonusGranted = false,
  });
}
