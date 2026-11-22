import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'book_file_store.dart';

/// 本地书封面：解码 → 长边缩到 [maxEdge] 以内 → 压成 JPEG
/// 落盘 `books/{id}/cover.jpg`。
///
/// 任何一步失败（SVG、损坏图片、不支持的编码）都静默返回 null，
/// 由界面回退到现有的首字渐变占位，绝不影响导入流程。
class LocalBookCover {
  LocalBookCover._();

  static const String fileName = 'cover.jpg';

  /// 长边上限。书架卡片与听书页最大显示不到 240px，1200 已足够清晰。
  static const int maxEdge = 1200;

  /// 体积上限：超过则逐档降低 JPEG 画质，最终再缩小尺寸兜底。
  static const int maxBytes = 600 * 1024;

  /// 处理并写入封面文件，返回落盘路径；拿不到可用封面时返回 null。
  static Future<String?> save(String bookId, Uint8List? raw) async {
    if (raw == null || raw.isEmpty) return null;
    Uint8List? encoded;
    try {
      // 大图解码在主隔离区外执行，避免导入/启动时卡 UI。
      encoded = await compute(_encodeCover, raw);
    } catch (e) {
      debugPrint('[reader] 封面处理失败：$e');
      return null;
    }
    if (encoded == null) return null;
    try {
      return await saveReaderBookFile(bookId, encoded, fileName: fileName);
    } catch (e) {
      debugPrint('[reader] 封面落盘失败：$e');
      return null;
    }
  }
}

/// 后台隔离区入口：任何异常都返回 null（不向上抛，避免打断导入）。
Uint8List? _encodeCover(Uint8List raw) {
  try {
    var image = img.decodeImage(raw);
    if (image == null) return null;

    // 手机拍摄的封面可能带 EXIF 方向，先摆正再缩放。
    image = img.bakeOrientation(image);
    image = _flattenAlpha(image);

    final longest = math.max(image.width, image.height);
    if (longest > LocalBookCover.maxEdge) {
      image = _resizeLongEdge(image, LocalBookCover.maxEdge);
    }

    for (final quality in const [85, 75, 65, 55]) {
      final jpg = img.encodeJpg(image, quality: quality);
      if (jpg.length <= LocalBookCover.maxBytes) return jpg;
    }

    // 极端高噪点封面：再缩一档，保证体积可控。
    return img.encodeJpg(
      _resizeLongEdge(image, LocalBookCover.maxEdge ~/ 2),
      quality: 70,
    );
  } catch (_) {
    return null;
  }
}

img.Image _resizeLongEdge(img.Image image, int edge) {
  final widthFirst = image.width >= image.height;
  return img.copyResize(
    image,
    width: widthFirst ? edge : null,
    height: widthFirst ? null : edge,
    interpolation: img.Interpolation.average,
  );
}

/// JPEG 不支持透明通道：带 alpha 的封面先铺白底，避免透明区变黑。
img.Image _flattenAlpha(img.Image image) {
  if (image.numChannels != 2 && image.numChannels != 4) return image;
  final canvas = img.Image(
    width: image.width,
    height: image.height,
    numChannels: 3,
  );
  img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
  img.compositeImage(canvas, image);
  return canvas;
}
