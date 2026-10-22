import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import 'package:intl/intl.dart';

import '../services/sync_service.dart';
import '../theme.dart';
import '../widgets/app_ui.dart';

/// 云端同步冲突解决弹层（v1.20.0）。
///
/// 在「同步冲突处理策略」选择「有冲突时先问我」后，若云端与本地对同一行
/// 都有更新，会先停留在此处由用户逐条决定：
///   采用云端 = 用服务器版本覆盖本地；保留本地 = 保持本地版本（本行不再重复提示）。
/// 业务数据始终保存在本地 SQLite，本弹层只决定同步数据的合并方向，不改变存储。
Future<void> showConflictResolverSheet(BuildContext context) {
  return showAppSheet<void>(
    context,
    isScrollControlled: true,
    builder: (ctx) => _ConflictSheet(),
  );
}

class _ConflictSheet extends StatefulWidget {
const   _ConflictSheet();

  @override
  State<_ConflictSheet> createState() => _ConflictSheetState();
}

class _ConflictSheetState extends State<_ConflictSheet> {
  final _sync = SyncService.instance;
  final _fmt = DateFormat('yyyy-MM-dd HH:mm');

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: AnimatedBuilder(
        animation: _sync,
        builder: (context, _) {
          final conflicts = _sync.pendingConflicts;
          if (conflicts.isEmpty) {
            // 冲突已全部解决：轻提示并让弹层自行收起。
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && Navigator.of(context).canPop()) {
                Navigator.of(context).pop();
              }
            });
            return SizedBox(
              height: 160,
              child: Center(
                child: Text(L10n.instance.t('conflict_resolver_sheet_no_pending'),
                    style: TextStyle(color: AppTheme.textSub)),
              ),
            );
          }
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.68,
            maxChildSize: 0.92,
            builder: (ctx, scrollCtrl) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                  child: Text(
                    L10n.instance.t('i18n_170', args: {'v0':'${_sync.pendingConflicts.length}'}),
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    L10n.instance.t('i18n_093'),
                    style: TextStyle(fontSize: 12, color: AppTheme.textSub),
                  ),
                ),
                SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    controller: scrollCtrl,
                    itemCount: conflicts.length,
                    itemBuilder: (ctx, i) {
                      final c = conflicts[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 4),
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                          decoration: BoxDecoration(
                            color: AppTheme.bgCard,
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${_tableLabel(c.table)}：${c.title}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.textMain),
                              ),
                              SizedBox(height: 4),
                              Text.rich(
                                TextSpan(
                                  style: const TextStyle(
                                      fontSize: 12, color: AppTheme.textSub),
                                  children: [
                                    TextSpan(
                                      text:
                                          L10n.instance.t('i18n_454', args: {'v0': _fmt.format(DateTime.fromMillisecondsSinceEpoch(c.localTs))}),
                                      style: const TextStyle(
                                          color: AppTheme.textMain),
                                    ),
                                    const TextSpan(text: '  ·  '),
                                    TextSpan(
                                      text:
                                          L10n.instance.t('i18n_094', args: {'v0': _fmt.format(DateTime.fromMillisecondsSinceEpoch(c.serverTs))}),
                                      style: const TextStyle(
                                          color: AppTheme.primary),
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(height: 6),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  AppButton(
                                    label: L10n.instance.t('conflict_keep_local'),
                                    icon: Icons.phone_android,
                                    kind: AppButtonKind.ghost,
                                    size: AppButtonSize.small,
                                    expand: false,
                                    onPressed: () =>
                                        _sync.keepLocalVersions([c]),
                                  ),
                                  SizedBox(width: 4),
                                  AppButton(
                                    label: L10n.instance.t('conflict_use_cloud'),
                                    icon: Icons.cloud_done,
                                    kind: AppButtonKind.primary,
                                    size: AppButtonSize.small,
                                    expand: false,
                                    onPressed: () =>
                                        _sync.applyServerVersions([c]),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                AppCardDivider(),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: AppButton(
                          label: L10n.instance.t('conflict_ignore'),
                          kind: AppButtonKind.secondary,
                          size: AppButtonSize.small,
                          expand: true,
                          onPressed: _sync.clearPendingConflicts,
                        ),
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: AppButton(
                          label: L10n.instance.t('conflict_keep_all_local'),
                          kind: AppButtonKind.secondary,
                          size: AppButtonSize.small,
                          expand: true,
                          onPressed: () =>
                              _sync.keepLocalVersions(List.of(conflicts)),
                        ),
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: AppButton(
                          label: L10n.instance.t('conflict_use_all_cloud'),
                          kind: AppButtonKind.primary,
                          size: AppButtonSize.small,
                          expand: true,
                          onPressed: () =>
                              _sync.applyServerVersions(List.of(conflicts)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  static String _tableLabel(String t) => switch (t) {
    'customers' => L10n.instance.t('common_customer'),
    'projects' => L10n.instance.t('common_project'),
    'payments' => L10n.instance.t('conflict_resolver_sheet_collect'),
    'quotes' => L10n.instance.t('common_quote'),
    'pending_collections' => L10n.instance.t('constants_pending_collection'),
    'milestones' => L10n.instance.t('common_milestone'),
    'contracts' => L10n.instance.t('common_contract'),
    _ => t,
  };
}
