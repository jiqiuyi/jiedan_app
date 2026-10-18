import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../theme.dart';
import '../services/error_reporter.dart';

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

  /// 当前模块 Tab 过滤（[LogModule.all] 表示全部）。
  String _moduleFilter = LogModule.all;

  /// 当前文件的日志条目（_openFile 时解析，折叠交互数据源）。
  List<_LogEntry> _entries = const [];

  /// 已展开完整堆栈的条目索引集合。
  final Set<int> _expanded = {};

  /// 折叠时默认展示的堆栈关键帧行数。
  static const int _previewLineCount = 5;

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
          .where(
            (e) =>
                e is File &&
                e.path.endsWith('.log') &&
                p.basename(e.path).startsWith('error_'),
          )
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
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
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
        p.join((await getApplicationDocumentsDirectory()).path, 'logs'),
      ),
      () async => Directory(
        p.join((await getApplicationSupportDirectory()).path, 'logs'),
      ),
      () async =>
          Directory(p.join((await getTemporaryDirectory()).path, 'logs')),
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
    if (!await f.exists().timeout(_fileTimeout)) {
      // 目标文件不存在（如切换后已被清理）：结束加载态，避免卡在转圈。
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
      return;
    }
    // 文件上限 512KB（截断后 ≤256KB），直接整体读入展示。
    final bytes = await f.readAsBytes().timeout(_fileTimeout);
    // 按 UTF-8 宽容解码，避免个别乱码字节中断展示。
    final text = utf8.decode(bytes, allowMalformed: true);
    final parsed = _parseEntries(text);
    setState(() {
      _loading = false;
      _selectedPath = path;
      _content = text;
      _entries = parsed;
      _expanded.clear();
      _info =
          '${p.basename(path)} · ${bytes.length} 字节 · 共 ${_files.length} 个日志文件';
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('日志已复制到剪贴板，可直接粘贴发给开发者')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('复制失败：$e')));
      }
    }
  }

  /// 组装精简日志文本：每条目仅保留 header（异常类型+时间）与堆栈前
  /// [_previewLineCount] 行关键帧，省略其余堆栈，便于快速反馈排查。
  Future<String> _buildCompactLogText() async {
    final buf = StringBuffer();
    for (final f in _files) {
      buf.writeln('===== ${p.basename(f.path)} =====');
      final bytes = await File(f.path).readAsBytes().timeout(_fileTimeout);
      final text = utf8.decode(bytes, allowMalformed: true);
      final entries = _parseEntries(text);
      if (entries.isEmpty) continue;
      for (final e in entries) {
        buf.writeln(e.header);
        final shown = e.bodyLines.take(_previewLineCount).toList();
        for (final l in shown) {
          buf.writeln(l);
        }
        final hidden = e.bodyLines.length - shown.length;
        if (hidden > 0) {
          buf.writeln('  … 省略 $hidden 行堆栈');
        }
        buf.writeln();
      }
    }
    return buf.toString();
  }

  /// 复制日志：[compact] 为 true 时复制精简版，否则复制完整版。
  Future<void> _copyLog(bool compact) async {
    if (!compact) {
      await _copyAll();
      return;
    }
    try {
      final text = await _buildCompactLogText();
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '日志已复制（精简版：每条目异常+时间+前 $_previewLineCount 行堆栈），可直接粘贴发给开发者',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('复制失败：$e')));
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
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('日志读取失败：$e')));
      }
      if (mounted) setState(() => _uploading = false);
      return;
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
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
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('上传成功（${resp.statusCode}）')));
        } else {
          // 后端无该端点（404 等）或返回错误：降级为复制提示粘贴发送。
          await Clipboard.setData(ClipboardData(text: text));
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '上传失败（HTTP ${resp.statusCode}），日志已复制到剪贴板，请粘贴发送给开发者',
                ),
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('上传失败（$e），日志已复制到剪贴板，请粘贴发送给开发者')));
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
            PopupMenuButton<_CopyMode>(
              tooltip: '复制日志',
              icon: const Icon(Icons.copy_all_outlined),
              onSelected: (mode) => _copyLog(mode == _CopyMode.compact),
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: _CopyMode.compact,
                  child: Text('复制精简版（异常+时间+前5行堆栈）'),
                ),
                PopupMenuItem(value: _CopyMode.full, child: Text('复制完整版')),
              ],
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
              const Icon(Icons.info_outline, size: 16, color: AppTheme.textSub),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _info,
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSub),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final mod in LogModule.order)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(LogModule.label(mod)),
                    selected: _moduleFilter == mod,
                    onSelected: (_) => _setModuleFilter(mod),
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
                      label: Text('${p.basename(f.path)} (${f.size}B)'),
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
              : _filteredEntries.isEmpty
              ? const Center(child: Text('当前模块暂无日志'))
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _filteredEntries.length,
                  itemBuilder: (context, index) => _buildEntryTile(index),
                ),
        ),
      ],
    );
  }

  /// 当前模块过滤后的可见条目（「全部」不过滤）。
  List<_LogEntry> get _filteredEntries => _moduleFilter == LogModule.all
      ? _entries
      : _entries.where((e) => e.module == _moduleFilter).toList();

  /// 切换模块 Tab：清空展开状态，避免索引错位。
  void _setModuleFilter(String mod) {
    if (_moduleFilter == mod) return;
    setState(() {
      _moduleFilter = mod;
      _expanded.clear();
    });
  }

  /// 单条日志折叠卡片：默认展示 header（异常类型+时间）与堆栈前
  /// [_previewLineCount] 行关键帧，点击条目 / 按钮可展开完整堆栈。
  Widget _buildEntryTile(int index) {
    final e = _entries[index];
    final expanded = _expanded.contains(index);
    final preview = e.bodyLines.take(_previewLineCount).toList();
    final hiddenCount = e.bodyLines.length - preview.length;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppTheme.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: _moduleBadge(e.module),
            ),
          ),
          InkWell(
            onTap: () => _toggleEntry(index),
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppRadius.md),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    expanded ? Icons.unfold_less : Icons.unfold_more,
                    size: 18,
                    color: AppTheme.textSub,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SelectableText(
                      e.header,
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        height: 1.4,
                        color: AppTheme.textMain,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in expanded ? e.bodyLines : preview)
                  _frameLine(line),
                if (hiddenCount > 0)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 32),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        textStyle: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      onPressed: () => _toggleEntry(index),
                      child: Text(
                        expanded ? '收起堆栈' : '展开完整堆栈（剩余 $hiddenCount 行）',
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 模块小标签：圆角徽标展示条目所属模块。
  Widget _moduleBadge(String mod) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.divider,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        LogModule.label(mod),
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: AppTheme.textMain,
        ),
      ),
    );
  }

  /// 单行堆栈 / ctx 帧：等宽小字，轻微缩进。
  Widget _frameLine(String line) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: SelectableText(
        line,
        style: const TextStyle(
          fontSize: 11,
          fontFamily: 'monospace',
          height: 1.4,
          color: AppTheme.textSub,
        ),
      ),
    );
  }

  void _toggleEntry(int index) {
    setState(() {
      if (!_expanded.add(index)) {
        _expanded.remove(index);
      }
    });
  }

  /// 解析日志文本为条目列表。
  /// 每条目以「[时间] [tag] …」首行开头，后续缩进行为堆栈帧 / ctx 诊断行；
  /// 日志超限截断后可能从堆栈中间开始，开头无 header 的散行归入「截断残片」条目。
  static List<_LogEntry> _parseEntries(String content) {
    final entries = <_LogEntry>[];
    _LogEntry? cur;
    StringBuffer orphan = StringBuffer();
    // 新格式：[time] [tag] [module] error；旧格式：[time] [tag] error。
    // 无 module 段的存量条目按 tag 智能归类（LogModule.moduleOfTag）。
    final headerRe = RegExp(
      r'^\[([^\]]*)\] \[([^\]]*)\](?: \[([^\]]*)\])? (.*)$',
    );
    for (final line in const LineSplitter().convert(content)) {
      if (line.startsWith('[')) {
        if (orphan.isNotEmpty) {
          entries.add(
            _LogEntry(
              header: '（日志截断残片）',
              bodyLines: [orphan.toString().trimRight()],
              module: LogModule.other,
            ),
          );
          orphan = StringBuffer();
        }
        final m = headerRe.firstMatch(line);
        final tag = (m != null && m.group(2) != null) ? m.group(2)! : '';
        final mod = (m != null && m.group(3) != null && m.group(3)!.isNotEmpty)
            ? m.group(3)!
            : LogModule.moduleOfTag(tag);
        cur = _LogEntry(header: line, bodyLines: [], module: mod);
        entries.add(cur);
      } else if (line.isEmpty) {
        continue;
      } else if (cur != null) {
        cur.bodyLines.add(line);
      } else {
        orphan.writeln(line);
      }
    }
    if (orphan.isNotEmpty) {
      entries.add(
        _LogEntry(
          header: '（日志截断残片）',
          bodyLines: [orphan.toString().trimRight()],
          module: LogModule.other,
        ),
      );
    }
    return entries;
  }
}

class _LogEntry {
  final String header;
  final List<String> bodyLines;

  /// 日志模块标识（Tab 分类依据）；存量无 module 条目由 tag 推断。
  final String module;
  _LogEntry({
    required this.header,
    required this.bodyLines,
    required this.module,
  });
}

/// 复制模式：精简版（异常+时间+前5行关键帧）与完整版。
enum _CopyMode { compact, full }

class _LogFile {
  final String path;
  final int size;
  _LogFile({required this.path, required this.size});
}
