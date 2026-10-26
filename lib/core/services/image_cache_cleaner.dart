import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// 图片缓存清理（M5 设置页「清除图片缓存」，PRD §5.6.4）。
///
/// 两层缓存：
/// - Flutter 内存 `imageCache`（两端都有）；
/// - `cached_network_image` 磁盘缓存（原生端；Web 封面走 `Image.network`
///   无磁盘缓存，跳过）。
class ImageCacheCleaner {
  const ImageCacheCleaner._();

  static Future<void> clearAll() async {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    if (!kIsWeb) {
      await DefaultCacheManager().emptyCache();
    }
  }
}
