package com.jiedan.guanjia

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/**
 * 到账通知解析服务：仅读取系统公开推送的收款/到账通知，
 * 绝不登录任何第三方 App、不抓取 App 内部账单数据库（守住权限边界）。
 *
 * 解析出的「金额 + 到账时间」暂存到本地队列，由 App 网络层携带登录态
 * 上报后端做匹配；匹配失败自动进入人工抽查队列，不依赖单一来源。
 *
 * 可靠性说明（系统差异）：
 * - 不同厂商系统对通知监听的生命周期管理不同（MIUI / EMUI / ColorOS），
 *   存在杀后台、通知折叠、权限丢失导致漏报的客观差异；
 * - 已做「监听启用 + 开机自启」的轻量保活，不做激进流氓驻留手段；
 * - 建议引导用户将本应用加入电池优化白名单（只管主动引导一次，不循环弹窗）。
 */
class PayNoticeListenerService : NotificationListenerService() {

    companion object {
        const val TAG = "PayNotice"
        // 暂存队列 key（App 网络层轮询取走后清空）
        const val PREFS = "jiedan_pay_notice"
        const val KEY_PENDING = "pending_reports"
        const val MAX_PENDING = 200

        /** 监听器是否已被系统授予「通知使用权」（App 侧引导用）。 */
        fun isEnabled(context: Context): Boolean {
            val flat = Settings.Secure.getString(
                context.contentResolver, "enabled_notification_listeners")
            if (flat.isNullOrEmpty()) return false
            val comp = context.packageName + "/" +
                    PayNoticeListenerService::class.java.name
            return flat.split(':').any { it.equals(comp, ignoreCase = true) }
        }

        /** 获取 App 内最近暂存的待上报到账记录，取走即清空（Flutter 侧拉取）。 */
        fun takePending(context: Context): List<Map<String, Any>> {
            val sp = getSp(context)
            val raw = sp.getString(KEY_PENDING, null) ?: return emptyList()
            val list = mutableListOf<Map<String, Any>>()
            try {
                val arr = JSONArray(raw)
                for (i in 0 until arr.length()) {
                    val o = arr.getJSONObject(i)
                    list.add(mapOf(
                        "amount" to o.optDouble("amount"),
                        "ts" to o.optLong("ts"),
                        "source" to o.optString("source")
                    ))
                }
            } catch (e: Exception) {
                Log.w(TAG, "解析暂存队列失败", e)
            }
            sp.edit().remove(KEY_PENDING).apply()
            return list
        }

        fun pendingCount(context: Context): Int = takePending(context).size

        private fun getSp(context: Context): SharedPreferences =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        /** 追加一条解析结果到暂存队列（容错：队列损坏则重建）。 */
        private fun appendPending(context: Context, amount: Double, ts: Long, source: String) {
            val sp = getSp(context)
            var arr = JSONArray()
            val prev = sp.getString(KEY_PENDING, null)
            if (!prev.isNullOrEmpty()) {
                try {
                    arr = JSONArray(prev)
                } catch (e: Exception) {
                    arr = JSONArray() // 队列损坏直接重建，不阻塞主流程
                }
            }
            val item = JSONObject()
            item.put("amount", amount)
            item.put("ts", ts)
            item.put("source", source)
            arr.put(item)
            // 防止队列无限增长
            while (arr.length() > MAX_PENDING) arr.remove(0)
            sp.edit().putString(KEY_PENDING, arr.toString()).apply()
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        super.onNotificationPosted(sbn)
        val pkg = sbn.packageName
        // 只关注微信 / 支付宝的收款通知
        if (!isTargetPackage(pkg)) return
        val extras = sbn.notification?.extras ?: return
        val text = mutableListOf<CharSequence>()
        extras.getCharSequence("android.text")?.let { text.add(it) }
        extras.getCharSequenceArray("android.textLines")?.forEach { text.add(it) }
        val title = extras.getCharSequence("android.title")?.toString() ?: ""
        val body = text.joinToString(" ")
        if (title.isBlank() && body.isBlank()) return

        val amount = parseAmount(title, body) ?: return
        // 到账时间：优先取通知时间，异常则退回当前时间（容错）
        val ts = try {
            sbn.postTime
        } catch (e: Exception) {
            System.currentTimeMillis()
        }
        val source = if (pkg.contains("tencent")) "wechat" else "alipay"
        appendPending(this, amount, ts, source)
        Log.i(TAG, "解析到账通知: $source $amount at $ts")
    }

    /** 是否微信/支付宝渠道（按包名判断，避免误解析第三方假通知）。 */
    private fun isTargetPackage(pkg: String): Boolean {
        return pkg.contains("com.tencent.mm") ||          // 微信
                pkg.startsWith("com.alipay") ||            // 支付宝
                pkg.contains("alipayhk") ||                // 支付宝HK（低概率）
                pkg.contains("alipays")                    // 兼容包名变体
    }

    /**
     * 从通知 title/body 提取到账金额（元）。
     * 支持的常见文案：
     *  - 微信：收款到账 ¥9.50 / 微信支付收款 9.50元 / 收款金额：9.50
     *  - 支付宝：支付宝到账 9.50元 / 到账提醒 9.50 元
     * 仅识别带「到账 / 收款 / 收入」语义的文本，避免误把「支付成功支出¥xx」当收入。
     * 解析失败返回 null（进容错路径，交由抽查兜底，不崩溃）。
     */
    private fun parseAmount(title: String, body: String): Double? {
        // 只处理含收入语义的文案
        val text = "$title $body"
        val hasIncome = text.contains("到账") || text.contains("收款") || text.contains("收入")
        if (!hasIncome) return null
        // 排除明显的支出/退款/消费语义
        if (text.contains("支出") || text.contains("退款") || text.contains("消费") ||
            text.contains("转账成功") || text.contains("付款成功")) return null

        // 匹配 ¥9.50 / 9.50元 / 9.50 元 / 金额:9.50 等
        val patterns = listOf(
            Regex("""[¥￥]\s*(\d{1,3}(?:\.\d{1,2})?)"""),
            Regex("""收款金额\s*[:：]?\s*(\d{1,3}(?:\.\d{1,2})?)"""),
            Regex("""(\d{1,3}\.\d{2})\s*元"""),
            Regex("""收款\s*(\d{1,3}(?:\.\d{1,2})?)\s*元"""),
        )
        for (re in patterns) {
            val m = re.find(text) ?: continue
            return m.groupValues[1].toDoubleOrNull()?.let { if (it > 0) it else null }
        }
        return null
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        Log.i(TAG, "通知监听服务已连接")
    }
}
