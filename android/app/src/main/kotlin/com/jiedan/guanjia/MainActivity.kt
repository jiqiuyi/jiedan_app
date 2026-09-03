package com.jiedan.guanjia

import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
import android.util.Log
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.jiedan.guanjia/signature"
    private val PAY_CHANNEL = "com.jiedan.guanjia/paylistener"

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

