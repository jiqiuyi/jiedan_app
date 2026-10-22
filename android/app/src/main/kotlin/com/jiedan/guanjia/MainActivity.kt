package com.jiedan.guanjia

import android.app.PendingIntent
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.annotation.NonNull
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.jiedan.guanjia/signature"
    private val PAY_CHANNEL = "com.jiedan.guanjia/paylistener"
    private val WIDGET_CHANNEL = "com.jiedan.guanjia/widget"
    private val APK_CHANNEL = "com.jiedan.guanjia/apk_install"
    /// 兼容 flutter_downloader 旧版本通知点击广播 action（1.12.1 起完成通知
    /// 直接携带打开 APK 的 contentIntent、走 ACTION_VIEW；此处兜底老版本，
    /// intent extras 携带 task_id）。
    private val NOTIFICATION_CLICK_ACTION =
        "com.vincent.file.downloader.action.FLUTTER_NOTIFICATION_CLICK"

    /// PackageInstaller 安装结果广播 action（v1.47.2）：Session.commit 的
    /// PendingIntent 指向该 action，接收系统安装器最终状态供 Flutter 侧留痕。
    private val ACTION_INSTALL_RESULT = "com.jiedan.guanjia.INSTALL_RESULT"
    private val EXTRA_SESSION_ID = "extra_session_id"

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // 注册 PackageInstaller 安装结果接收器（动态注册，App 进程存活即可收到；
        // Android 13+ 必须显式指定 exported 标志，这里仅接收系统安装器广播）。
        runCatching {
            if (Build.VERSION.SDK_INT >= 33) {
                registerReceiver(
                    installResultReceiver,
                    IntentFilter(ACTION_INSTALL_RESULT),
                    Context.RECEIVER_NOT_EXPORTED
                )
            } else {
                registerReceiver(
                    installResultReceiver,
                    IntentFilter(ACTION_INSTALL_RESULT)
                )
            }
        }
        handleIncomingIntent(intent)
    }

    override fun onDestroy() {
        super.onDestroy()
        runCatching { unregisterReceiver(installResultReceiver) }
    }

    /// PackageInstaller.Session 提交后系统安装器返回的状态接收器（v1.47.2）：
    /// 保存到静态字段，由 Flutter 侧 consumeInstallResult 拉取并写入错误日志。
    private val installResultReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != ACTION_INSTALL_RESULT) return
            val sessionId = intent.getIntExtra(EXTRA_SESSION_ID, -1)
            val status = intent.getIntExtra(
                PackageInstaller.EXTRA_STATUS,
                PackageInstaller.STATUS_PENDING_USER_ACTION
            )
            lastInstallResultSessionId = sessionId
            lastInstallResultStatus = status
            Log.i("JieDanUpdate", "PackageInstaller result session=$sessionId status=$status")
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIncomingIntent(intent)
    }

    /// 统一处理冷启动 / 热启动的外部意图：
    /// - QUICK_LEDGER：桌面小组件「记一笔」置位，由 Flutter 侧轮询消费；
    /// - FLUTTER_NOTIFICATION_CLICK：老版本 flutter_downloader 通知点击，置位
    ///   待安装下载任务 ID；
    /// - ACTION_VIEW + package-archive：通知 / 文件管理器打开 APK，置位待安装路径。
    private fun handleIncomingIntent(intent: Intent?) {
        if (intent == null) return
        when (intent.action) {
            LedgerWidgetProvider.ACTION_QUICK_LEDGER -> pendingQuickLedger = true
            NOTIFICATION_CLICK_ACTION -> {
                val taskId = intent.getStringExtra("task_id")
                if (!taskId.isNullOrEmpty()) pendingInstallTaskId = taskId
            }
            Intent.ACTION_VIEW -> {
                if (intent.type == "application/vnd.android.package-archive") {
                    val path = uriToApkPath(intent.data)
                    if (path != null) pendingInstallApkPath = path
                }
            }
        }
    }

    /// 将通知点击 / 系统打开 APK 的 data URI 转成本地绝对路径
    /// （content:// 通过 MediaStore 查询 _data；file:// 直接取 path）。
    private fun uriToApkPath(uri: Uri?): String? {
        if (uri == null) return null
        return try {
            if (uri.scheme == "content") {
                var p: String? = null
                contentResolver.query(
                    uri,
                    arrayOf(android.provider.MediaStore.Files.FileColumns.DATA),
                    null, null, null
                )?.use { c ->
                    if (c.moveToFirst()) p = c.getString(0)
                }
                p
            } else {
                uri.path
            }
        } catch (e: Exception) {
            null
        }
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSigningCertSha256" -> result.success(getSigningCertSha256())
                    else -> result.notImplemented()
                }
            }

        // 到账通知解析数据桥：Flutter 侧拉取暂存记录并带上登录态上报后端。
        // 原生只做「解析 + 暂存」，保证上报动作始终由 App 网络层（带 token）完成。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PAY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "flushPendingReports" -> {
                        val list = PayNoticeListenerService.takePending(this)
                        result.success(list.map {
                            mapOf(
                                "amount" to it["amount"],
                                "ts" to it["ts"],
                                "source" to it["source"],
                            )
                        })
                    }
                    "listenerEnabled" ->
                        result.success(PayNoticeListenerService.isEnabled(this))
                    "openListenerSettings" -> {
                        try {
                            startActivity(
                                Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 桌面小组件桥：Flutter 侧轮询消费「记一笔」拉起意图（QUICK_LEDGER）。
        // 冷启动由 onCreate 置位，热启动由 onNewIntent 置位；消费后复位，避免重复弹窗。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WIDGET_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumeQuickLedger" -> {
                        val v = pendingQuickLedger
                        pendingQuickLedger = false
                        result.success(v)
                    }
                    else -> result.notImplemented()
                }
            }

        // App 内更新安装桥（v1.46.2）：Flutter 侧下载完成后传 APK 绝对路径，
        // 原生经 FileProvider 生成 content:// URI 拉起系统安装界面，不跳转浏览器。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APK_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> installApk(call.arguments as? String ?: "", result)
                    "canRequestPackageInstalls" -> {
                        // 下载前权限预检（v1.47.2）：Android O+ 才需要未知来源授权
                        result.success(
                            Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                                packageManager.canRequestPackageInstalls()
                        )
                    }
                    "consumeInstallResult" -> {
                        // PackageInstaller 安装结果（v1.47.2）：Flutter 侧拉取后
                        // 写入错误日志；-2 表示无记录则返回空 Map。
                        val s = lastInstallResultStatus
                        val sid = lastInstallResultSessionId
                        lastInstallResultStatus = -2
                        lastInstallResultSessionId = -2
                        if (s == -2) {
                            result.success(emptyMap<String, String>())
                        } else {
                            val statusText = when (s) {
                                PackageInstaller.STATUS_SUCCESS -> "success"
                                PackageInstaller.STATUS_PENDING_USER_ACTION -> "pending_user_action"
                                PackageInstaller.STATUS_FAILURE -> "failure"
                                PackageInstaller.STATUS_FAILURE_ABORTED -> "aborted"
                                PackageInstaller.STATUS_FAILURE_BLOCKED -> "blocked"
                                PackageInstaller.STATUS_FAILURE_CONFLICT -> "conflict"
                                PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> "incompatible"
                                PackageInstaller.STATUS_FAILURE_INVALID -> "invalid"
                                PackageInstaller.STATUS_FAILURE_STORAGE -> "storage"
                                else -> "unknown($s)"
                            }
                            result.success(
                                mapOf(
                                    "status" to statusText,
                                    "code" to s.toString(),
                                    "sessionId" to sid.toString(),
                                )
                            )
                        }
                    }
                    "consumeNotificationInstall" -> {
                        val taskId = pendingInstallTaskId
                        pendingInstallTaskId = null
                        val path = pendingInstallApkPath
                        pendingInstallApkPath = null
                        // P0（v1.49.1）：无任何通知点击 / APK 打开记录时返回空 Map，
                        // 与 consumeInstallResult 行为一致；旧实现返回
                        // {taskId:null, path:null} 非空 Map 会短路 Flutter 侧
                        // checkPendingInstall 的兜底扫描，导致下载完成后无法跳转安装。
                        if (taskId.isNullOrEmpty() && path.isNullOrEmpty()) {
                            result.success(emptyMap<String, String>())
                        } else {
                            result.success(mapOf("taskId" to taskId, "path" to path))
                        }
                    }
                    "openUnknownSourcesSettings" -> {
                        try {
                            startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:$packageName"),
                                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    companion object {
        @Volatile
        private var pendingQuickLedger = false
        /// 通知点击触发的待安装下载任务 ID / APK 路径（Flutter 侧消费后复位）。
        @Volatile
        private var pendingInstallTaskId: String? = null
        @Volatile
        private var pendingInstallApkPath: String? = null
        /// PackageInstaller 最近一次提交的安装结果（v1.47.2）；-2 表示无记录。
        @Volatile
        private var lastInstallResultSessionId: Int = -2
        @Volatile
        private var lastInstallResultStatus: Int = -2
    }

    /// 拉起系统安装界面安装 APK（v1.47.2 缺陷1修复）：
    /// - Android 8.0+（API 26）：PackageInstaller.Session 提交安装——安装确认
    ///   界面由系统进程显示，**不受后台 Activity 启动限制**，下载完成时 App
    ///   在后台也能正常拉起安装确认页；结果经广播回传供 Flutter 侧留痕。
    /// - Android 7.x 及以下：回退 FileProvider + ACTION_VIEW（无后台限制问题）。
    private fun installApk(path: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            installViaPackageInstaller(path, result)
        } else {
            installViaActionView(path, result)
        }
    }

    /// PackageInstaller.Session 安装（Android 8.0+，v1.47.2）：
    /// 将 APK 字节写入 session 后 commit，由系统安装器弹出确认界面；结果经
    /// [ACTION_INSTALL_RESULT] 广播回传 [installResultReceiver]。
    private fun installViaPackageInstaller(path: String, result: MethodChannel.Result) {
        val file = File(path)
        try {
            if (!file.exists()) {
                result.error("file_not_found", "APK 文件不存在", null)
                return
            }
            if (!isInFileProviderScope(file)) {
                result.error("file_not_in_scope", "APK 不在允许共享的目录内", null)
                return
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !packageManager.canRequestPackageInstalls()
            ) {
                result.error("need_unknown_sources", "需要开启允许安装未知来源应用", null)
                return
            }
            val installer = packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(
                PackageInstaller.SessionParams.MODE_FULL_INSTALL
            ).apply {
                setAppPackageName(packageName)
                setSize(file.length())
            }
            val sessionId = installer.createSession(params)
            val session = installer.openSession(sessionId)
            try {
                file.inputStream().use { input ->
                    session.openWrite(file.name, 0, file.length()).use { out ->
                        input.copyTo(out)
                    }
                }
            } catch (e: Exception) {
                runCatching { session.abandon() }
                result.error("install_failed", "写入安装包失败：${e.message}", null)
                return
            }
            val senderIntent = Intent(ACTION_INSTALL_RESULT).apply {
                setPackage(packageName)
                putExtra(EXTRA_SESSION_ID, sessionId)
            }
            val sender = PendingIntent.getBroadcast(
                this,
                sessionId,
                senderIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            ).intentSender
            session.commit(sender)
            result.success(true)
        } catch (e: SecurityException) {
            result.error("need_unknown_sources", "需要开启允许安装未知来源应用", null)
        } catch (e: Exception) {
            result.error("install_failed", "提交安装失败：${e.message}", null)
        }
    }

    /// ACTION_VIEW 安装（Android 7.x 及以下 / 无 PackageInstaller 环境）：
    /// FileProvider authority 与 AndroidManifest 中 "${applicationId}.fileprovider"
    /// 保持一致。
    private fun installViaActionView(path: String, result: MethodChannel.Result) {
        val uri: Uri?
        try {
            val file = File(path)
            if (!file.exists()) {
                result.error("file_not_found", "APK 文件不存在", null)
                return
            }
            if (!isInFileProviderScope(file)) {
                result.error("file_not_in_scope", "APK 不在允许共享的目录内", null)
                return
            }
            // Android O+：未授权「安装未知应用」时提前返回，由 Flutter 侧弹引导
            // 对话框（避免 startActivity 时才抛 SecurityException 导致提示不可见）。
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !packageManager.canRequestPackageInstalls()
            ) {
                result.error("need_unknown_sources", "需要开启允许安装未知来源应用", null)
                return
            }
            uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        } catch (e: Exception) {
            result.error("install_failed", "准备安装失败：${e.message}", null)
            return
        }
        try {
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            result.success(true)
        } catch (e: ActivityNotFoundException) {
            // 部分设备/ROM（如个别鸿蒙版本）不支持 ACTION_VIEW 安装 APK，
            // 回退 ACTION_INSTALL_PACKAGE。
            try {
                val fallback = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(fallback)
                result.success(true)
            } catch (e2: Exception) {
                result.error("no_activity", "未找到可安装 APK 的应用", null)
            }
        } catch (e: SecurityException) {
            // 未知来源未授权：引导到「允许安装未知来源应用」设置页
            val can = Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                packageManager.canRequestPackageInstalls()
            if (!can) result.error("need_unknown_sources", "需要开启允许安装未知来源应用", null)
            else result.error("install_rejected", "安装被系统拒绝，请稍后重试", null)
        } catch (e: Exception) {
            result.error("install_failed", e.message, null)
        }
    }

    /// FileProvider scope 预检：APK 必须位于 file_paths.xml 声明覆盖的目录
    /// （files/downloads 或 cache）内，否则 getUriForFile 会抛
    /// IllegalArgumentException，这里给出明确错误码便于定位。
    private fun isInFileProviderScope(file: File): Boolean {
        return try {
            val f = file.canonicalFile
            val filesRoot = filesDir.canonicalFile
            val cacheRoot = cacheDir.canonicalFile
            f.path.startsWith(filesRoot.path + File.separator) ||
                f.path.startsWith(cacheRoot.path + File.separator)
        } catch (e: Exception) {
            false
        }
    }

    /// 获取当前 APK 实际签名证书的 SHA-256 指纹（冒号分隔大写，如
    /// "F1:79:87:...")。用于防重打包自签名校验：Dart 侧与内置期望值比对，
    /// 不一致即判定 APK 被二次签名/重打包，拒绝继续运行。
    private fun getSigningCertSha256(): String? {
        return try {
            val pm = packageManager
            val sigs = if (android.os.Build.VERSION.SDK_INT >= 28) {
                val si = pm.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
                si.signingInfo?.apkContentsSigners ?: return null
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(packageName, PackageManager.GET_SIGNATURES).signatures
            }
            if (sigs.isNullOrEmpty()) return null
            val digest = MessageDigest.getInstance("SHA-256")
                .digest(sigs[0].toByteArray())
            digest.joinToString(":") { String.format("%02X", it) }
        } catch (e: Exception) {
            Log.e("JieDanSign", "获取签名失败", e)
            null
        }
    }
}

