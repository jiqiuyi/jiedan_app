import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

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
  ApiClient._();
  static final ApiClient instance = ApiClient._();

  static const String _tokenKey = 'cloud_token';
  String? _token;
  String? get token => _token;

  /// 启动时从本地读取持久化的 token
  Future<void> loadToken() async {
    final sp = await SharedPreferences.getInstance();
    _token = sp.getString(_tokenKey);
  }

  Future<void> _saveToken(String? t) async {
    _token = t;
    final sp = await SharedPreferences.getInstance();
    if (t == null) {
      await sp.remove(_tokenKey);
    } else {
      await sp.setString(_tokenKey, t);
    }
  }

  Future<Map<String, dynamic>> _call(
    String method,
    String path,
    Map<String, dynamic>? body,
  ) async {
    final uri = Uri.parse('${AppConfig.apiBaseUrl}$path');
    final headers = <String, String>{'Content-Type': 'application/json'};
    late http.Response resp;
    try {
      if (method == 'GET') {
        resp = await http.get(uri, headers: headers).timeout(
              const Duration(seconds: 12),
            );
      } else {
        resp = await http
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
    return _call('GET', '/api/me?token=$t', null);
  }

  // ---------------- 订阅 / 支付 ----------------

  /// 创建订单，返回 { orderId, orderNo, amount, plan, qrPayload }
  /// [plan] 取值：firstMonth / month / year / twoYear / forever
  Future<Map<String, dynamic>> createOrder(String plan) async {
    final json = await _call('POST', '/api/order', {
      'token': _token,
      'plan': plan,
    });
    return json;
  }

  /// 模拟支付回调（MVP：真实支付接入前的演示通道），支付成功后后端完成
  /// 开通专业版 + 邀请人返现 + 满员送 VIP 的结算。
  Future<Map<String, dynamic>> mockPay(int orderId) async {
    return _call('POST', '/api/pay/simulate', {
      'token': _token,
      'orderId': orderId,
    });
  }

  /// 退出登录：清除本地 token
  Future<void> clearToken() => _saveToken(null);
}
