import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// 收款码图片 → data URL（模块 B 返现提现专用）。
///
/// 后端硬约束：单张收款码 base64 解码后必须 ≤ 200KB（`kMaxQrcodeBytes`）。
/// 策略：
/// 1. 原图字节数已 ≤ 上限 → 直接用原始编码（体积最小、最清晰）；
/// 2. 超限 → 用 Flutter 引擎逐级降采样并重编码为 PNG，命中即返回；
/// 3. 全部失败 → 返回 null，由调用方提示用户换一张更小的截图。
Future<String?> qrImageToDataUrl(
  String filePath, {
  int maxBytes = 200 * 1024,
}) async {
  if (filePath.isEmpty) return null;
  Uint8List raw;
  try {
    raw = await File(filePath).readAsBytes();
  } catch (_) {
    return null;
  }
  if (raw.isEmpty) return null;
  if (raw.length <= maxBytes) {
    final mime =
        filePath.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
    return 'data:$mime;base64,${base64Encode(raw)}';
  }
  // 逐级降采样（宽度逐档收紧），保证压缩后落在 200KB 内
  for (final width in const [720, 560, 420, 320, 240]) {
    final out = await _resizeToPng(raw, width);
    if (out == null || out.isEmpty) continue;
    if (out.length <= maxBytes) {
      return 'data:image/png;base64,${base64Encode(out)}';
    }
  }
  return null;
}

/// 按目标宽度等比缩放并重编码为 PNG；失败返回 null。
Future<Uint8List?> _resizeToPng(Uint8List raw, int targetWidth) async {
  ui.Codec? codec;
  ui.Image? image;
  try {
    codec = await ui.instantiateImageCodec(raw, targetWidth: targetWidth);
    final frame = await codec.getNextFrame();
    image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}
