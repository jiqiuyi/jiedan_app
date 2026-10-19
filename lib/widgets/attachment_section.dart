import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api_client.dart';
import '../constants.dart';
import '../database.dart';
import '../state/ticker.dart';
import '../theme.dart';
import 'app_ui.dart';

/// 附件区块（项目 / 合同共用）。
///
/// 职责：附件列表（文件名/大小/时间/删除）、添加附件（file_picker 选文件 →
/// MultipartRequest 上传 /api/attachments/upload 带鉴权 → 本地 insert 并走同步）、
/// 点击预览（图片 InteractiveViewer 大图、PDF 用 printing PdfPreview 滚动查看、
/// docx/xlsx/其他下载到临时目录后 url_launcher 唤起系统应用）。上传/下载显示进度。
class AttachmentSection extends StatefulWidget {
  /// 'project' / 'contract'
  final String ownerType;
  final int ownerId;
  const AttachmentSection({
    super.key,
    required this.ownerType,
    required this.ownerId,
  });

  @override
  State<AttachmentSection> createState() => _AttachmentSectionState();
}

class _AttachmentSectionState extends State<AttachmentSection> {
  List<Map<String, Object?>> _items = [];
  bool _loading = true;
  bool _uploading = false;
  double? _downloadProgress; // null=未下载；0..1 下载进度

  static const int _maxBytes = 50 * 1024 * 1024;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await AppDb.instance
        .getAttachments(widget.ownerType, widget.ownerId);
    if (!mounted) return;
    setState(() {
      _items = rows;
      _loading = false;
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------- 上传 ----------
  Future<void> _pickAndUpload() async {
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.isEmpty) return;
    final f = result.files.single;
    final path = f.path;
    if (path == null) return;
    final file = File(path);
    final size = await file.length();
    if (size > _maxBytes) {
      _toast('文件超过 50MB 上限，无法上传');
      return;
    }
    setState(() => _uploading = true);
    try {
      final uri = Uri.parse('${AppConfig.apiBaseUrl}/api/attachments/upload');
      final req = http.MultipartRequest('POST', uri);
      final token = ApiClient.instance.token;
      if (token != null && token.isNotEmpty) {
        req.headers['Authorization'] = 'Bearer $token';
      }
      req.files.add(await http.MultipartFile.fromPath('file', path));
      final resp = await req.send().timeout(const Duration(seconds: 180));
      final body = await resp.stream.bytesToString();
      final Map<String, dynamic> json;
      try {
        json = jsonDecode(body) as Map<String, dynamic>;
      } catch (_) {
        throw const ApiException('上传失败（服务异常）');
      }
      if (resp.statusCode == 401) {
        throw const TokenInvalidException();
      }
      if (resp.statusCode != 200 || json['ok'] != true) {
        throw ApiException((json['error'] as String?) ?? '上传失败');
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      await AppDb.instance.insertAttachment({
        'owner_type': widget.ownerType,
        'owner_id': widget.ownerId,
        'filename': json['filename'] as String? ?? f.name,
        'mime': json['mime'] as String? ?? '',
        'size': (json['size'] as num?)?.toInt() ?? size,
        'server_path': json['server_path'] as String? ?? '',
        'created_at': now,
        'updated_at': now,
      });
      await _load();
      _toast('上传成功');
    } on TokenInvalidException {
      _toast('登录已失效，请重新登录');
    } catch (e) {
      _toast(e is ApiException ? e.message : '网络异常，上传失败');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  // ---------- 下载（带进度） ----------
  Future<Uint8List> _download(int id) async {
    final uri = Uri.parse(
        '${AppConfig.apiBaseUrl}/api/attachments/download?id=$id');
    final req = http.Request('GET', uri);
    final token = ApiClient.instance.token;
    if (token != null && token.isNotEmpty) {
      req.headers['Authorization'] = 'Bearer $token';
    }
    final client = http.Client();
    try {
      final resp = await client.send(req).timeout(const Duration(seconds: 180));
      if (resp.statusCode == 401) throw const TokenInvalidException();
      if (resp.statusCode != 200) throw const ApiException('下载失败');
      final total = resp.contentLength ?? 0;
      final chunks = <List<int>>[];
      var received = 0;
      await for (final chunk in resp.stream) {
        chunks.add(chunk);
        received += chunk.length;
        if (total > 0) {
          final p = received / total;
          if (mounted) setState(() => _downloadProgress = p);
        }
      }
      final bytes = Uint8List(received);
      var off = 0;
      for (final c in chunks) {
        bytes.setRange(off, off + c.length, c);
        off += c.length;
      }
      return bytes;
    } finally {
      client.close();
    }
  }

  // ---------- 打开/预览 ----------
  Future<void> _open(Map<String, Object?> row) async {
    final id = row['id'] as int;
    final filename = (row['filename'] as String?) ?? 'file';
    final mime = (row['mime'] as String?) ?? '';
    final lower = filename.toLowerCase();
    final isImage = mime.startsWith('image/') ||
        ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp']
            .any(lower.endsWith);
    final isPdf = mime == 'application/pdf' || lower.endsWith('.pdf');
    if (mounted) setState(() => _downloadProgress = 0);
    try {
      final bytes = await _download(id);
      if (!mounted) return;
      if (isImage) {
        final dir = await getTemporaryDirectory();
        final tmp =
            File('${dir.path}/att_${DateTime.now().millisecondsSinceEpoch}_$filename');
        await tmp.writeAsBytes(bytes);
        if (!mounted) return;
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => _ImageViewerPage(file: tmp, title: filename),
        ));
      } else if (isPdf) {
        if (!mounted) return;
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => _PdfViewerPage(bytes: bytes, title: filename),
        ));
      } else {
        final dir = await getTemporaryDirectory();
        final tmp =
            File('${dir.path}/att_${DateTime.now().millisecondsSinceEpoch}_$filename');
        await tmp.writeAsBytes(bytes);
        if (!mounted) return;
        final ok = await launchUrl(
          Uri.file(tmp.path),
          mode: LaunchMode.externalApplication,
        );
        if (!ok) _toast('未能唤起外部应用打开该文件');
      }
    } on TokenInvalidException {
      _toast('登录已失效，请重新登录');
    } catch (e) {
      _toast(e is ApiException ? e.message : '下载失败，请重试');
    } finally {
      if (mounted) setState(() => _downloadProgress = null);
    }
  }

