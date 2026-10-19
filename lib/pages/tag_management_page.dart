import 'package:flutter/material.dart';

import '../database.dart';
import '../theme.dart';
import '../widgets/app_ui.dart';

/// 标签维护页：维护「行业」「来源」「成本」三类标签字典。
/// 维护结果持久化到本地 SQLite（tag_items 表），
/// 行业 / 来源供新增 / 编辑客户表单下拉选择与客户列表筛选下拉共用，
/// 成本标签供项目成本记录选择。
class TagManagementPage extends StatefulWidget {
  const TagManagementPage({super.key});

  @override
  State<TagManagementPage> createState() => _TagManagementPageState();
}

class _TagManagementPageState extends State<TagManagementPage> {
  static const _kinds = ['industry', 'source', 'cost'];

  final Map<String, List<String>> _tags = {
    for (final k in _kinds) k: <String>[],
  };
  final Map<String, TextEditingController> _ctrls = {
    for (final k in _kinds) k: TextEditingController(),
  };
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _reload() async {
    final db = AppDb.instance;
    final industry = await db.getTagItems('industry');
    final source = await db.getTagItems('source');
    final cost = await db.getTagItems('cost');
    if (!mounted) return;
    setState(() {
      _tags['industry'] = industry;
      _tags['source'] = source;
      _tags['cost'] = cost;
      _loading = false;
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _add(String kind) async {
    final ctrl = _ctrls[kind]!;
    final name = ctrl.text.trim();
    if (name.isEmpty) {
      _toast('请输入标签内容');
      return;
    }
    final ok = await AppDb.instance.addTagItem(kind, name);
    if (!ok) {
      _toast('标签已存在');
      return;
    }
    ctrl.clear();
    _toast('标签已添加');
    _reload();
  }

  Future<void> _remove(String kind, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除标签'),
        content: Text('确认删除「$name」？已使用该标签的客户不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          AppButton(
            label: '删除',
            kind: AppButtonKind.danger,
            size: AppButtonSize.medium,
            expand: false,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await AppDb.instance.deleteTagItem(kind, name);
    _toast('标签已删除');
    _reload();
  }

  Widget _section(String kind, String label, String hint, {String emptyTip = '暂无标签，添加后可在新增 / 编辑客户中下拉选择'}) {
    final tags = _tags[kind] ?? const <String>[];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textMain),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ctrls[kind],
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _add(kind),
                    decoration: InputDecoration(
                      hintText: hint,
                      isDense: true,
                      filled: true,
                      fillColor: AppTheme.textSub.withValues(alpha: 0.05),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                AppButton(
                  label: '添加',
                  kind: AppButtonKind.primary,
                  size: AppButtonSize.medium,
                  expand: false,
                  onPressed: () => _add(kind),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (tags.isEmpty)
              Text(
                emptyTip,
                style: const TextStyle(fontSize: 12.5, color: AppTheme.textSub),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: tags
                    .map((t) => Chip(
                          label: Text(t),
                          deleteIcon: const Icon(Icons.close, size: 16),
                          onDeleted: () => _remove(kind, t),
                          backgroundColor:
                              AppTheme.primary.withValues(alpha: 0.08),
                          side: BorderSide.none,
                          shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(AppRadius.sheet),
                          ),
                          labelStyle: const TextStyle(
                              fontSize: 13, color: AppTheme.textMain),
                          deleteIconColor: AppTheme.textSub,
                          visualDensity: VisualDensity.compact,
                        ))
                    .toList(),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: const Text('标签维护'),
        backgroundColor: AppTheme.bg,
        elevation: 0,
        centerTitle: true,
      ),
      body: _loading
          ? const AppLoading()
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _section('industry', '行业标签', '输入行业标签，如：餐饮、电商、装修'),
                const SizedBox(height: 14),
                _section('source', '来源标签', '输入来源标签，如：朋友介绍、小红书、老客'),
                const SizedBox(height: 14),
                _section('cost', '成本标签', '输入成本标签，如：物料、人工、外包',
                    emptyTip: '暂无标签，添加后可在项目成本中选择'),
                const SizedBox(height: 8),
                const Text(
                  '提示：行业 / 来源标签用于新增 / 编辑客户时快速选择，仍可手动输入；成本标签用于项目成本记录。客户列表筛选下拉同源。',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSub),
                ),
              ],
            ),
    );
  }
}
