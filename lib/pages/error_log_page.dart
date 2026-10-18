import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../theme.dart';

/// 「设置-关于-错误日志」：展示本地错误日志（error_YYYYMMDD.log），
/// 便于远程诊断 DB 打开 / 恢复 / 查询失败等异常时，让用户一键复制日志内容
/// 反馈给开发者。日志由 ErrorReporter 写入 <应用文档>/logs/ 目录（按天滚动，
/// 保留最近 3 天，单文件上限 512KB 超限截断保留尾部 256KB）。
class ErrorLogPage extends StatefulWidget {
  const ErrorLogPage({super.key});

  @override
  State<ErrorLogPage> createState() => _ErrorLogPageState();
}

class _ErrorLogPageState extends State<ErrorLogPage> {
  bool _loading = true;
  String? _error;
  List<_LogFile> _files = const [];
  String _selectedPath = '';
  String _content = '';
  String _info = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final dir = await getApplicationDocumentsDirectory();
      final logDir = Directory(p.join(dir.path, 'logs'));
      if (!await logDir.exists()) {
        setState(() {
          _loading = false;
          _info = '暂无错误日志（logs 目录不存在）';
        });
        return;
      }
      final entries = await logDir
          .list()
          .where((e) =>
              e is File &&
              e.path.endsWith('.log') &&
              p.basename(e.path).startsWith('error_'))
          .toList();
      entries.sort((a, b) => b.path.compareTo(a.path));
      final files = <_LogFile>[];
      for (final e in entries) {
        final f = e as File;
        final stat = await f.stat();
        files.add(_LogFile(path: f.path, size: stat.size));
      }
      _files = files;
      if (files.isEmpty) {
        setState(() {
          _loading = false;
          _info = '暂无错误日志';
        });
        return;
      }
      await _openFile(files.first.path);
    } catch (e, st) {
      setState(() {
        _loading = false;
        _error = '日志读取失败：$e\n${st.toString().split('\n').take(3).join('\n')}';
      });
    }
  }

  Future<void> _openFile(String path) async {
    final f = File(path);
    if (!await f.exists()) return;
    // 文件上限 512KB（截断后 ≤256KB），直接整体读入展示。
    final bytes = await f.readAsBytes();
    // 按 UTF-8 宽容解码，避免个别乱码字节中断展示。
    final text = utf8.decode(bytes, allowMalformed: true);
    setState(() {
      _selectedPath = path;
      _content = text;
      _info = '${p.basename(path)} · ${bytes.length} 字节 · 共 ${_files.length} 个日志文件';
    });
  }

  Future<void> _copyAll() async {
    final buf = StringBuffer();
    for (final f in _files) {
      buf.writeln('===== ${p.basename(f.path)} =====');
      final bytes = await File(f.path).readAsBytes();
      buf.writeln(utf8.decode(bytes, allowMalformed: true));
      buf.writeln();
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('日志已复制到剪贴板，可直接粘贴发给开发者')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('错误日志'),
        actions: [
          if (!_loading && _files.isNotEmpty)
            IconButton(
              tooltip: '复制全部日志',
              icon: const Icon(Icons.copy_all_outlined),
              onPressed: _copyAll,
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 40, color: AppTheme.danger),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.tonal(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (_files.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.inbox_outlined, size: 40),
              const SizedBox(height: 12),
              const Text('暂无错误日志'),
              const SizedBox(height: 4),
              Text(_info, style: const TextStyle(color: AppTheme.textSub)),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              const Icon(Icons.info_outline,
                  size: 16, color: AppTheme.textSub),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _info,
                  style:
                      const TextStyle(fontSize: 12, color: AppTheme.textSub),
                ),
              ),
            ],
          ),
        ),
        if (_files.length > 1)
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final f in _files)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(
                          '${p.basename(f.path)} (${f.size}B)'),
                      selected: f.path == _selectedPath,
                      onSelected: (_) => _openFile(f.path),
                    ),
                  ),
              ],
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: _content.isEmpty
              ? const Center(child: Text('日志为空'))
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    _content,
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      height: 1.4,
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _LogFile {
  final String path;
  final int size;
  _LogFile({required this.path, required this.size});
}
