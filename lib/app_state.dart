import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' show Hmac, sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_client.dart';
import 'constants.dart';
import 'database.dart';
import 'models.dart';
import 'services/sync_service.dart';

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

  /// 当前账号是否为管理员（云端 role=admin；普通用户恒为 false）。
  bool get isCurrentAdmin =>
      (_cloudMe?['role'] ?? 'user').toString() == 'admin';

  /// 是否已连上云端（成功拉取过 me 且拿到 token）
  bool _cloudReady = false;
  bool get cloudReady => _cloudReady;

  Future<void> load() async {
    await ApiClient.instance.loadToken();
    _currentUser = await AppDb.instance.getCurrentUser();
    // 防破解加固（P0）：VIP 判定以云端为准，本地 SQLite 的 is_pro 仅作展示缓存，
    // 不再作为 VIP 判定依据。未登录或云端不可用时一律按免费版处理（只读降级，
    // 绝不信任本地标记）。
    _isPro = false;
    notifyListeners();
    // 有 token 时拉云端数据刷新订阅/推广状态；云端不可用时回退本地 VIP 缓存（第15批过渡期）
    if (ApiClient.instance.token != null) {
      try {
        await refreshCloud();
      } catch (_) {
        // 云端暂不可用：读取本地 VIP 缓存维持订阅体验（该缓存由最近一次云端 me 成功写入）。
        // 缓存缺失或已过期则按免费版处理（只读降级，不信任默认可写标记）。
        _isPro = await _localVipActive();
        notifyListeners();
      }
    } else {
      // 未登录（无 token）：若存在本地会话账号则回退其 VIP 缓存，否则按免费版处理
      _isPro = await _localVipActive();
      notifyListeners();
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
      // 防破解加固（P0）：云端 isPro 无论 true/false 一律覆盖本地缓存，
      // 本地 users 表仅作会话展示缓存，VIP 判定只认云端。
      local = local.copyWith(nickname: nickname, isPro: isPro, proExpireAt: expireAt);
    }
    await AppDb.instance.updateUser(local);
    await AppDb.instance.setCurrentUser(local.id);
    _currentUser = local;
    // 第15批（过渡期）：云端 me 成功即写入本地 VIP 缓存（按手机号隔离），
    // 供云端不可用时离线续订；实时判定仍以云端 isPro 为权威。
    await _writeLocalVipCache(phone, isPro, expireAt);
    // 防破解加固：VIP 判定纯云端权威，本地不叠加任何解锁标记。
    _isPro = _vipActive(isPro, expireAt);
  }

  // ==================== 本地 VIP 缓存（第16批防白嫖加固） ====================
  // VIP 判定源（第15批）：云端 isPro 权威 → 成功即写本地缓存 → 云端不可用读本地缓存。
  // 缓存仅在云端 me 成功时写入，避免离线期间被篡改。
  //
  // 第16批（断网破解加固）：缓存由「明文 JSON」升级为 v2 签名格式——
  //   1) HMAC-SHA256 签名：签名密钥为设备级随机密钥（存 flutter_secure_storage，
  //      与 token 同级保护，不进 SQLite），任何篡改都会导致验签失败直接降级；
  //   2) 手机号参与签名：防止跨账号复制缓存；
  //   3) 7 天离线宽限期：缓存自带写入时间 ts，离线超过 7 天即作废降级，
  //      杜绝「断网 + 改库」永久白嫖；
  //   4) 旧版 v1 明文缓存一律不信任（升级后首次云端 me 成功即重写 v2）。
  // 局限说明：宽限期依赖本地时钟，改系统时间可延长（纯本地无法根治，
  //          待 HTTPS 联调后由服务端时间戳/请求签名兜底）。
  static const String localVipCachePrefix = 'local_vip_cache_';

  /// v2 缓存签名密钥：设备级随机密钥，持久化于 flutter_secure_storage。
  static const _vipCacheKeyStorage = FlutterSecureStorage();
  static const _vipCacheKeyName = 'vip_cache_hmac_key_v2';
  static const _vipCacheMaxOffline = Duration(days: 7);

  /// 获取（或首次生成）设备级缓存签名密钥。密钥只在 secure storage，不进 SQLite。
  Future<String> _vipCacheDeviceKey() async {
    final existed = await _vipCacheKeyStorage.read(key: _vipCacheKeyName);
    if (existed != null && existed.isNotEmpty) return existed;
    final rnd = Random.secure();
    final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
    final key = base64Encode(bytes);
    await _vipCacheKeyStorage.write(key: _vipCacheKeyName, value: key);
    return key;
  }

  /// 规范化签名原文：手机号 + 写入时间 + isPro + 到期时间，改任一字段验签必败。
  static String _vipCacheSigInput(
      String phone, int ts, bool isPro, int? expireAt) {
    return '$phone\n$ts\n$isPro\n${expireAt ?? 0}';
  }

  /// 云端 me 成功后把 isPro / proExpireAt 落入本地缓存（按手机号隔离，v2 签名格式）。
  Future<void> _writeLocalVipCache(
      String phone, bool isPro, int? expireAt) async {
    if (phone.isEmpty) return;
    final ts = DateTime.now().millisecondsSinceEpoch;
    final key = await _vipCacheDeviceKey();
    final sig = Hmac(sha256, utf8.encode(key))
        .convert(utf8.encode(_vipCacheSigInput(phone, ts, isPro, expireAt)))
        .toString();
    await AppDb.instance.setSetting(
      localVipCachePrefix + phone,
      jsonEncode({
        'v': 2,
        'ts': ts,
        'data': {'isPro': isPro, 'proExpireAt': expireAt},
        'sig': sig,
      }),
    );
  }

  /// 读取并判断本地 VIP 缓存是否仍有效（签名有效 + 未过期 + 未超 7 天离线宽限）。
  /// 缺失 / 无签名旧格式 / 篡改 / 已过期 / 超宽限期一律返回 false（只读降级）。
  Future<bool> _localVipActive() async {
    final phone = _currentUser?.phone ?? '';
    if (phone.isEmpty) return false;
    final raw = await AppDb.instance.getSetting(localVipCachePrefix + phone);
    if (raw == null || raw.isEmpty) return false;
    final Map<String, dynamic> m;
    try {
      m = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return false;
    }
    // 仅信任 v2 签名格式：v1 明文缓存是白嫖漏洞源，升级即作废（下次 me 成功会重写）。
    if (m['v'] != 2) return false;
    final ts = m['ts'];
    final sig = m['sig'];
    final data = m['data'];
    if (ts is! num || sig is! String || data is! Map<String, dynamic>) {
      return false;
    }
    final tsMs = ts.toInt();
    // 7 天离线宽限期：超期降级，禁止长期断网白嫖。
    if (DateTime.now().millisecondsSinceEpoch - tsMs >
        _vipCacheMaxOffline.inMilliseconds) {
      return false;
    }
    // 验签：任一字段被篡改（含改系统时间前挪动 ts）都会验签失败。
    final isPro = data['isPro'];
    final expireRaw = data['proExpireAt'];
    final expire = expireRaw is num
        ? expireRaw.toInt()
        : (int.tryParse('$expireRaw') ?? 0);
    final key = await _vipCacheDeviceKey();
    final expect = Hmac(sha256, utf8.encode(key))
        .convert(utf8.encode(
            _vipCacheSigInput(phone, tsMs, isPro == true, expire)))
        .toString();
    if (expect != sig.toLowerCase()) return false;
    if (isPro != true) return false;
    if (expire <= 0) return true; // 永久订阅（签名有效 + 未超宽限期）
    return expire > DateTime.now().millisecondsSinceEpoch;
  }

  /// isPro 且未过期则视为 VIP 有效（null / 非正到期时间视为永久）。
  static bool _vipActive(bool isPro, int? expireAt) {
    if (!isPro) return false;
    if (expireAt == null || expireAt <= 0) return true;
    return expireAt > DateTime.now().millisecondsSinceEpoch;
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
    // 数据存储方式（v1.14.0）：含服务器模式时，注册成功后立即拉取合并云端业务数据。
    if (SyncService.instance.canSync) {
      unawaited(SyncService.instance.syncOnStart());
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
    // 数据存储方式（v1.14.0）：含服务器模式时，登录成功后立即拉取合并云端业务数据。
    if (SyncService.instance.canSync) {
      unawaited(SyncService.instance.syncOnStart());
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

  /// 强制清除本地会话（云端 token + 本地用户缓存）。
  /// 防破解加固（P2）：备份导入后调用，要求用户重新登录，
  /// VIP 状态以云端 me() 为准重新覆盖，避免被篡改备份里的 is_pro 误导。
  Future<void> clearSession() async {
    await ApiClient.instance.clearToken();
    await AppDb.instance.setCurrentUser(null);
    _currentUser = null;
    _isPro = false;
    _cloudMe = null;
    _cloudReady = false;
    notifyListeners();
  }

  // ==================== 订阅 / 支付（云端订单） ====================

  /// 创建云端订单。
  /// [plan] 取值：firstMonth / month / year / forever
  /// 返回订单信息 { orderId, orderNo, amount, plan, qrPayload }；失败抛异常。
  Future<Map<String, dynamic>> createOrder(String plan) {
    return ApiClient.instance.createOrder(plan);
  }

  // ==================== 兑换码（防破解修复：服务端核销） ====================

  /// 兑换码核销（服务端权威）：提交码后由 POST /api/redeem 校验码的有效性、
  /// 幂等与次数限制，成功则云端下发 isPro / 订阅信息并同步本地。
  /// 客户端不硬编码任何码、不做本地判断。返回 null 表示成功，否则为错误提示文案。
  Future<String?> redeemVipCode(String code) async {
    final c = code.trim();
    if (c.isEmpty) return '请输入兑换码';
    if (!loggedIn) return '请先登录';
    try {
      final json = await ApiClient.instance.redeemCode(c);
      final user = json['user'];
      if (user is Map<String, dynamic>) {
        await _syncLocalUserFromCloud(user);
        notifyListeners();
        return null;
      }
      return '兑换成功，请稍后重试';
    } on ApiException catch (e) {
      return e.message;
    }
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
        totalRebate: (_num(me['rebateTotal']) * 100).round(),
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
        list.where((e) => e.paid).fold<int>(0, (s, e) => s + e.rebate);
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
          payAmount: (_num(e['payAmount']) * 100).round(),
          // 后端 invitees 不返回 rebate，本地按返现比例结算展示
          rebate: (_num(e['payAmount']) * AppConfig.rebateRate * 100).round(),
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

  Future<void> markInviteePaid(int inviteeId, int payAmountFen) async {
    if (_cloudReady) return;
    final uid = _currentUser?.id;
    if (uid == null) return;
    final list = await AppDb.instance.getInvitees(uid);
    final target = list.where((e) => e.id == inviteeId).firstOrNull;
    if (target == null) return;
    final rebate = (payAmountFen * AppConfig.rebateRate).round();
    await AppDb.instance.updateInvitee(target.copyWith(
      paid: true,
      payAmount: payAmountFen,
      rebate: rebate,
      paidAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  Future<void> removeInvitee(int inviteeId) async {
    if (_cloudReady) return;
    await AppDb.instance.deleteInvitee(inviteeId);
  }

  /// 第15批过渡期：本地自动核验满 [AppConfig.inviteFreeVipFriends] 位已付款好友，
  /// 本地发放 [AppConfig.inviteRewardMonths] 个月 VIP，并落 subscription_orders
  /// （channel=invite，synced=0 预留云端同步字段）。已发放过则不重复触发。
  /// 过渡期限制：仅本地发放，卸载重装 / 换机后丢失；云端就绪时由服务端发放，本地不重复。
  /// 返回 true 表示本次触发了赠送。
  Future<bool> grantInviteVipIfEligible() async {
    final uid = _currentUser?.id;
    final phone = _currentUser?.phone ?? '';
    if (uid == null) return false;
    if (_cloudReady) return false; // 云端权威发放，本地不重复
    if (await AppDb.instance.inviteBonusGranted(uid)) return false;
    final list = await AppDb.instance.getInvitees(uid);
    final paidCount = list.where((e) => e.paid).length;
    if (paidCount < AppConfig.inviteFreeVipFriends) return false;
    // 本地发放 N 个月 VIP：自当前时间起算
    final expireAt = DateTime.now()
        .add(Duration(days: 30 * AppConfig.inviteRewardMonths.toInt()))
        .millisecondsSinceEpoch;
    final updated = _currentUser!.copyWith(isPro: true, proExpireAt: expireAt);
    await AppDb.instance.updateUser(updated);
    await _writeLocalVipCache(phone, true, expireAt);
    _currentUser = updated;
    _isPro = true;
    await AppDb.instance.markInviteBonusGranted(uid);
    // 落订阅订单，预留云端同步字段（synced=0，ref_no 记邀请达标批次）
    await AppDb.instance.insertSubscriptionOrder(
      userId: uid,
      phone: phone,
      planKey: 'invite_bonus',
      planName: '邀请送月',
      amount: 0,
      channel: AppDb.subChannelInvite,
      status: AppDb.subStatusGranted,
      refNo: 'invite-${AppConfig.inviteFreeVipFriends}p',
    );
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
  final int totalRebate; // 累计返现金额（分，v9 统一改分）
  final bool bonusGranted; // 是否已触发过"推荐送 VIP"

  const InviteStats({
    required this.friendCount,
    required this.paidCount,
    required this.totalRebate,
    this.bonusGranted = false,
  });
}
