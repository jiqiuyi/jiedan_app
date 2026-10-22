import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import 'package:intl/intl.dart';

import '../api_client.dart';
import '../app_state.dart';
import '../constants.dart';
import '../database.dart';
import '../services/device_info_reporter.dart';
import '../theme.dart';
import 'login_page.dart';
import '../widgets/app_ui.dart';

/// 意见反馈页：在线提交 Bug / 更新建议 / 其他。
/// v1.15.0：弃用邮箱上报方式，改为实时在线提交到服务器（需登录，token 鉴权），
/// 成功后立即可在「我的反馈」中看到；后端按 uid 记录提交人。
class FeedbackPage extends StatefulWidget {
const   FeedbackPage({super.key});

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  final _contentCtrl = TextEditingController();
  final _contactCtrl = TextEditingController();
  FeedbackType _type = FeedbackType.suggestion;
  bool _submitting = false;

  @override
  void dispose() {
    _contentCtrl.dispose();
    _contactCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final content = _contentCtrl.text.trim();
    if (content.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.instance.t('feedback_content_required'))),
      );
      return;
    }
    if (!AppState.instance.loggedIn) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(L10n.instance.t('common_login_required')),
          content: Text(L10n.instance.t('feedback_login_required_desc')),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(L10n.instance.t('common_cancel'))),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(L10n.instance.t('common_go_login')),
            ),
          ],
        ),
      );
      if (go == true && mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => LoginPage()),
        );
      }
      return;
    }

    setState(() => _submitting = true);
    String feedbackId = '';
    String? err;
    try {
      // v1.26.0：提交前按上报开关决定是否附带最小化设备信息（4 项非敏感）；
      // 开关关闭或读取失败时为空串，后端按缺失处理，不影响提交成功。
      var payload = DeviceInfoPayload();
      if (await DeviceInfoReporter.instance.reportingEnabled()) {
        payload = await DeviceInfoReporter.instance.collect();
      }
      final res = await ApiClient.instance.submitFeedback(
        type: _type.name,
        content: content,
        contact: _contactCtrl.text.trim(),
        deviceModel: payload.deviceModel,
        osVersion: payload.osVersion,
        appVersion: payload.appVersion,
        buildNumber: payload.buildNumber,
      );
      feedbackId = '${res['feedbackId']}';
    } catch (e) {
      err = '$e';
    }

    // 无论在线提交成功与否，都先在本地反馈箱留档：
    // - 成功：记录服务器 id 以便后续合并作者回复；
    // - 失败：标记为「未同步」草稿，标题栏提示，下拉刷新可重试同步。
    await AppDb.instance.insertFeedback(
      type: _type.index,
      content: content,
      contact: _contactCtrl.text.trim(),
      serverId: err == null ? int.tryParse(feedbackId) : null,
      synced: err == null ? 1 : 0,
    );

    if (!mounted) return;
    setState(() => _submitting = false);
    final ok = err == null;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.instance.t('feedback_submit_failed_local', args: {'err':err}))),
      );
      return;
    }

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.instance.t('feedback_received')),
        content: Text(
          L10n.instance.t('i18n_113', args: {'v0': feedbackId}),
        ),
        actions: [
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            child: Text(L10n.instance.t('common_done')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(L10n.instance.t('settings_func_feedback')),
        actions: [
          IconButton(
            icon: Icon(Icons.inbox_outlined),
            tooltip: L10n.instance.t('feedback_my'),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => MyFeedbackPage()),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 类型选择
          Text(L10n.instance.t('feedback_type'), style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final t in FeedbackType.values)
                AppFilterChip(
                  label: t.label,
                  selected: _type == t,
                  onTap: () => setState(() => _type = t),
                ),
            ],
          ),
          SizedBox(height: 16),
          // 内容
          Text(L10n.instance.t('feedback_content'), style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          SizedBox(height: 8),
          TextField(
            controller: _contentCtrl,
            maxLines: 6,
            maxLength: 500,
            decoration: InputDecoration(
              hintText: _type == FeedbackType.bug
                  ? L10n.instance.t('i18n_574')
                  : L10n.instance.t('i18n_573'),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              filled: true,
              fillColor: Colors.white,
            ),
          ),
          SizedBox(height: 8),
          // 联系方式
          Text(L10n.instance.t('feedback_contact'), style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          SizedBox(height: 8),
          TextField(
            controller: _contactCtrl,
            decoration: InputDecoration(
              hintText: L10n.instance.t('feedback_page_phone_wechat'),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              filled: true,
              fillColor: Colors.white,
            ),
          ),
          SizedBox(height: 20),
          SizedBox(
            height: 48,
            child: FilledButton(
              onPressed: _submitting ? null : _submit,
              child: Text(_submitting ? L10n.instance.t('common_submitting') : L10n.instance.t('feedback_submit')),
            ),
          ),
          SizedBox(height: 12),
          Center(
            child: Text(
              L10n.instance.t('i18n_189'),
              style: TextStyle(color: AppTheme.textSub, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// 我的反馈列表：展示本地反馈箱（含服务器作者回复），支持下拉刷新从服务器
/// 拉取最新回复状态；离线时展示本地数据并标注「未同步 / 离线」。
/// v1.16.0：新增作者回复展示与服务器合并。
class MyFeedbackPage extends StatefulWidget {
const   MyFeedbackPage({super.key});

  @override
  State<MyFeedbackPage> createState() => _MyFeedbackPageState();
}

class _MyFeedbackPageState extends State<MyFeedbackPage> {
  final _fmt = DateFormat('yyyy-MM-dd HH:mm');
  List<Map<String, Object?>> _list = [];
  String? _syncError; // 最近一次服务器同步失败原因（离线时展示）

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await AppDb.instance.getFeedbacks();
    if (!mounted) return;
    setState(() {
      _list = rows;
    });
    // 已登录则拉取服务器最新回复状态并合并到本地
    if (AppState.instance.loggedIn) {
      await _syncFromServer();
    }
  }

  /// 从服务器拉取我的反馈，合并作者回复到本地并刷新列表。
  /// 未登录 / 网络异常时静默降级为本地数据（_syncError 标注离线）。
  Future<void> _syncFromServer() async {
    String? err;
    try {
      final res =
          await ApiClient.instance.fetchMyFeedbacks();
      final items = (res['feedbacks'] as List? ?? []);
      for (final it in items.cast<Map<String, dynamic>>()) {
        final typeName = (it['type'] ?? 'suggestion').toString();
        var typeIdx = FeedbackType.other.index;
        for (var t = 0; t < FeedbackType.values.length; t++) {
          if (FeedbackType.values[t].name == typeName) {
            typeIdx = t;
            break;
          }
        }
        final reply = it['reply'] as String?;
        final replied =
            it['repliedAt'] == null ? null : (it['repliedAt'] as num).toInt();
        await AppDb.instance.upsertFeedbackFromServer(
          serverId: (it['id'] as num).toInt(),
          type: typeIdx,
          content: (it['content'] ?? '').toString(),
          contact: (it['contact'] ?? '').toString(),
          createdAt: (it['createdAt'] as num).toInt(),
          reply: reply,
          repliedAt: replied,
        );
      }
    } catch (e) {
      err = '$e';
    }
    // 重新读取本地（含合并结果），离线时保留原数据并标注
    final rows = await AppDb.instance.getFeedbacks();
    if (!mounted) return;
    setState(() {
      _list = rows;
      _syncError = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(L10n.instance.t('feedback_my')),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh),
            tooltip: L10n.instance.t('feedback_sync_replies'),
            onPressed: () async {
              if (!AppState.instance.loggedIn) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(L10n.instance.t('feedback_sync_login_tip'))),
                );
                return;
              }
              await _syncFromServer();
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _syncFromServer,
        child: _list.isEmpty
            ? ListView(
                physics: AlwaysScrollableScrollPhysics(),
                children: [
                  AppEmpty(
                    icon: Icons.feedback_outlined,
                    title: L10n.instance.t('feedback_empty'),
                  ),
                ],
              )
            : ListView.builder(
                physics: AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(top: 8, bottom: 24),
                itemCount: _list.length + (_syncError != null ? 1 : 0),
                itemBuilder: (context, i) {
                  if (_syncError != null && i == _list.length) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                      child: Text(
                        L10n.instance.t('i18n_306'),
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.warn),
                      ),
                    );
                  }
                  final m = _list[i];
                  return _FeedbackCard(m: m, fmt: _fmt);
                },
              ),
      ),
    );
  }
}

