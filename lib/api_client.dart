import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'constants.dart';

/// 云端后端异常（HTTP 非 2xx 或业务层错误）
class ApiException implements Exception {
  final String message;
  const ApiException(this.message);

  @override
  String toString() => message;
}

/// 云端鉴权失败（token 失效 / 未授权，HTTP 401）。
///
/// 与普通 [ApiException] 区分，业务层捕获后应清除本地会话并引导用户
/// 重新登录，而不是当作普通网络/服务错误提示。继承 [ApiException]，
/// 保证既有 `on ApiException` 捕获点仍能兜住。
class TokenInvalidException extends ApiException {
  const TokenInvalidException([super.message = '登录已失效，请重新登录']);
}

/// 云端 API 封装：账号 / 订阅 / 订单 / 推广数据。
/// 业务数据（客户/项目/收款）仍走本地 AppDb，不经过本类。
class ApiClient {
  ApiClient._() {
    _client = _buildClient();
  }
  static final ApiClient instance = ApiClient._();

  /// HTTP 客户端：默认走系统栈；apiBaseUrl 切到 HTTPS 时自动启用证书固定。
  late http.Client _client;

  /// token 持久化走 flutter_secure_storage（防破解 P2：关键凭据不进普通明文存储）
  static const _storage = FlutterSecureStorage();
  static const String _tokenKey = 'cloud_token';
  String? _token;
  String? get token => _token;

  /// 启动时从本地读取持久化的 token
  Future<void> loadToken() async {
    _token = await _storage.read(key: _tokenKey);
  }

  Future<void> _saveToken(String? t) async {
    _token = t;
    if (t == null) {
      await _storage.delete(key: _tokenKey);
    } else {
      await _storage.write(key: _tokenKey, value: t);
    }
  }

  /// 构建 HTTP 客户端：
  /// - 明文 http（默认）：使用系统默认 HttpClient；
  /// - https：启用证书固定（只信任内置的固定证书指纹），防止中间人重打包后
  ///   将请求指向伪造服务器。待正式 HTTPS 证书签发后，将
  ///   [AppConfig.apiBaseUrl] 切到 https 并更新 [AppConfig.pinnedCertSha256]。
  static http.Client _buildClient() {
    final base = AppConfig.apiBaseUrl;
    if (base.startsWith('https://')) {
      final sc = SecurityContext(withTrustedRoots: true);
      // 可选：从 assets 加载内置证书（未来证书签发后放入）
      // final bytes = rootBundle.load('assets/certs/server.pem'); ...
      final httpClient = HttpClient(context: sc)
        ..badCertificateCallback = (cert, host, port) {
          // 只信任内置的固定证书指纹（用 DER 编码计算 SHA-256）
          final sha = sha256.convert(cert.der).toString();
          final pinned = AppConfig.pinnedCertSha256;
          if (pinned.isEmpty) return false;
          return sha == pinned.toLowerCase();
        };
      return IOClient(httpClient);
    }
    return http.Client();
  }

