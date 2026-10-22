import 'dart:async';
import '../l10n/l10n.dart';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'error_reporter.dart';

/// App 内更新下载与安装（v1.46.2 新增）。
///
/// 点击「立即更新」后由本服务通过 flutter_downloader 在后台下载新版 APK：
/// - 系统通知栏展示下载进度（showNotification=true）；
/// - 下载目标为 App 私有目录（getApplicationSupportDirectory()/downloads），无需存储权限；
/// - 下载完成后自动拉起系统安装界面（原生 MethodChannel 经 FileProvider 生成
///   content:// URI），全程不跳转浏览器。
class AppUpdater {
  AppUpdater._();
  static final AppUpdater instance = AppUpdater._();

  static const String _installChannelName = 'com.jiedan.guanjia/apk_install';
  static const String _portName = 'app_updater_download_port';

  final MethodChannel _installChannel = MethodChannel(
    _installChannelName,
  );

  bool _inited = false;
  ReceivePort? _port;

  /// 最近一次下载的 URL / 版本（complete 回调时记录，供失败后「重新尝试」
  /// 重新下载使用；进程存活期间有效）。
  String? _lastDownloadUrl;
  String? _lastVersion;

  /// 最近一次下载的期望大小（服务器 Content-Length），下载完成后用于
  /// 完整性校验（防下载到截断文件 / HTML 错误页导致的「解析失败」）。
  int? _lastExpectedBytes;

  /// 本次下载失败后是否已自动重试一次（防止 failed 回调死循环重试）。
  bool _retriedOnce = false;

  /// 持久化最近一次下载信息：进程被杀 / complete 回调丢失后，冷启动兜底
  /// （checkPendingInstall / _offerPendingApkOnStartup）仍能拿到 URL、版本
  /// 与服务器期望大小做完整校验。
  static const String _lastUrlKey = 'update_last_url';
  static const String _lastVersionKey = 'update_last_version';
  static const String _lastExpectBytesKey = 'update_last_expect_bytes';
  /// 待安装下载任务 ID（enqueue 成功即写入，v1.48.1）：flutter_downloader
  /// complete 回调丢失（下载期间进程被杀 / isolate 被回收）时，冷启动/回前台
  /// 兜底扫描据此确认「下载已开始」，配合下载目录 APK 完成自动安装。
  static const String _pendingTaskIdKey = 'update_pending_task_id';

