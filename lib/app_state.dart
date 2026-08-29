import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'constants.dart';
import 'database.dart';
import 'models.dart';

/// 全局应用状态（登录账号 + 订阅状态 + 数据变更通知）
///
/// v1.6.0 起账号 / 订阅 / 推广数据以云端后端为权威（ApiClient）；
/// 本地 AppDb 的 users 表仅用于缓存当前会话展示与离线兜底，
/// 业务数据（customers/projects/payments）仍走本地 AppDb 不动。
class AppState extends ChangeNotifier {
  AppState._();
  static final AppState instance = AppState._();

  UserAccount? _currentUser;
  UserAccount? get currentUser => _currentUser;
  bool get loggedIn => _currentUser != null;

  bool _isPro = false;
  bool get isPro => _isPro;

  /// 云端 me() 返回的 user 缓存（订阅 / 首月特惠 / 邀请码 / 邀请人列表）
  Map<String, dynamic>? _cloudMe;
  Map<String, dynamic>? get cloudMe => _cloudMe;

  /// 是否已连上云端（成功拉取过 me 且拿到 token）
  bool _cloudReady = false;
  bool get cloudReady => _cloudReady;

  Future<void> load() async {
    await ApiClient.instance.loadToken();
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
    // 有 token 时后台拉云端数据刷新订阅/推广状态（失败不阻断本地使用）
    if (ApiClient.instance.token != null) {
      try {
        await refreshCloud();
      } catch (_) {
        // 云端暂不可用，保持本地缓存状态
      }
    }
  }

  /// 拉取云端 me 并刷新订阅 / 首月特惠 / 邀请数据，同步本地会话缓存
  /// 保存 me 返回的完整结构：user / inviteCode / invitees / rebateTotal / vipRewardGranted
  Future<void> refreshCloud() async {
    final json = await ApiClient.instance.me();
    final user = json['user'];
    if (user is! Map<String, dynamic>) return;
    _cloudMe = json;
    _cloudReady = true;
    await _syncLocalUserFromCloud(user);
    notifyListeners();
  }

  /// 把云端 user 同步到本地 users 表（作为会话缓存），并更新内存状态。
  /// 本地 id 由 SQLite 自增；云端字段映射到 UserAccount。
  Future<void> _syncLocalUserFromCloud(Map<String, dynamic> user) async {
    final phone = _str(user['phone']);
    final nickname = _str(user['nickname']);
    final isPro = _bool(user['isPro']);
    final expireRaw = user['proExpireAt'];
    final int? expireAt;
    if (expireRaw == null) {
      expireAt = null; // 永久
    } else if (expireRaw is num) {
      expireAt = expireRaw.toInt();
    } else if (expireRaw is String && expireRaw.isNotEmpty) {
      expireAt = int.tryParse(expireRaw);
    } else {
      expireAt = null;
    }

    UserAccount? local = await AppDb.instance.getUserByPhone(phone);
    if (local == null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      local = UserAccount(
        phone: phone,
        passHash: '',
        nickname: nickname,
        createdAt: now,
        isPro: isPro,
        proExpireAt: expireAt,
      );
      final newId = await AppDb.instance.insertUser(local);
      local = UserAccount(
        id: newId,
        phone: phone,
        passHash: '',
        nickname: nickname,
        createdAt: now,
        isPro: isPro,
        proExpireAt: expireAt,
      );
    } else {
      local = local.copyWith(nickname: nickname);
      if (isPro) {
        local = UserAccount(
          id: local.id,
          phone: local.phone,
          passHash: local.passHash,
          nickname: local.nickname,
          createdAt: local.createdAt,
          isPro: true,
          proExpireAt: expireAt,
        );
      }
    }
    await AppDb.instance.updateUser(local);
    await AppDb.instance.setCurrentUser(local.id);
    _currentUser = local;
    _isPro = isPro;
  }

  // ==================== 账号（云端） ====================

