import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/sync_service.dart';
import '../theme.dart';

/// 云端同步冲突解决弹层（v1.20.0）。
///
/// 在「同步冲突处理策略」选择「有冲突时先问我」后，若云端与本地对同一行
/// 都有更新，会先停留在此处由用户逐条决定：
///   采用云端 = 用服务器版本覆盖本地；保留本地 = 保持本地版本（本行不再重复提示）。
/// 业务数据始终保存在本地 SQLite，本弹层只决定同步数据的合并方向，不改变存储。
Future<void> showConflictResolverSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => const _ConflictSheet(),
  );
}

class _ConflictSheet extends StatefulWidget {
  const _ConflictSheet();

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
            return const SizedBox(
              height: 160,
              child: Center(
                child: Text('没有待处理的同步冲突了',
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
                    '同步冲突（${_sync.pendingConflicts.length}）',
                    style:
                        const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    '云端与本地对同一条数据都有更新，请选择采用哪一版：',
                    style: TextStyle(fontSize: 12, color: AppTheme.textSub),
                  ),
                ),
                const SizedBox(height: 8),
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
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${_tableLabel(c.table)}：${c.title}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.textMain),
                              ),
                              const SizedBox(height: 4),
                              Text.rich(
                                TextSpan(
                                  style: const TextStyle(
                                      fontSize: 12, color: AppTheme.textSub),
                                  children: [
                                    TextSpan(
                                      text:
                                          '本地：${_fmt.format(DateTime.fromMillisecondsSinceEpoch(c.localTs))}',
                                      style: const TextStyle(
                                          color: AppTheme.textMain),
                                    ),
                                    const TextSpan(text: '  ·  '),
                                    TextSpan(
                                      text:
                                          '云端：${_fmt.format(DateTime.fromMillisecondsSinceEpoch(c.serverTs))}',
                                      style: const TextStyle(
                                          color: AppTheme.primary),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  TextButton.icon(
                                    onPressed: () =>
                                        _sync.keepLocalVersions([c]),
                                    icon: const Icon(Icons.phone_android,
                                        size: 16),
                                    label: const Text('保留本地'),
                                    style: TextButton.styleFrom(
                                        foregroundColor: AppTheme.textMain),
                                  ),
                                  const SizedBox(width: 4),
                                  FilledButton.icon(
                                    onPressed: () =>
                                        _sync.applyServerVersions([c]),
                                    icon: const Icon(Icons.cloud_done,
                                        size: 16),
                                    label: const Text('采用云端'),
                                    style: FilledButton.styleFrom(
                                      backgroundColor: AppTheme.primary,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 8),
                                    ),
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
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _sync.clearPendingConflicts,
                          style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  vertical: 10, horizontal: 8)),
                          child: const Text('暂时不管',
                              style: TextStyle(
                                  fontSize: 13, color: AppTheme.textMain)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () =>
                              _sync.keepLocalVersions(List.of(conflicts)),
                          style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  vertical: 10, horizontal: 8)),
                          child: const Text('全部保留本地',
                              style: TextStyle(
                                  fontSize: 13, color: AppTheme.textMain)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton(
                          onPressed: () =>
                              _sync.applyServerVersions(List.of(conflicts)),
                          style: FilledButton.styleFrom(
                            backgroundColor: AppTheme.primary,
                            padding: const EdgeInsets.symmetric(
                                vertical: 10, horizontal: 8),
                          ),
                          child: const Text('全部采用云端',
                              style: TextStyle(fontSize: 13)),
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
    'customers' => '客户',
    'projects' => '项目',
    'payments' => '收款',
    'quotes' => '报价',
    'pending_collections' => '待收款',
    'milestones' => '里程碑',
    'contracts' => '合同',
    _ => t,
  };
}
