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
    Map<String, dynamic>? body,
  ) async {
    final uri = Uri.parse('${AppConfig.apiBaseUrl}$path');
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

  /// 创建订单，返回 { orderId, orderNo, amount, plan, qrPayload }
  /// [plan] 取值：firstMonth / month / year / forever
  /// 【真实支付接入点】拿到商户号后，此处改为调用真实下单接口。
  Future<Map<String, dynamic>> createOrder(String plan) async {
    final json = await _call('POST', '/api/order', {
      'plan': plan,
    });
    return json;
  }

  /// 退出登录：清除本地 token
  Future<void> clearToken() => _saveToken(null);
}