  /// 应用启动时初始化：注册下载回调（后台 isolate 事件转发到主 isolate）。
  /// 失败不阻断启动（仅失去自动安装能力，可手动重试）。
  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    try {
      await FlutterDownloader.initialize(debug: false);
      _port = ReceivePort();
      // 防热重启/重复注册：先移除旧 port（旧 isolate 已销毁时 lookup 会拿到
      // 死 port 导致回调丢失），再注册当前 port。
      IsolateNameServer.removePortNameMapping(_portName);
      IsolateNameServer.registerPortWithName(_port!.sendPort, _portName);
      _port!.listen(_onDownloadEvent);
      await FlutterDownloader.registerCallback(_downloadCallback);
    } catch (e) {
      debugPrint('AppUpdater init failed: $e');
    }
  }

  /// 开始后台下载新版 APK；下载完成回调自动触发安装。
  ///
  /// 下载 URL 统一追加防缓存参数（?t=毫秒时间戳），避免 nginx/CDN 缓存旧
  /// 文件导致用户拉到半截 / 旧包后「安装包解析失败」。
  Future<void> startDownload(
    String url,
    String version, {
    bool resetRetry = true,
  }) async {
    _lastDownloadUrl = url;
    _lastVersion = version;
    if (resetRetry) _retriedOnce = false;
    _lastExpectedBytes = null;
    // 下载前预检「安装未知来源应用」权限（v1.47.2）：未授权时先弹引导，
    // 避免下载完成后才提示 / 无法拉起系统安装界面。
    await _preCheckInstallPermissionBeforeDownload(url, version);
    // 预取服务器 Content-Length，供下载完成后做完整性校验；同时持久化，
    // 覆盖「进程被杀 → complete 回调丢失 / 冷启动兜底」场景仍能拿到期望大小。
    try {
      final head = await http
          .head(Uri.parse(_withCacheBust(url)))
          .timeout(Duration(seconds: 10));
      final cl =
          head.headers['content-length'] ?? head.headers['Content-Length'];
      if (head.statusCode == 200 && cl != null) {
        _lastExpectedBytes = int.tryParse(cl);
      }
      // HEAD 预取结果留痕（v1.47.2）：便于远程核对期望大小与实际下载差异
      unawaited(
        ErrorReporter.instance.logError(
          'updater_head_ok',
          StateError('HEAD ${head.statusCode} content-length=$cl'),
          StackTrace.current,
          context: {'url': url, 'expectBytes': '$_lastExpectedBytes'},
        ),
      );
    } catch (e) {
      // HEAD 失败不影响下载，仅失去大小校验依据；记录日志便于远程诊断。
      unawaited(
        ErrorReporter.instance.logError(
          'updater_head_failed',
          e,
          StackTrace.current,
          context: {'url': url},
        ),
      );
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastUrlKey, url);
      await prefs.setString(_lastVersionKey, version);
      await prefs.setInt(_lastExpectBytesKey, _lastExpectedBytes ?? -1);
    } catch (_) {
      // 持久化失败不阻塞下载
    }
    try {
      final dir = await _ensureDownloadDir();
      final fileName = 'jiedan_guanjia_v$version.apk';
      final target = File('${dir.path}${Platform.pathSeparator}$fileName');
      if (target.existsSync()) {
        try {
          target.deleteSync();
        } catch (_) {
          // 残留旧包删除失败不阻塞下载（下载器会覆盖）
        }
      }
      final taskId = await FlutterDownloader.enqueue(
        url: _withCacheBust(url),
        savedDir: dir.path,
        fileName: fileName,
        showNotification: true, // 通知栏展示下载进度
        // 下载完成通知点击直接打开 APK 拉起系统安装界面（flutter_downloader
        // 1.12.1 仅当此项为 true 时才会为完成通知设置 contentIntent，否则
        // 点击通知无任何响应，App 也不会被唤起）
        openFileFromNotification: true,
      );
      if (taskId == null || taskId.isEmpty) {
        _showSnack(L10n.instance.t('i18n_304'));
        unawaited(
          ErrorReporter.instance.logError(
            'updater_enqueue_empty',
            StateError('enqueue returned empty taskId'),
            StackTrace.current,
            context: {'url': url},
          ),
        );
        return;
      }
      _showSnack(L10n.instance.t('i18n_268'));
      // enqueue 成功即写待安装记录（v1.48.1）：taskId 持久化，覆盖
      // 「complete 回调丢失」场景——冷启动/回前台兜底扫描不依赖回调，
      // 只要有下载目录 APK 即可自动校验并安装。
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_pendingTaskIdKey, taskId);
      } catch (_) {
        // pending 持久化失败不阻塞下载（last 记录仍可兜底）
      }
      // pending 记录写入留痕（v1.48.1）
      unawaited(
        ErrorReporter.instance.logError(
          'updater_pending_saved',
          StateError('pending taskId=$taskId'),
          StackTrace.current,
          context: {
            'taskId': taskId,
            'url': _withCacheBust(url),
            'version': version,
            'expectBytes': '$_lastExpectedBytes',
            'savedDir': dir.path,
          },
        ),
      );
      // 下载开始留痕（v1.47.2）：记录 URL 与期望大小，供安装失败时比对
      unawaited(
        ErrorReporter.instance.logError(
          'updater_download_start',
          StateError('enqueue ok taskId=$taskId'),
          StackTrace.current,
          context: {
            'url': _withCacheBust(url),
            'version': version,
            'expectBytes': '$_lastExpectedBytes',
            'savedDir': dir.path,
          },
        ),
      );
    } catch (e) {
      _showSnack(L10n.instance.t('i18n_304'));
      unawaited(
        ErrorReporter.instance.logError(
          'updater_enqueue_failed',
          e,
          StackTrace.current,
          context: {'url': url},
        ),
      );
    }
  }

  /// 为下载 URL 追加防缓存参数（保持原 query 兼容）。
  String _withCacheBust(String url) {
    final sep = url.contains('?') ? '&' : '?';
    return '$url$sep${DateTime.now().millisecondsSinceEpoch}';
  }

  /// 下载失败处理：清理残留半截包并自动重试一次（新防缓存参数）；重试仍
  /// 失败给出明确文案并记录日志（不静默失败）。
  Future<void> _handleDownloadFailed(String taskId) async {
    try {
      // 清理 DownloadManager 失败可能残留的半截 APK。
      if (_lastVersion != null) {
        final dir = await _ensureDownloadDir();
        final f = File(
          '${dir.path}${Platform.pathSeparator}jiedan_guanjia_v$_lastVersion.apk',
        );
        if (f.existsSync()) {
          try {
            f.deleteSync();
          } catch (_) {
            // 删除失败不阻塞重试
          }
        }
      }
      if (!_retriedOnce && _lastDownloadUrl != null && _lastVersion != null) {
        _retriedOnce = true;
        _showSnack(L10n.instance.t('i18n_075'));
        await startDownload(
          _lastDownloadUrl!,
          _lastVersion!,
          resetRetry: false,
        );
        return;
      }
      _showSnack(L10n.instance.t('i18n_409'));
      unawaited(
        ErrorReporter.instance.logError(
          'updater_download_failed',
          StateError('download task failed: $taskId'),
          StackTrace.current,
          context: {
            'url': _lastDownloadUrl ?? '',
            'version': _lastVersion ?? '',
          },
        ),
      );
    } catch (e, st) {
      ErrorReporter.instance.logError(
        'updater_download_failed',
        e,
        st,
        module: LogModule.updater,
      );
      _showSnack(L10n.instance.t('i18n_409'));
    }
  }

  /// 后台 isolate 下载回调（必须 @pragma 防 release 模式树摇）。
  @pragma('vm:entry-point')
  static void _downloadCallback(String id, int status, int progress) {
    final send = IsolateNameServer.lookupPortByName(_portName);
    send?.send([id, status, progress]);
  }

  void _onDownloadEvent(dynamic data) {
    if (data is! List || data.length < 2) return;
    final id = data[0] as String;
    final status = DownloadTaskStatus.fromInt(data[1] as int? ?? -1);
    if (status == DownloadTaskStatus.complete) {
      // 下载完成即拉起安装（前台 complete 回调路径）。带 Content-Length
      // 大小校验，坏文件直接删除并提示，不进入安装流程。
      // 回调留痕（v1.47.2）：记录收到 complete 时的期望大小，便于远程核对
      // 是否发生过「complete 后未触发安装」。
      unawaited(
        ErrorReporter.instance.logError(
          'updater_complete_received',
          StateError('task $id complete'),
          StackTrace.current,
          context: {'taskId': id, 'expectBytes': '$_lastExpectedBytes'},
        ),
      );
      unawaited(_installByTaskId(id, expectBytes: _lastExpectedBytes));
    } else if (status == DownloadTaskStatus.failed) {
      unawaited(_handleDownloadFailed(id));
    } else if (status == DownloadTaskStatus.canceled) {
      _showSnack(L10n.instance.t('i18n_265'));
    }
  }

  Future<void> _installByTaskId(String taskId, {int? expectBytes}) async {
    try {
      String? path;
      final tasks = await FlutterDownloader.loadTasks();
      if (tasks != null) {
        final task = tasks.where((t) => t.taskId == taskId).firstOrNull;
        // taskId 匹配结果留痕（v1.47.2）：区分「按 taskId 命中」与「走扫描兜底」
        unawaited(
          ErrorReporter.instance.logError(
            'updater_task_lookup',
            StateError('taskId=$taskId matched=${task != null}'),
            StackTrace.current,
            context: {'taskId': taskId, 'tasks': '${tasks.length}'},
          ),
        );
        if (task != null && task.filename != null) {
          final dir = task.savedDir;
          // savedDir 运行时可能为 null（下载器任务表未持久化目录，模型声明
          // 非空导致分析器误报），直接拼接会得到 "null/xxx.apk" 导致
          // file_not_found，此处判空后走扫描兜底。
          path = (dir.isEmpty)
              ? null
              : '$dir${Platform.pathSeparator}${task.filename}';
          // 记录最近下载信息，供安装失败后「重新尝试」重新下载使用。
          _lastDownloadUrl = task.url;
          _lastVersion = _versionFromApkName(task.filename!);
        }
      }
      // 兜底 1：回调里 loadTasks 匹配不到 taskId（release 树摇 / 数据库丢失）
      // 或 savedDir 缺失导致拼接无效时，扫描下载目录中最新的 .apk。
      if (path == null || !File(path).existsSync()) {
        path = await _findLatestApk();
      }
      if (path == null) {
        _showSnack(L10n.instance.t('i18n_410'));
        return;
      }
      // 兜底 2：安装前完整性校验（大小 / magic bytes / EOCD / Content-Length）。
      // 内存期望大小丢失时（进程被杀 / 回调丢失）从持久化记录补齐；
      // 校验不通过时（v1.47.2）**不再删除安装包**——避免 HEAD/GET 大小
      // 差异或服务器临时异常误杀合法包，改为保留文件并弹「手动安装/重新下载」。
      final verr = await _validateApkWithPersisted(path, expectBytes);
      if (verr != null) {
        // 校验失败留痕（v1.47.2）：记录文件大小与期望大小，便于远程确认
        // 是真实截断还是校验过严误杀。
        unawaited(
          ErrorReporter.instance.logError(
            'updater_validate_failed',
            StateError(verr),
            StackTrace.current,
            context: {
              'path': path,
              'expectBytes': '${expectBytes ?? _lastExpectedBytes ?? ''}',
              'fileBytes':
                  '${File(path).existsSync() ? File(path).lengthSync() : -1}',
            },
          ),
        );
        await _showInvalidApkDialog(verr, path);
        return;
      }
      await _installApk(path);
    } catch (_) {
      _showSnack(L10n.instance.t('i18n_077'));
    }
  }

  /// 扫描下载目录中最新的 .apk 文件（taskId 匹配失败时的兜底）。
  Future<String?> _findLatestApk() async {
    try {
      final dir = await _ensureDownloadDir();
      final files =
          dir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.toLowerCase().endsWith('.apk'))
              .toList()
            ..sort(
              (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
            );
      if (files.isEmpty) return null;
      return files.first.path;
    } catch (_) {
      return null;
    }
  }

  /// 安装包完整性初检：
  /// - 存在且体积 ≥ 1MB（真实 APK 远大于此，可拦截下载到 HTML 错误页 / 空文件）；
  /// - 文件头为 zip magic（PK\x03\x04，APK 本质是 zip）；
  /// - 可选：与服务器 Content-Length 容差校验（v1.47.2：HEAD 期望大小与实际
  ///   下载大小允许 ±5% 差异——CDN/gzip/节点差异或服务器更新同 URL 文件时
  ///   不会误杀合法包；真正截断包仍会被头部 PK / 尾部 EOCD 校验拦截）。
  /// 返回 null 表示通过；否则返回失败原因文案。
  String? _validateApk(String path, {int? expectBytes}) {
    try {
      final f = File(path);
      if (!f.existsSync()) return L10n.instance.t('i18n_214');
      final len = f.lengthSync();
      if (len < 1024 * 1024) return L10n.instance.t('i18n_217');
      if (expectBytes != null && expectBytes > 0) {
        final lower = (expectBytes * 0.95).floor();
        final upper = (expectBytes * 1.05).ceil();
        if (len < lower || len > upper) {
          return L10n.instance.t('i18n_216');
        }
      }
      final raf = f.openSync();
      try {
        final head = raf.readSync(4);
        if (head.length < 4 || head[0] != 0x50 || head[1] != 0x4B) {
          return L10n.instance.t('i18n_219');
        }
        // 尾部校验 ZIP 结束记录（EOCD 标记 PK\x05\x06）：下载中断 / CDN 缓存
        // 半截文件时头部 magic 仍完整、但尾部缺失，系统安装器会报「解析失败」。
        // 扫描文件末尾 ≤64KB（ZIP 注释区上限）内的 EOCD 标记。
        final len = f.lengthSync();
        if (len < 22) return L10n.instance.t('i18n_215');
        final tailLen = len > 22 + 65536 ? 22 + 65536 : len;
        raf.setPositionSync(len - tailLen);
        final tail = raf.readSync(tailLen);
        var eocd = false;
        for (var i = tail.length - 22; i >= 0; i--) {
          if (tail[i] == 0x50 &&
              tail[i + 1] == 0x4B &&
              tail[i + 2] == 0x05 &&
              tail[i + 3] == 0x06) {
            eocd = true;
            break;
          }
        }
        if (!eocd) return L10n.instance.t('i18n_218');
      } finally {
        raf.closeSync();
      }
      return null;
    } catch (_) {
      return L10n.instance.t('i18n_220');
    }
  }

  /// 校验安装包，期望大小缺失时从持久化记录补齐：仅当 APK 文件名版本与
  /// 最近一次下载版本一致时，采用持久化的服务器 Content-Length 做严格大小
  /// 比对（覆盖 complete 回调丢失 / 冷启动兜底场景）。
  Future<String?> _validateApkWithPersisted(
    String path,
    int? expectBytes,
  ) async {
    var expect = expectBytes;
    if (expect == null || expect <= 0) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final lastVer = prefs.getString(_lastVersionKey);
        final apkName = path.split(Platform.pathSeparator).last.toLowerCase();
        if (lastVer != null && lastVer == _versionFromApkName(apkName)) {
          final v = prefs.getInt(_lastExpectBytesKey) ?? -1;
          if (v > 0) expect = v;
        }
      } catch (_) {
        // 持久化读取失败不影响校验
      }
    }
    return _validateApk(path, expectBytes: expect);
  }

  /// 消费原生侧记录的通知点击 / APK 打开意图并触发安装。
  /// 冷启动（onCreate 置位）与前台恢复（onNewIntent 置位）后由 main.dart 调用。
  /// 若无待消费意图，则兜底扫描下载目录中比当前版本新的 APK（覆盖
  /// 「后台下载完成但回调丢失 / 通知被清」场景），弹窗让用户决定是否安装。
  Future<void> checkPendingInstall() async {
    try {
      // 兜底触发留痕（v1.48.1）：冷启动 / 回前台每次扫描均记录，便于确认
      // 兜底链路被正确触发（complete 回调丢失时依赖此路径完成安装）。
      unawaited(
        ErrorReporter.instance.logError(
          'updater_resume_check',
          StateError('pending install check triggered'),
          StackTrace.current,
        ),
      );
      // 拉取原生侧 PackageInstaller 提交结果并留痕（v1.47.2）：用户在系统
      // 安装确认界面的最终结果（成功/失败/取消）经此通道回传错误日志。
      await _consumeInstallResult();
      final pending = await _installChannel.invokeMapMethod<String, dynamic>(
        'consumeNotificationInstall',
      );
      if (pending == null || pending.isEmpty) {
        await _offerPendingApkOnStartup();
        return;
      }
      final taskId = pending['taskId'] as String?;
      final path = pending['path'] as String?;
      if (taskId != null && taskId.isNotEmpty) {
        await _installByTaskId(taskId);
      } else if (path != null && path.isNotEmpty) {
        final f = File(path);
        if (!f.existsSync()) {
          _showSnack(L10n.instance.t('i18n_213'));
        } else {
          // 通知点击 / 文件打开路径：同样先做完整性校验；校验不通过时
          // （v1.47.2）保留文件并弹「手动安装/重新下载」，不再删除。
          final verr = await _validateApkWithPersisted(path, null);
          if (verr != null) {
            unawaited(
              ErrorReporter.instance.logError(
                'updater_pending_validate_failed',
                StateError(verr),
                StackTrace.current,
                context: {'path': path},
              ),
            );
            await _showInvalidApkDialog(verr, path);
          } else {
            await _installApk(path);
          }
        }
      }
    } catch (_) {
      _showSnack(L10n.instance.t('i18n_222'));
    }
  }

  /// 启动兜底：下载目录存在比当前版本新的 APK 时**自动提交安装**（v1.48.1：
  /// 由「弹窗询问」改为「自动拉起系统安装界面」——complete 回调丢失时，用户
  /// 重启 App 即自动校验并安装，无需手动点击）。数据源为 enqueue 时写入的
  /// pending / last 持久化记录。用 SharedPreferences 记录已提交过的文件名，
  /// 避免每次启动重复提交（用户取消系统界面后不再打扰）。
  static const String _offeredApkKey = 'update_install_offered_apk';

  Future<void> _offerPendingApkOnStartup() async {
    try {
      // 读取 pending 记录留痕（v1.48.1）：确认兜底扫描的数据源不依赖
      // complete 回调写入。
      String? pendingTaskId;
      try {
        final prefs = await SharedPreferences.getInstance();
        pendingTaskId = prefs.getString(_pendingTaskIdKey);
      } catch (_) {
        // 读取失败不阻塞扫描
      }
      unawaited(
        ErrorReporter.instance.logError(
          'updater_startup_scan_triggered',
          StateError('startup scan pendingTaskId=$pendingTaskId'),
          StackTrace.current,
          context: {'pendingTaskId': pendingTaskId ?? ''},
        ),
      );
      final dir = await _ensureDownloadDir();
      final files =
          dir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.toLowerCase().endsWith('.apk'))
              .toList()
            ..sort(
              (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
            );
      if (files.isEmpty) {
        // 扫描未发现 APK：无待安装包，静默并留痕（供远程确认兜底扫描生效）
        unawaited(
          ErrorReporter.instance.logError(
            'updater_startup_scan_none',
            StateError('no apk found in download dir'),
            StackTrace.current,
          ),
        );
        return;
      }
      final latest = files.first.path;
      // 启动兜底同样校验完整性；校验不通过时（v1.47.2）**不删除**安装包
      // （避免误杀合法包），仅留痕后静默跳过，不再弹窗打扰。
      final verr = await _validateApkWithPersisted(latest, null);
      if (verr != null) {
        unawaited(
          ErrorReporter.instance.logError(
            'updater_startup_scan_invalid',
            StateError(verr),
            StackTrace.current,
            context: {'path': latest},
          ),
        );
        return;
      }
      final apkName = latest.split(Platform.pathSeparator).last;
      final apkVersion = _versionFromApkName(apkName);
      if (apkVersion == null) return;
      final info = await PackageInfo.fromPlatform();
      if (!_isVersionNewer(apkVersion, info.version)) {
        // 当前版本不低于 APK：非待装包（残留旧包 / 已安装更新），跳过
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(_offeredApkKey) == apkName) return;
      // 先记录已提交文件名，再提交安装（防并发 / 重复提交）
      await prefs.setString(_offeredApkKey, apkName);
      // 扫描发现更新的 APK：自动提交安装（v1.48.1 替代原弹窗询问）
      unawaited(
        ErrorReporter.instance.logError(
          'updater_startup_scan_found',
          StateError('auto install apk=$apkName v$apkVersion'),
          StackTrace.current,
          context: {'path': latest, 'apkName': apkName, 'version': apkVersion},
        ),
      );
      await _installApk(latest);
    } catch (_) {
      // 兜底失败静默即可：用户仍可走「检查更新」主动下载
    }
  }

  /// 拉起系统安装界面（原生侧 Android 8.0+ 走 PackageInstaller.Session
  /// 提交，不受后台 Activity 启动限制；低版本回退 FileProvider+ACTION_VIEW）。
  /// 失败时弹可见对话框（原因 + 手动安装 + 重新尝试），绝不静默；日志留痕。
  Future<void> _installApk(String path, {String? reason}) async {
    try {
      final ok = await _installChannel.invokeMethod<bool>('installApk', path);
      // 安装提交结果留痕（v1.47.2）
      unawaited(
        ErrorReporter.instance.logError(
          'updater_install_submit',
          StateError('installApk result=$ok'),
          StackTrace.current,
          context: {'path': path, 'reason': reason ?? ''},
        ),
      );
      if (ok != true) {
        _showInstallFailedDialog(reason ?? L10n.instance.t('i18n_525'), path: path);
      } else {
        // 安装界面已成功拉起（v1.48.1）：清除 pending 记录，避免后续启动
        // 重复扫描同一任务；系统安装结果仍由 PackageInstaller 广播回传。
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.remove(_pendingTaskIdKey);
        } catch (_) {
          // 清除失败不阻塞（_offeredApkKey 仍可防重复提交）
        }
      }
    } on PlatformException catch (e) {
      unawaited(
        ErrorReporter.instance.logError(
          'updater_install_failed',
          e,
          StackTrace.current,
          module: LogModule.updater,
          context: {'code': e.code, 'message': '${e.message}', 'path': path},
        ),
      );
      if (e.code == 'need_unknown_sources') {
        // v1.47.2：权限未授权时自动拉起系统设置页并弹说明，替代仅弹对话框
        unawaited(
          _installChannel.invokeMethod('openUnknownSourcesSettings'),
        );
        _showNeedUnknownSourcesDialog();
      } else {
        _showInstallFailedDialog(e.message ?? L10n.instance.t('i18n_582'), path: path);
      }
    } catch (e, st) {
      ErrorReporter.instance.logError(
        'updater_install_failed',
        e,
        st,
        module: LogModule.updater,
      );
      _showInstallFailedDialog('$e', path: path);
    }
  }

  /// 下载前预检「安装未知来源应用」权限（v1.47.2 缺陷3修复）：
  /// 用户点「立即更新」进入下载前就检查 REQUEST_INSTALL_PACKAGES，未授权时
  /// 弹引导对话框（去开启 / 仍然下载），避免下载完成后才提示导致装不上。
  Future<void> _preCheckInstallPermissionBeforeDownload(
    String url,
    String version,
  ) async {
    try {
      final can = await _installChannel.invokeMethod<bool>(
            'canRequestPackageInstalls',
          ) ??
          true;
      if (can) return;
      // 权限缺失留痕（v1.47.2）
      unawaited(
        ErrorReporter.instance.logError(
          'updater_permission_denied',
          StateError('REQUEST_INSTALL_PACKAGES not granted'),
          StackTrace.current,
          module: LogModule.updater,
          context: {'version': version},
        ),
      );
      final ctx = appNavigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      var goSettings = false;
      await showDialog<void>(
        context: ctx,
        barrierDismissible: false,
        builder: (dialogCtx) => AlertDialog(
          title: Text(L10n.instance.t('updater_allow_install')),
          content: Text(
            L10n.instance.t('i18n_223') +
            L10n.instance.t('i18n_152') +
            L10n.instance.t('i18n_138') +
            L10n.instance.t('i18n_301'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: Text(L10n.instance.t('updater_download_anyway')),
            ),
            FilledButton(
              onPressed: () {
                goSettings = true;
                Navigator.pop(dialogCtx);
              },
              child: Text(L10n.instance.t('updater_go_enable')),
            ),
          ],
        ),
      );
      if (goSettings) {
        await _installChannel.invokeMethod('openUnknownSourcesSettings');
        // 引导后不阻塞下载：用户开启后返回，下载完成仍可正常拉起安装
      }
    } catch (_) {
      // 预检失败不阻塞下载（保持原行为）
    }
  }

  /// 安装包校验失败对话框（v1.47.2 缺陷2修复）：不再自动删除安装包，
  /// 保留文件并提供「手动安装」与「重新下载」两条出路，避免合法包被销毁。
  Future<void> _showInvalidApkDialog(String reason, String path) async {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    await showDialog<void>(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        title: Text(L10n.instance.t('updater_verify_failed')),
        content: Text(
          L10n.instance.t('i18n_010', args: {'v0': reason}),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text(L10n.instance.t('common_close')),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogCtx);
              if (_lastDownloadUrl != null && _lastVersion != null) {
                unawaited(startDownload(_lastDownloadUrl!, _lastVersion!));
              }
            },
            child: Text(L10n.instance.t('updater_download_again')),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(dialogCtx);
              unawaited(_installApk(path));
            },
            child: Text(L10n.instance.t('updater_manual_install')),
          ),
        ],
      ),
    );
  }

  /// 拉取原生侧 PackageInstaller 提交的安装结果（成功/失败/用户取消），
  /// 留痕到错误日志（v1.47.2），便于远程定位「下载完成但安装失败」场景。
  Future<void> _consumeInstallResult() async {
    try {
      final r = await _installChannel.invokeMapMethod<String, dynamic>(
        'consumeInstallResult',
      );
      if (r == null || r.isEmpty) return;
      final status = r['status'] as String? ?? '';
      final code = r['code'] as String? ?? '';
      unawaited(
        ErrorReporter.instance.logError(
          'updater_install_result',
          StateError('PackageInstaller status=$status code=$code'),
          StackTrace.current,
          module: LogModule.updater,
          context: {'status': status, 'code': code},
        ),
      );
    } catch (_) {
      // 消费失败静默
    }
  }

  /// 安装失败兜底对话框：展示失败原因，并提供「手动安装」（再次拉起系统
  /// 安装器）与「重新尝试」（重新下载后自动安装）两条出路。
  void _showInstallFailedDialog(String reason, {String? path}) {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) return;
    final canReDownload = _lastDownloadUrl != null && _lastVersion != null;
    showDialog<void>(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        title: Text(L10n.instance.t('updater_install_failed')),
        content: Text(
          L10n.instance.t('i18n_078', args: {'v0': reason}) +
          L10n.instance.t('i18n_160'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text(L10n.instance.t('common_close')),
          ),
          if (canReDownload)
            TextButton(
              onPressed: () {
                Navigator.pop(dialogCtx);
                unawaited(startDownload(_lastDownloadUrl!, _lastVersion!));
              },
              child: Text(L10n.instance.t('updater_try_again')),
            ),
          if (path != null)
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogCtx);
                unawaited(_installApk(path));
              },
              child: Text(L10n.instance.t('updater_manual_install')),
            ),
        ],
      ),
    );
  }

  /// 从 APK 文件名（jiedan_guanjia_v1.46.8.apk）解析版本号。
  String? _versionFromApkName(String name) {
    final m = RegExp(r'v(\d+\.\d+\.\d+)\.apk$').firstMatch(name);
    return m?.group(1);
  }

  /// 简单版本号比较：a 是否比 b 新（逐段数字比较）。
  bool _isVersionNewer(String a, String b) {
    final pa = a.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final pb = b.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  void _showNeedUnknownSourcesDialog() {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) return;
    showDialog<void>(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        title: Text(L10n.instance.t('updater_allow_unknown')),
        content: Text(
          L10n.instance.t('i18n_524') +
          L10n.instance.t('i18n_576') +
          L10n.instance.t('i18n_152') +
          L10n.instance.t('i18n_138') +
          L10n.instance.t('i18n_302'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text(L10n.instance.t('common_cancel')),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(dialogCtx);
              unawaited(
                _installChannel.invokeMethod('openUnknownSourcesSettings'),
              );
            },
            child: Text(L10n.instance.t('updater_go_enable')),
          ),
        ],
      ),
    );
  }

  Future<Directory> _ensureDownloadDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}downloads');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  void _showSnack(String msg) {
    appMessengerKey.currentState?.showSnackBar(SnackBar(content: Text(msg)));
  }
}