/// 单条反馈卡片：类型 / 时间 / 内容 / 联系方式 / 作者回复 / 未同步标注。
class _FeedbackCard extends StatelessWidget {
const   _FeedbackCard({required this.m, required this.fmt});
  final Map<String, Object?> m;
  final DateFormat fmt;

  @override
  Widget build(BuildContext context) {
    final type = FeedbackType.values[m['type'] as int];
    final dt = DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int);
    final contact = (m['contact'] as String?) ?? '';
    final reply = (m['reply'] as String?) ?? '';
    final repliedAt = m['replied_at'];
    final synced = (m['synced'] as int?) ?? 1;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(AppRadius.xs),
                  ),
                  child: Text(
                    type.label,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (synced == 0) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.warn.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(AppRadius.xs),
                    ),
                    child: Text(
                      L10n.instance.t('i18n_437'),
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.warn,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                Text(
                  fmt.format(dt),
                  style: const TextStyle(fontSize: 11, color: AppTheme.textSub),
                ),
              ],
            ),
            SizedBox(height: 8),
            Text(
              (m['content'] as String?) ?? '',
              style: const TextStyle(fontSize: 14, height: 1.5),
            ),
            if (contact.isNotEmpty) ...[
              SizedBox(height: 6),
              Text(L10n.instance.t('feedback_contact_prefix2', args: {'contact':contact}),
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSub)),
            ],
            // 作者回复（v1.16.0）：视觉区分，绿色标签 + 回复时间 + 内容
            if (reply.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.success.withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                  border: Border.all(
                      color: AppTheme.success.withValues(alpha: 0.35)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.mark_email_read_outlined,
                            size: 15, color: AppTheme.success),
                        const SizedBox(width: 4),
                        Text(
                          L10n.instance.t('i18n_112'),
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.success,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (repliedAt != null) ...[
                          const SizedBox(width: 8),
                          Text(
                            fmt.format(
                                DateTime.fromMillisecondsSinceEpoch(repliedAt as int)),
                            style: const TextStyle(
                                fontSize: 11, color: AppTheme.textSub),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      reply,
                      style: const TextStyle(fontSize: 13, height: 1.5),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