  Future<Map<String, dynamic>> _call(
    String method,
    String path,
    Map<String, dynamic>? body, {
    Map<String, String>? query,
    // 仅限「已登录后才允许调用」的鉴权接口：true 时 HTTP 401 会被识别为
    // token 失效（TokenInvalidException），而非普通请求失败。登录/注册等
    // 无需携带 token 的接口保持 false，避免把「密码错误」误判为失效。
    bool authRequired = false,
  }) async {
    final uri = Uri.parse('${AppConfig.apiBaseUrl}$path').replace(
      queryParameters:
          (query == null || query.isEmpty) ? null : query,
    );
    final headers = <String, String>{
      'Content-Type': 'application/json',
      // 鉴权统一走 Authorization 头；真实支付接入后此处不变，仅替换 pay 接口
      if (_token != null && _token!.isNotEmpty)
        'Authorization': 'Bearer $_token',
    };
    late http.Response resp;
    try {
      if (method == 'GET') {
        resp = await _client.get(uri, headers: headers).timeout(
              const Duration(seconds: 12),
            );
      } else if (method == 'DELETE') {
        resp = await _client.delete(uri, headers: headers).timeout(
              const Duration(seconds: 12),
            );
      } else {
        resp = await _client
            .post(uri, headers: headers, body: jsonEncode(body ?? {}))
            .timeout(const Duration(seconds: 12));
      }
    } catch (_) {
      throw const ApiException('网络异常，请检查网络后重试');
    }
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw ApiException('服务异常（HTTP ${resp.statusCode}）');
    }
    if (resp.statusCode == 401 || json['ok'] == false) {
      // 鉴权接口的 401 独立为 token 失效分支，供上层触发登出 / 跳转登录。
      if (authRequired && resp.statusCode == 401) {
        throw const TokenInvalidException();
      }
      throw ApiException((json['error'] as String?) ?? '请求失败');
    }
    return json;
  }

  // ---------------- 账号 ----------------

  /// 注册并返回云端用户信息；[inviteCode] 选填（邀请码，自动绑定邀请关系）
  Future<Map<String, dynamic>> register({
    required String phone,
    required String password,
    String nickname = '',
    String inviteCode = '',
  }) async {
    final json = await _call('POST', '/api/register', {
      'phone': phone,
      'password': password,
      'nickname': nickname,
      'inviteCode': inviteCode,
    });
    await _saveToken(json['token'] as String?);
    return json;
  }

  Future<Map<String, dynamic>> login({
    required String phone,
    required String password,
  }) async {
    final json = await _call('POST', '/api/login', {
      'phone': phone,
      'password': password,
    });
    await _saveToken(json['token'] as String?);
    return json;
  }

  /// 拉取当前账号的云端信息（含订阅状态 / 邀请码 / 邀请人列表 / 返现）
  Future<Map<String, dynamic>> me() async {
    final t = _token;
    if (t == null) throw const ApiException('未登录');
    return _call('GET', '/api/me', null);
  }

  // ---------------- 订阅 / 支付 ----------------

  /// 创建订单，返回 { orderId, orderNo, amount, plan, qrPayload, qrcode }
  /// [plan] 取值：firstMonth / month / year / forever
  /// 【真实支付接入点】拿到商户号后，此处改为调用真实下单接口。
  Future<Map<String, dynamic>> createOrder(String plan) async {
    final json = await _call('POST', '/api/order', {
      'plan': plan,
    }, authRequired: true);
    return json;
  }

  /// 付款确认：客户点「是的」→ 订单标记为待确认（不直接开通）。
  /// 真正的开通由后端收到监听上报（金额 + 时间）匹配后才执行。
  Future<Map<String, dynamic>> confirmOrder(int orderId) async {
    final t = _token;
    if (t == null) throw const ApiException('未登录');
    return _call('POST', '/api/order/confirm', {'orderId': orderId},
        authRequired: true);
  }

  /// 监听上报：由通知解析侧（原生组件 / Flutter 兜底）上报到账金额 + 时间。
  /// [amount] 到账金额（元）；[ts] 到账时间戳（毫秒）；[source] 渠道标识
  /// （wechat / alipay / manual）；[deviceId] 设备标识（风控 / 拉黑用）。
  Future<Map<String, dynamic>> reportListener({
    required double amount,
    required int ts,
    required String source,
    String deviceId = '',
  }) async {
    final t = _token;
    if (t == null) throw const ApiException('未登录');
    return _call('POST', '/api/listener/report', {
      'amount': amount,
      'ts': ts,
      'source': source,
      'deviceId': deviceId,
    }, authRequired: true);
  }

  // ---------------- 管理员接口（role=admin 鉴权）---------------

  /// 待确认/抽查/已支付/全部订单：GET /api/admin/orders?status=...
  Future<List<Map<String, dynamic>>> adminOrders(String status) async {
    final t = _token;
    if (t == null) throw const ApiException('未登录');
    final json = await _call('GET', '/api/admin/orders', null,
        query: {'status': status}, authRequired: true);
    return (json['orders'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
  }

  /// 抽查单列表。
  Future<List<Map<String, dynamic>>> adminSpotchecks() async {
    final t = _token;
    if (t == null) throw const ApiException('未登录');
    final json = await _call('GET', '/api/admin/spotchecks', null,
        authRequired: true);
    return (json['spotchecks'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
  }

  /// 抽查复核：{ spotcheckId, action: approve | reject }
  Future<Map<String, dynamic>> adminSpotcheckReview(
      int spotcheckId, String action) async {
    final t = _token;
    if (t == null) throw const ApiException('未登录');
    return _call('POST', '/api/admin/spotcheck/review',
        {'spotcheckId': spotcheckId, 'action': action},
        authRequired: true);
  }

  /// 返现明细：{ details, totals }。
  Future<Map<String, dynamic>> adminRebates() async {
    final t = _token;
    if (t == null) throw const ApiException('未登录');
    return _call('GET', '/api/admin/rebates', null, authRequired: true);
  }

  /// 待打款：{ payouts, totalRebate }。
  Future<Map<String, dynamic>> adminPayouts() async {
    final t = _token;
    if (t == null) throw const ApiException('未登录');
    return _call('GET', '/api/admin/payouts', null, authRequired: true);
  }

  /// 收款码配置：GET 查询 / POST 保存 { wechat, alipay }。
  Future<Map<String, dynamic>> adminQrcode(
      {String? wechat, String? alipay}) async {
    final t = _token;
    if (t == null) throw const ApiException('未登录');
    return _call(
        'POST', '/api/admin/qrcode', {'wechat': wechat, 'alipay': alipay},
        authRequired: true);
  }

  /// 读取当前收款码配置（管理后台回显用）。
  Future<Map<String, dynamic>> adminQrcodeGet() async {
    final t = _token;
    if (t == null) throw const ApiException('未登录');
    return _call('GET', '/api/admin/qrcode', null, authRequired: true);
  }

  /// 监听状态汇总。
  Future<Map<String, dynamic>> adminListener() async {
    final t = _token;
    if (t == null) throw const ApiException('未登录');
    return _call('GET', '/api/admin/listener', null, authRequired: true);
  }

  /// 吊销专业版权限。
  Future<Map<String, dynamic>> adminRevoke(int userId) async {
    final t = _token;
    if (t == null) throw const ApiException('未登录');
    return _call('POST', '/api/admin/revoke', {'userId': userId},
        authRequired: true);
  }

  /// 设备拉黑。
  Future<Map<String, dynamic>> adminBlock(
      String deviceId, String note) async {
    final t = _token;
    if (t == null) throw const ApiException('未登录');
    return _call('POST', '/api/admin/block',
        {'deviceId': deviceId, 'note': note}, authRequired: true);
  }

  /// 管理操作日志。
  Future<List<Map<String, dynamic>>> adminLogs() async {
    final t = _token;
    if (t == null) throw const ApiException('未登录');
    final json = await _call('GET', '/api/admin/logs', null,
        authRequired: true);
    return (json['logs'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
  }

  /// 当前账号是否为管理员（role == admin）。
  Future<bool> isAdmin() async {
    try {
      final data = await me();
      return (data['role'] ?? 'user').toString() == 'admin';
    } on ApiException {
      return false;
    }
  }

  // ---------------- 业务数据同步（v1.14.0，存储方式三选一）----------------

  /// 推送本地增量到云端。返回 { ok, serverTs }。
  /// [tables]：{ 表名: [行...] }，每行含数据库字段 + _ts（修改时间戳）。
  /// 服务器按行合并，冲突以服务器最新为准；serverTs 用于增量拉取水位。
  Future<Map<String, dynamic>> pushSync(Map<String, dynamic> tables) async {
    final t = _token;
    if (t == null) throw const ApiException('未登录');
    return _call('POST', '/api/sync/push', {'tables': tables},
        authRequired: true);
  }

  /// 增量拉取云端数据。返回 { ok, serverTs, tables }。
  /// [since] 为上次成功同步的服务器时间戳（0 = 全量）。
  Future<Map<String, dynamic>> pullSync(int since) async {
    final t = _token;
    if (t == null) throw const ApiException('未登录');
    return _call('GET', '/api/sync/pull', null,
        query: {'since': '$since'}, authRequired: true);
  }

  /// 双向合并：推送本地全部数据，并返回服务器权威快照（含服务器数据与本次
  /// 推送采纳后的结果）。用于「本地+服务器」首启全量 + 登录/启动合并。
  Future<Map<String, dynamic>> mergeSync(Map<String, dynamic> tables) async {
    final t = _token;
    if (t == null) throw const ApiException('未登录');
    return _call('POST', '/api/sync/merge', {'tables': tables},
        authRequired: true);
  }

  /// 删除本账号在服务器上的全部同步数据（存储方式切回「仅本地」时可选项）。
  /// 返回 { ok, deletedRows, uid }；不影响其他用户的命名空间。
  Future<Map<String, dynamic>> deleteServerSync() async {
    final t = _token;
    if (t == null) throw const ApiException('未登录');
    return _call('DELETE', '/api/sync/all', null, authRequired: true);
  }

  // ---------------- 在线意见反馈（v1.15.0）----------------

  /// 在线提交意见反馈到服务器。返回 { ok, feedbackId }。
  /// [type]：bug / suggestion / other；[content] 必填，[contact] 选填。
  Future<Map<String, dynamic>> submitFeedback({
    required String type,
    required String content,
    String contact = '',
  }) async {
    final t = _token;
    if (t == null) throw const ApiException('未登录');
    return _call('POST', '/api/feedback', {
      'type': type,
      'content': content,
      'contact': contact,
    }, authRequired: true);
  }

  /// 拉取当前用户在服务器上的全部反馈（最新在前）。
  /// 返回 { ok, count, feedbacks: [...] }，每项含 type/content/contact/
  /// createdAt/reply/repliedAt，reply 为作者回复（未回复时为 null）。
  Future<Map<String, dynamic>> fetchMyFeedbacks() async {
    final t = _token;
    if (t == null) throw const ApiException('未登录');
    return _call('GET', '/api/feedback/mine', null, authRequired: true);
  }

  /// 退出登录：清除本地 token
  Future<void> clearToken() => _saveToken(null);
}
