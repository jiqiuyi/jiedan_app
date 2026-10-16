package com.jiedan.guanjia

import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
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

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // 冷启动：桌面小组件「记一笔」直接拉起极速记账面板（不经过首页）
        if (intent?.action == LedgerWidgetProvider.ACTION_QUICK_LEDGER) {
            pendingQuickLedger = true
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // 热启动/前台恢复：小组件「记一笔」置位意图，由 Flutter 侧轮询消费
        if (intent.action == LedgerWidgetProvider.ACTION_QUICK_LEDGER) {
            pendingQuickLedger = true
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
    }

    /// 拉起系统安装界面安装 APK。FileProvider authority 与 AndroidManifest 中
    /// "${applicationId}.fileprovider" 保持一致。
    private fun installApk(path: String, result: MethodChannel.Result) {
        try {
            val file = File(path)
            if (!file.exists()) {
                result.error("file_not_found", "APK 文件不存在", null)
                return
            }
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            result.success(true)
        } catch (e: ActivityNotFoundException) {
            result.error("no_activity", "未找到可安装 APK 的应用", null)
        } catch (e: SecurityException) {
            // 未知来源未授权：引导到「允许安装未知来源应用」设置页
            val can = packageManager.canRequestPackageInstalls()
            if (!can) result.error("need_unknown_sources", "需要开启允许安装未知来源应用", null)
            else result.error("install_rejected", "安装被系统拒绝，请稍后重试", null)
        } catch (e: Exception) {
            result.error("install_failed", e.message, null)
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

