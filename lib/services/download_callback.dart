import 'dart:ui' show IsolateNameServer;

/// App 内更新下载回调端口名（与 app_updater.dart 中注册的 ReceivePort 对应）。
const String appUpdaterDownloadPortName = 'app_updater_download_port';

/// flutter_downloader 下载回调入口（v1.49.4，官方标准顶层函数写法）。
///
/// 必须为**顶层函数**并加 `@pragma('vm:entry-point')`：flutter_downloader
/// 1.12.1 在后台 isolate（DownloadWorker）中通过 CallbackHandle 恢复回调入口，
/// release AOT 下需从快照直接解析顶层函数；此前将回调放在 AppUpdater 类的
/// static 方法上，仅方法级注解不足以让类本身进入后台 isolate 入口点表，
/// 真机出现 `To access 'package:...::AppUpdater' from native code, it must be
/// annotated`，导致 complete 回调永远无法到达主 isolate。
///
/// 本函数仅做端口转发：把 [id, status, progress] 发送到主 isolate 注册的
/// 端口，由 AppUpdater._onDownloadEvent 消费，保证 updater_complete_received
/// 留痕与自动安装链路真正生效。
@pragma('vm:entry-point')
void downloadCallback(String id, int status, int progress) {
  final send = IsolateNameServer.lookupPortByName(appUpdaterDownloadPortName);
  send?.send([id, status, progress]);
}
