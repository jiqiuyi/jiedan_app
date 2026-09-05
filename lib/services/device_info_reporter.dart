import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 设备信息最小化上报（v1.26.0，隐私合规）。
///
/// 仅采集 4 项非敏感信息，用于开发者定位反馈问题：
/// - 设备型号（Android model / iOS utsname.machine）
/// - 系统版本（Android version.release / iOS systemVersion）
/// - App 版本号（PackageInfo.version）
/// - build 号（PackageInfo.buildNumber）
///
/// 明确红线：不采集 IMEI / Android ID / MAC / 位置 / 通讯录 / 应用列表等敏感信息。
/// 读取失败一律静默降级为空串，绝不阻断反馈提交、不影响任何主流程。
/// 「反馈信息上报」开关默认开启，可在设置页一键关闭（本地持久化）。
class DeviceInfoReporter {
  DeviceInfoReporter._();
  static final DeviceInfoReporter instance = DeviceInfoReporter._();

  /// 上报开关持久化键（SharedPreferences，默认开启）。
  static const String _enabledKey = 'feedback_report_enabled';

  /// 反馈信息上报开关是否开启（默认开启；读取失败按默认处理，不影响功能）。
  Future<bool> reportingEnabled() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return sp.getBool(_enabledKey) ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 设置反馈信息上报开关（本地持久化；失败静默忽略）。
  Future<void> setReportingEnabled(bool v) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_enabledKey, v);
    } catch (_) {
      // 持久化失败静默忽略，开关状态仅影响本次会话表现。
    }
  }

  /// 采集最小化设备信息载荷。任何单项读取失败都降级为空串，绝不抛错。
  Future<DeviceInfoPayload> collect() async {
    var deviceModel = '';
    var osVersion = '';
    try {
      final di = await DeviceInfoPlugin().deviceInfo;
      if (di is AndroidDeviceInfo) {
        deviceModel = di.model;
        osVersion = di.version.release;
      } else if (di is IosDeviceInfo) {
        deviceModel = di.utsname.machine;
        osVersion = di.systemVersion;
      }
    } catch (_) {
      // 平台信息不可用：静默降级为空串。
    }
    var appVersion = '';
    var buildNumber = '';
    try {
      final pi = await PackageInfo.fromPlatform();
      appVersion = pi.version;
      buildNumber = pi.buildNumber;
    } catch (_) {
      // 版本信息不可用：静默降级为空串。
    }
    return DeviceInfoPayload(
      deviceModel: deviceModel,
      osVersion: osVersion,
      appVersion: appVersion,
      buildNumber: buildNumber,
    );
  }
}

/// 最小化设备信息载荷（4 项，全部可空）。
class DeviceInfoPayload {
  const DeviceInfoPayload({
    this.deviceModel = '',
    this.osVersion = '',
    this.appVersion = '',
    this.buildNumber = '',
  });

  final String deviceModel;
  final String osVersion;
  final String appVersion;
  final String buildNumber;
}