  // ---------- 删除 ----------
  Future<void> _delete(Map<String, Object?> row) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除附件'),
        content: Text('确定删除附件「${row['filename']}」吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          AppButton(
            label: '删除',
            kind: AppButtonKind.danger,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await AppDb.instance.deleteAttachment(row['id'] as int);
    Ticker.ping();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('附件', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            TextButton.icon(
              onPressed: _uploading ? null : _pickAndUpload,
              icon: const Icon(Icons.attach_file, size: 18),
              label: const Text('添加附件'),
            ),
          ],
        ),
        if (_uploading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(),
          ),
        if (_downloadProgress != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(
              value: _downloadProgress,
              minHeight: 3,
            ),
          ),
        if (_loading)
          const AppLoading(size: 22)
        else if (_items.isEmpty)
          const AppEmpty(
            icon: Icons.attach_file_outlined,
            title: '还没有附件',
            hint: '可上传图片 / 文档 / 表格 / PDF 等，单个不超过 50MB',
          )
        else
          ..._items.map(
            (row) => Card(
              child: ListTile(
                leading: Icon(_iconFor(row), color: AppTheme.primary),
                title: Text((row['filename'] as String?) ?? '附件',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  '${_fmtSize((row['size'] as num?)?.toInt() ?? 0)} · ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch((row['created_at'] as num?)?.toInt() ?? 0))}',
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20, color: AppTheme.textSub),
                  onPressed: () => _delete(row),
                ),
                onTap: () => _open(row),
              ),
            ),
          ),
      ],
    );
  }

  IconData _iconFor(Map<String, Object?> row) {
    final name = (row['filename'] as String?) ?? '';
    final mime = (row['mime'] as String?) ?? '';
    final lower = name.toLowerCase();
    if (mime.startsWith('image/') ||
        ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp'].any(lower.endsWith)) {
      return Icons.image_outlined;
    }
    if (mime == 'application/pdf' || lower.endsWith('.pdf')) {
      return Icons.picture_as_pdf_outlined;
    }
    if (lower.endsWith('.doc') || lower.endsWith('.docx')) {
      return Icons.description_outlined;
    }
    if (lower.endsWith('.xls') || lower.endsWith('.xlsx') || lower.endsWith('.csv')) {
      return Icons.table_chart_outlined;
    }
    if (lower.endsWith('.ppt') || lower.endsWith('.pptx')) {
      return Icons.slideshow_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  static String _fmtSize(int bytes) {
    if (bytes >= 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }
}

/// 图片大图预览（自建 InteractiveViewer，不引入 photo_view）。
class _ImageViewerPage extends StatelessWidget {
  final File file;
  final String title;
  const _ImageViewerPage({required this.file, required this.title});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      backgroundColor: Colors.black,
      body: InteractiveViewer(
        maxScale: 5,
        child: Center(
          child: Image.file(file, fit: BoxFit.contain),
        ),
      ),
    );
  }
}

/// PDF 预览页：复用现有 printing 的 PdfPreview 渲染，支持缩放与滚动翻页。
class _PdfViewerPage extends StatelessWidget {
  final Uint8List bytes;
  final String title;
  const _PdfViewerPage({required this.bytes, required this.title});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: PdfPreview(
        canChangeOrientation: false,
        canDebug: false,
        canChangePageFormat: false,
        build: (format) async => bytes,
      ),
    );
  }
}
