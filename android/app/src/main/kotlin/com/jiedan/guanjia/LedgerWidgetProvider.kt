package com.jiedan.guanjia

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews
import org.json.JSONArray
import org.json.JSONObject

/**
 * 接单管家·记账 桌面小组件 Provider（4x2 中号）。
 *
 * 数据桥接：Flutter 侧每次记账增删改后通过 home_widget 的
 * HomeWidget.saveWidgetData 把「本月支出/收入 + 最近 3 条」写入
 * SharedPreferences("HomeWidgetPreferences") 的 key [DATA_KEY]（JSON 字符串），
 * 再 HomeWidget.updateWidget 广播刷新本 Provider。
 *
 * 点击行为：
 *  - 小组件整体点击 -> 打开 App 主页；
 *  - 「记一笔」按钮 -> PendingIntent 携带 action [ACTION_QUICK_LEDGER] 指向
 *    MainActivity，由 MainActivity 置位 intent 标志，Flutter 侧轮询消费后
 *    直接弹出极速记账面板（不经过首页）。
 */
class LedgerWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (appWidgetId in appWidgetIds) {
            // 任何构建/渲染异常都不允许冒泡到系统，否则 Launcher 会显示
            // 「加载窗口小工具时出现问题」；异常时回退到极简可渲染布局。
            val views =
                try {
                    buildRemoteViews(context)
                } catch (e: Exception) {
                    buildFallbackRemoteViews(context)
                }
            try {
                appWidgetManager.updateAppWidget(appWidgetId, views)
            } catch (e: Exception) {
                // 单实例更新失败不影响其他实例
            }
        }
    }

    companion object {
        const val ACTION_QUICK_LEDGER = "com.jiedan.guanjia.QUICK_LEDGER"

        /** home_widget 插件写入数据的 SharedPreferences 文件名（插件常量 HomeWidgetPlugin.PREFERENCES）。 */
        const val PREFS_FILE = "HomeWidgetPreferences"

        /** 与 lib/services/ledger_widget_bridge.dart 约定的缓存键。 */
        const val DATA_KEY = "ledger_widget_data"

        const val COLOR_BRAND_BLUE = 0xFF4A5AF0.toInt()
        const val COLOR_INCOME_GREEN = 0xFF16A085.toInt()

        fun buildRemoteViews(context: Context): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.widget_ledger)
            try {
                populateRemoteViews(context, views)
            } catch (e: Exception) {
                // 数据渲染异常（如个别 ROM 对 setTextColor/visibility 不兼容）时
                // 回退极简布局，保证永远可渲染，不出现「加载窗口小工具时出现问题」。
                return buildFallbackRemoteViews(context)
            }
            return views
        }

        /** 渲染兜底布局：仅标题 + 空态提示，不含任何点击/着色/显隐操作。 */
        fun buildFallbackRemoteViews(context: Context): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.widget_ledger)
            views.setTextViewText(R.id.widget_month_expense, "¥0.00")
            views.setTextViewText(R.id.widget_month_income, "¥0.00")
            views.setViewVisibility(R.id.widget_recent_list, View.GONE)
            views.setViewVisibility(R.id.widget_empty, View.VISIBLE)
            return views
        }

        private fun populateRemoteViews(context: Context, views: RemoteViews) {
            // 小组件整体点击 -> 打开 App 主页
            val openAppIntent =
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            views.setOnClickPendingIntent(
                R.id.widget_root,
                buildPendingIntent(context, openAppIntent, requestCode = 1),
            )

            // 「记一笔」-> 拉起极速记账面板（action 标识，MainActivity 置位意图）
            val quickLedgerIntent =
                Intent(context, MainActivity::class.java)
                    .setAction(ACTION_QUICK_LEDGER)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            views.setOnClickPendingIntent(
                R.id.btn_quick_ledger,
                buildPendingIntent(context, quickLedgerIntent, requestCode = 0),
            )

            // 数据渲染：本月支出/收入 + 最近 3 条
            val prefs = context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
            val jsonStr = prefs.getString(DATA_KEY, null)
            val data = parseData(jsonStr)

            if (data == null) {
                // 无数据：空态引导 + 统计清零
                views.setTextViewText(R.id.widget_month_expense, "¥0.00")
                views.setTextViewText(R.id.widget_month_income, "¥0.00")
                views.setViewVisibility(R.id.widget_recent_list, View.GONE)
                views.setViewVisibility(R.id.widget_empty, View.VISIBLE)
            } else {
                views.setTextViewText(
                    R.id.widget_month_expense,
                    "¥" + fmtYuan(data.monthExpense),
                )
                views.setTextViewText(
                    R.id.widget_month_income,
                    "¥" + fmtYuan(data.monthIncome),
                )
                views.setViewVisibility(R.id.widget_recent_list, View.VISIBLE)
                views.setViewVisibility(R.id.widget_empty, View.GONE)

                val recent = data.recent
                for (i in 0 until 3) {
                    val catId = when (i) {
                        0 -> R.id.widget_recent_1_cat
                        1 -> R.id.widget_recent_2_cat
                        else -> R.id.widget_recent_3_cat
                    }
                    val amtId = when (i) {
                        0 -> R.id.widget_recent_1_amt
                        1 -> R.id.widget_recent_2_amt
                        else -> R.id.widget_recent_3_amt
                    }
                    val rowId = when (i) {
                        0 -> R.id.widget_recent_1
                        1 -> R.id.widget_recent_2
                        else -> R.id.widget_recent_3
                    }
                    if (i < recent.size) {
                        val item = recent[i]
                        views.setViewVisibility(rowId, View.VISIBLE)
                        views.setTextViewText(catId, item.category)
                        val sign = if (item.kind == 0) "-" else "+"
                        views.setTextViewText(amtId, sign + "¥" + fmtYuan(item.amount))
                        views.setTextColor(
                            amtId,
                            if (item.kind == 0) COLOR_BRAND_BLUE else COLOR_INCOME_GREEN,
                        )
                    } else {
                        views.setViewVisibility(rowId, View.GONE)
                    }
                }
            }
        }

        private fun buildPendingIntent(
            context: Context,
            intent: Intent,
            requestCode: Int,
        ): PendingIntent {
            val flags =
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            return PendingIntent.getActivity(context, requestCode, intent, flags)
        }

        private data class WidgetData(
            val monthExpense: Int,
            val monthIncome: Int,
            val recent: List<RecentItem>,
        )

        private data class RecentItem(
            val category: String,
            val amount: Int,
            val kind: Int,
        )

        private fun parseData(jsonStr: String?): WidgetData? {
            if (jsonStr.isNullOrBlank()) return null
            return try {
                val root = JSONObject(jsonStr)
                val recent = JSONArray()
                val recentArr = root.optJSONArray("recent") ?: JSONArray()
                for (i in 0 until recentArr.length()) {
                    val obj = recentArr.optJSONObject(i) ?: continue
                    val category = obj.optString("category", "")
                    val amount = obj.optInt("amount", 0)
                    val kind = obj.optInt("kind", 0)
                    recent.put(RecentItem(category, amount, kind))
                }
                WidgetData(
                    monthExpense = root.optInt("month_expense", 0),
                    monthIncome = root.optInt("month_income", 0),
                    recent = (0 until recent.length()).map { idx ->
                        val item = recent.get(idx) as RecentItem
                        item
                    },
                )
            } catch (e: Exception) {
                null
            }
        }

        /** 分 -> 元字符串（两位小数），如 12345 -> "123.45"。 */
        fun fmtYuan(fen: Int): String {
            val sign = if (fen < 0) "-" else ""
            val abs = Math.abs(fen)
            val yuan = abs / 100
            val jiao = (abs % 100) / 10
            val li = abs % 10
            return "$sign$yuan.$jiao$li"
        }
    }
}
