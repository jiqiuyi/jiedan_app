import 'dart:async';
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
///
/// 可靠性设计（v1.46.20）：
/// - 所有平台通道调用（getApplicationDocumentsDirectory 等）均带超时，
///   超时后按支持目录 / 临时目录逐级降级，全部失败落入错误态而非无限转圈；
/// - 日志读取走 dart:io 本地文件系统，不依赖 DB、不依赖网络；
/// - 「上传日志」POST 到 https://yurouyun.cn/api/logs/upload，带超时；
///   后端无该端点 / 网络异常时自动降级为复制到剪贴板提示粘贴发送。
class ErrorLogPage extends StatefulWidget {
  const ErrorLogPage({super.key});

  @override
  State<ErrorLogPage> createState() => _ErrorLogPageState();
}

class _ErrorLogPageState extends State<ErrorLogPage> {
  bool _loading = true;
  bool _uploading = false;
  String? _error;
  List<_LogFile> _files = const [];
  String _selectedPath = '';
  String _content = '';
  String _info = '';

  /// 平台通道超时：三星等设备偶发 platform channel 无响应，必须限时，
  /// 避免页面永远停在 loading。
  static const Duration _channelTimeout = Duration(seconds: 3);
  /// 本地文件操作超时（dart:io 一般不会挂起，兜底保护）。
  static const Duration _fileTimeout = Duration(seconds: 10);
  /// 上传接口超时。
  static const Duration _uploadTimeout = Duration(seconds: 8);

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
      final logDir = await _resolveLogDir();
      if (!await logDir.exists().timeout(_fileTimeout)) {
        setState(() {
          _loading = false;
          _info = '暂无错误日志（logs 目录不存在）';
        });
        return;
      }
      final list = await logDir.list().toList().timeout(_fileTimeout);
      final entries = list
          .where((e) =>
              e is File &&
              e.path.endsWith('.log') &&
              p.basename(e.path).startsWith('error_'))
          .toList();
      entries.sort((a, b) => b.path.compareTo(a.path));
      final files = <_LogFile>[];
      for (final e in entries) {
        final f = e as File;
        final stat = await f.stat().timeout(_fileTimeout);
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

  /// 解析日志目录：平台通道带超时，失败后按「文档 → 支持 → 临时」逐级降级，
  /// 全部失败抛错由 _load 捕获进入错误态（可重试），绝不无限转圈。
  /// 日志写入端（error_reporter.logError）与读取端使用同一路径规则，
  /// 保证能读到同一批日志文件。
  Future<Directory> _resolveLogDir() async {
    final attempts = <Future<Directory> Function()>[
      () async => Directory(
          p.join((await getApplicationDocumentsDirectory()).path, 'logs')),
      () async => Directory(
          p.join((await getApplicationSupportDirectory()).path, 'logs')),
      () async => Directory(
          p.join((await getTemporaryDirectory()).path, 'logs')),
    ];
    Object? lastErr;
    for (final fn in attempts) {
      try {
        return await fn().timeout(_channelTimeout);
      } catch (e) {
        lastErr = e;
      }
    }
    throw StateError('无法获取应用目录（平台通道无响应：$lastErr）');
  }

  Future<void> _openFile(String path) async {
    final f = File(path);
    if (!await f.exists().timeout(_fileTimeout)) return;
    // 文件上限 512KB（截断后 ≤256KB），直接整体读入展示。
    final bytes = await f.readAsBytes().timeout(_fileTimeout);
    // 按 UTF-8 宽容解码，避免个别乱码字节中断展示。
    final text = utf8.decode(bytes, allowMalformed: true);
    setState(() {
      _selectedPath = path;
      _content = text;
      _info = '${p.basename(path)} · ${bytes.length} 字节 · 共 ${_files.length} 个日志文件';
    });
  }

  /// 组装全部日志文本（复制 / 上传共用）。
  Future<String> _buildAllLogText() async {
    final buf = StringBuffer();
    for (final f in _files) {
      buf.writeln('===== ${p.basename(f.path)} =====');
      final bytes = await File(f.path).readAsBytes().timeout(_fileTimeout);
      buf.writeln(utf8.decode(bytes, allowMalformed: true));
      buf.writeln();
    }
    return buf.toString();
  }

  Future<void> _copyAll() async {
    try {
      final text = await _buildAllLogText();
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('日志已复制到剪贴板，可直接粘贴发给开发者')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('复制失败：$e')),
        );
      }
    }
  }

  /// 上传全部日志到服务器；后端无该端点 / 网络异常 / 超时时，
  /// 降级为复制到剪贴板并提示粘贴发送（不改后端）。
  Future<void> _uploadAll() async {
    if (_uploading) return;
    setState(() => _uploading = true);
    String text = '';
    try {
      text = await _buildAllLogText();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('日志读取失败：$e')),
        );
      }
      if (mounted) setState(() => _uploading = false);
      return;
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final uri = Uri.parse('https://yurouyun.cn/api/logs/upload');
      final req = await client.postUrl(uri).timeout(const Duration(seconds: 5));
      req.headers.contentType = ContentType.json;
      req.headers.set(HttpHeaders.userAgentHeader, 'jiedan_app');
      final payload = jsonEncode({
        'content': text,
        'os': Platform.operatingSystem,
        'osVersion': Platform.version,
        'count': _files.length,
      });
      req.write(payload);
      final resp = await req.close().timeout(_uploadTimeout);
      // 读取并丢弃响应体，确保连接完整收尾后复用 / 关闭。
      await resp.transform(utf8.decoder).join().timeout(_uploadTimeout);
      if (mounted) {
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('上传成功（${resp.statusCode}）')),
          );
        } else {
          // 后端无该端点（404 等）或返回错误：降级为复制提示粘贴发送。
          await Clipboard.setData(ClipboardData(text: text));
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('上传失败（HTTP ${resp.statusCode}），日志已复制到剪贴板，请粘贴发送给开发者'),
              ),
            );
          }
        }
      }
    } catch (e) {
      // 网络 / 超时 / 解析失败：降级为复制提示粘贴发送。
      try {
        await Clipboard.setData(ClipboardData(text: text));
      } catch (_) {}
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('上传失败（$e），日志已复制到剪贴板，请粘贴发送给开发者')),
        );
      }
    } finally {
      client.close(force: true);
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('错误日志'),
        actions: [
          if (!_loading && _files.isNotEmpty) ...[
            IconButton(
              tooltip: '上传日志',
              icon: const Icon(Icons.cloud_upload_outlined),
              onPressed: _uploading ? null : _uploadAll,
            ),
            IconButton(
              tooltip: '复制全部日志',
              icon: const Icon(Icons.copy_all_outlined),
              onPressed: _copyAll,
            ),
          ],
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