  /// 云端注册：手机号 + 密码 + 昵称 + 邀请码（选填）
  /// 返回 null 表示成功，否则为错误提示文案
  Future<String?> register(
      String phone, String password, String nickname,
      {String inviteCode = ''}) async {
    final Map<String, dynamic> json;
    try {
      json = await ApiClient.instance.register(
        phone: phone.trim(),
        password: password,
        nickname: nickname.trim(),
        inviteCode: inviteCode.trim(),
      );
    } on ApiException catch (e) {
      return e.message;
    } catch (_) {
      return '注册失败，请稍后重试';
    }
    final user = json['user'];
    if (user is Map<String, dynamic>) {
      await _syncLocalUserFromCloud(user);
    }
    // 拉取完整 me（邀请码 / 邀请人列表 / 返现）并标记云端就绪
    try {
      await refreshCloud();
    } catch (_) {
      // me 拉取失败不阻断登录成功
    }
    notifyListeners();
    return null;
  }

  /// 云端登录：校验手机号 + 密码
  /// 返回 null 表示成功，否则为错误提示文案
  Future<String?> login(String phone, String password) async {
    final Map<String, dynamic> json;
    try {
      json = await ApiClient.instance.login(
        phone: phone.trim(),
        password: password,
      );
    } on ApiException catch (e) {
      return e.message;
    } catch (_) {
      return '登录失败，请稍后重试';
    }
    final user = json['user'];
    if (user is Map<String, dynamic>) {
      await _syncLocalUserFromCloud(user);
    }
    // 拉取完整 me（邀请码 / 邀请人列表 / 返现）并标记云端就绪
    try {
      await refreshCloud();
    } catch (_) {
      // me 拉取失败不阻断登录成功
    }
    notifyListeners();
    return null;
  }

  Future<void> logout() async {
    await ApiClient.instance.clearToken();
    await AppDb.instance.setCurrentUser(null);
    _currentUser = null;
    _isPro = false;
    _cloudMe = null;
    _cloudReady = false;
    notifyListeners();
  }

