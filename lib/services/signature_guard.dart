import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../constants.dart';

/// 防重打包自签名校验（防破解 P3）。
/// 仅 release 模式执行：读取 APK 实际签名证书 SHA-256 指纹，
/// 与 [AppConfig.expectedSigningCertSha256] 比对，不一致判定包被二次签名/重打包。
///
/// 破解者没有正式 keystore，只能用自己的证书重打包 APK 安装，
/// 本校验会让重打包包直接拒绝进入应用界面。
class SignatureGuard {
  SignatureGuard._();
  static final SignatureGuard instance = SignatureGuard._();

  static const MethodChannel _channel =
      MethodChannel('com.jiedan.guanjia/signature');

  /// 启动时调用：签名被篡改则抛出 [SignatureMismatchException]。
  /// debug/profile 模式跳过（调试期使用 debug 签名，不参与校验）。
  Future<void> verifyOnLaunch() async {
    // 非 release 一律放行（debug 运行、单元测试等）
    if (!kReleaseMode) return;
    final expected = AppConfig.expectedSigningCertSha256;
    if (expected.isEmpty) return; // 未配置期望指纹则跳过（正常不应发生）

    String? actual;
    try {
      actual = await _channel.invokeMethod<String>('getSigningCertSha256');
    } on PlatformException {
      actual = null;
    } on MissingPluginException {
      actual = null;
    }

    if (actual == null || !_normalize(actual).contains(_normalize(expected))) {
      throw SignatureMismatchException();
    }
  }

  static String _normalize(String s) => s.replaceAll(RegExp(r'\s+'), '');
}

/// 应用签名与内置期望指纹不一致（被重打包/二次签名）时抛出。
class SignatureMismatchException implements Exception {
  const SignatureMismatchException();
}
