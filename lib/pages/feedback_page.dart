import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants.dart';
import '../database.dart';
import '../theme.dart';

/// 开发者反馈接收邮箱
const _feedbackEmail = '1393180767@qq.com';

/// 意见反馈页：提交 Bug / 更新建议 / 其他。
/// 无服务器阶段反馈保存在本地，可一键上报到开发者邮箱或复制内容通过邮件/微信发送。
class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key});

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
        const SnackBar(content: Text('请先填写反馈内容')),
      );
      return;
    }
    setState(() => _submitting = true);
    await AppDb.instance.insertFeedback(
      type: _type.index,
      content: content,
      contact: _contactCtrl.text.trim(),
    );
    if (!mounted) return;
    setState(() => _submitting = false);

    final text =
        '【${_type.label}】\n版本：v${AppConfig.version}\n内容：$content'
        '${_contactCtrl.text.trim().isEmpty ? '' : '\n联系方式：${_contactCtrl.text.trim()}'}';

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('反馈已记录'),
        content: const Text('已保存到本地反馈箱。\n点「上报到邮箱」可直接发给开发者；也可以复制内容手动发送。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('完成'),
          ),
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (ctx.mounted) Navigator.pop(ctx);
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('反馈内容已复制，可粘贴到邮件/微信发送')),
              );
            },
            child: const Text('复制内容'),
          ),
          FilledButton(
            onPressed: () async {
              if (ctx.mounted) Navigator.pop(ctx);
              await _reportByEmail(text);
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已唤起邮件App，点发送即可送达开发者')),
              );
            },
            child: const Text('上报到邮箱'),
          ),
        ],
      ),
    );
  }

  /// 用系统邮件 App 上报反馈到开发者邮箱
  Future<void> _reportByEmail(String text) async {
    final uri = Uri(
      scheme: 'mailto',
      path: _feedbackEmail,
      query:
          'subject=${Uri.encodeQueryComponent('接单管家 反馈（v${AppConfig.version}）')}'
          '&body=${Uri.encodeQueryComponent('$text\n\n— 来自 接单管家 App')}',
    );
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未找到可用的邮件应用，请用「复制内容」手动发送')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('意见反馈'),
        actions: [
          IconButton(
            icon: const Icon(Icons.inbox_outlined),
            tooltip: '我的反馈',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const MyFeedbackPage()),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 类型选择
          const Text('反馈类型', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final t in FeedbackType.values)
                ChoiceChip(
                  label: Text(t.label),
                  selected: _type == t,
                  onSelected: (_) => setState(() => _type = t),
                ),
            ],
          ),
          const SizedBox(height: 16),
          // 内容
          const Text('反馈内容', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(
            controller: _contentCtrl,
            maxLines: 6,
            maxLength: 500,
            decoration: InputDecoration(
              hintText: _type == FeedbackType.bug
                  ? '请描述遇到的问题：在哪个页面、做了什么操作、出现什么现象'
                  : '请描述你的建议：希望新增什么功能、如何改进体验',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              filled: true,
              fillColor: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          // 联系方式
          const Text('联系方式（选填）', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(
            controller: _contactCtrl,
            decoration: InputDecoration(
              hintText: '手机号 / 微信 / 邮箱，方便开发者回复你',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              filled: true,
              fillColor: Colors.white,
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 48,
            child: FilledButton(
              onPressed: _submitting ? null : _submit,
              child: Text(_submitting ? '提交中…' : '提交反馈'),
            ),
          ),
          const SizedBox(height: 12),
          const Center(
            child: Text(
              '开发者邮箱：1393180767@qq.com',
              style: TextStyle(color: AppTheme.textSub, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// 我的反馈列表：查看本地已提交的全部反馈
class MyFeedbackPage extends StatefulWidget {
  const MyFeedbackPage({super.key});

  @override
  State<MyFeedbackPage> createState() => _MyFeedbackPageState();
}

class _MyFeedbackPageState extends State<MyFeedbackPage> {
  final _fmt = DateFormat('yyyy-MM-dd HH:mm');
  List<Map<String, Object?>> _list = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await AppDb.instance.getFeedbacks();
    if (!mounted) return;
    setState(() => _list = rows);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的反馈')),
      body: _list.isEmpty
          ? const Center(
              child: Text('还没有提交过反馈', style: TextStyle(color: AppTheme.textSub)),
            )
          : ListView.builder(
              padding: const EdgeInsets.only(top: 8, bottom: 24),
              itemCount: _list.length,
              itemBuilder: (context, i) {
                final m = _list[i];
                final type = FeedbackType.values[m['type'] as int];
                final dt = DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int);
                final contact = (m['contact'] as String?) ?? '';
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
                                borderRadius: BorderRadius.circular(6),
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
                            const Spacer(),
                            Text(
                              _fmt.format(dt),
                              style: const TextStyle(fontSize: 11, color: AppTheme.textSub),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          (m['content'] as String?) ?? '',
                          style: const TextStyle(fontSize: 14, height: 1.5),
                        ),
                        if (contact.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text('联系：$contact',
                              style: const TextStyle(fontSize: 12, color: AppTheme.textSub)),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