  /// 本地 MVP 兜底：未连云端时直接解锁专业版（保留兼容）
  Future<void> activatePro({int months = 1, bool lifetime = false}) async {
    if (_currentUser != null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final int? expireAt = lifetime
          ? null
          : DateTime.fromMillisecondsSinceEpoch(now)
              .add(Duration(days: 30 * months))
              .millisecondsSinceEpoch;
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

  // ==================== 订阅 / 支付（云端订单） ====================

  /// 创建云端订单。
  /// [plan] 取值：firstMonth / month / year / forever
  /// 返回订单信息 { orderId, orderNo, amount, plan, qrPayload }；失败抛异常。
  Future<Map<String, dynamic>> createOrder(String plan) {
    return ApiClient.instance.createOrder(plan);
  }

  /// 模拟支付（MVP 演示通道），成功后刷新云端状态。
  Future<void> confirmMockPay(int orderId) async {
    await ApiClient.instance.mockPay(orderId);
    await refreshCloud();
  }

  // ==================== 首月特惠（1 元，每人仅一次） ====================

  /// 当前账号是否已使用过「首月特惠 1 元」
  Future<bool> firstMonthOfferUsed() async {
    if (_cloudReady && _cloudMe != null) {
      final u = _cloudMe!['user'];
      if (u is Map<String, dynamic> && u['firstMonthUsed'] != null) {
        return _bool(u['firstMonthUsed']);
      }
    }
    // 云端未就绪时回落本地旧标记（兼容）
    final uid = _currentUser?.id;
    if (uid == null) return false;
    final v = await AppDb.instance.getSetting('first_month_offer_used_$uid');
    return v == '1';
  }

  /// 标记当前账号已使用首月特惠（云端支付后自动标记，本地仅兜底）
  Future<void> markFirstMonthOfferUsed() async {
    final uid = _currentUser?.id;
    if (uid == null) return;
    await AppDb.instance.setSetting('first_month_offer_used_$uid', '1');
  }

  // ==================== 推广活动（云端自动核验） ====================

  /// 我的邀请码（云端生成，自动关联邀请关系）
  Future<String> myInviteCode() async {
    if (_cloudReady && _cloudMe != null) {
      final code = _str(_cloudMe!['inviteCode']);
      if (code.isNotEmpty) return code;
    }
    final uid = _currentUser?.id;
    if (uid == null) return 'JD1000'; // 未登录兜底
    return AppDb.instance.getOrCreateInviteCode(uid);
  }

  /// 我的推广统计（云端权威）
  Future<InviteStats> inviteStats() async {
    if (_cloudReady && _cloudMe != null) {
      final me = _cloudMe!;
      final invitees = _list(me['invitees']);
      final paidCount = invitees.where((e) => _bool(e['paid'])).length;
      return InviteStats(
        friendCount: invitees.length,
        paidCount: paidCount,
        totalRebate: _num(me['rebateTotal']),
        bonusGranted: _bool(me['vipRewardGranted']),
      );
    }
    // 云端未就绪时回落本地 MVP 统计
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

  /// 云端邀请人列表（注册时自动关联，无需手动登记）。
  /// 云端不可用时返回本地 MVP 记录。
  Future<List<Invitee>> cloudInvitees() async {
    if (_cloudReady && _cloudMe != null) {
      final invitees = _list(_cloudMe!['invitees']);
      return invitees.map((e) {
        final invitedAt = _intOrNow(e['invitedAt']);
        final paidAt = e['paidAt'] == null ? null : _intOrNow(e['paidAt']);
        return Invitee(
          id: e['id'] is num ? (e['id'] as num).toInt() : null,
          inviterUserId: 0,
          name: _str(e['nickname']),
          phone: _str(e['phone']),
          invitedAt: invitedAt,
          paid: _bool(e['paid']),
          payAmount: _num(e['payAmount']),
          // 后端 invitees 不返回 rebate，本地按返现比例结算展示
          rebate: _num(e['payAmount']) * AppConfig.rebateRate,
          paidAt: paidAt,
        );
      }).toList();
    }
    final uid = _currentUser?.id;
    if (uid == null) return [];
    return AppDb.instance.getInvitees(uid);
  }

  /// 云端模式下推广由注册关联 + 支付回调自动核验，不再需要手动登记。
  /// 以下方法保留仅用于兼容云端未就绪的本地 MVP 数据。
  Future<void> addInvitee(String name, String phone) async {
    if (_cloudReady) return; // 云端模式下禁止手动登记
    final uid = _currentUser?.id;
    if (uid == null) return;
    await AppDb.instance.insertInvitee(Invitee(
      inviterUserId: uid,
      name: name,
      phone: phone.trim(),
      invitedAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  Future<void> markInviteePaid(int inviteeId, double payAmount) async {
    if (_cloudReady) return;
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

  Future<void> removeInvitee(int inviteeId) async {
    if (_cloudReady) return;
    await AppDb.instance.deleteInvitee(inviteeId);
  }

  /// 云端模式下 VIP 赠送由后端在满 2 位有效好友时自动发放，无需手动触发。
  Future<bool> grantInviteVipIfEligible() async {
    if (_cloudReady) return false;
    final uid = _currentUser?.id;
    if (uid == null) return false;
    final granted = await AppDb.instance.inviteBonusGranted(uid);
    if (granted) return false;
    final list = await AppDb.instance.getInvitees(uid);
    if (list.length < AppConfig.inviteFreeVipFriends) return false;
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

  // ---------------- 云端字段安全取值 ----------------
  static String _str(dynamic v) => v == null ? '' : '$v';
  static bool _bool(dynamic v) =>
      v == true || (v is num && v != 0) || v == '1' || v == 'true';
  static double _num(dynamic v) =>
      v is num ? v.toDouble() : (double.tryParse('$v') ?? 0);
  static List<dynamic> _list(dynamic v) =>
      v is List ? v : (v is String && v.isNotEmpty ? (jsonDecode(v) as List?) ?? [] : []);
  static int _intOrNow(dynamic v) {
    if (v is num) return v.toInt();
    final parsed = int.tryParse('$v');
    return parsed ?? DateTime.now().millisecondsSinceEpoch;
  }
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
