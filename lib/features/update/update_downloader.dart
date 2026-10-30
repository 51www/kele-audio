import 'dart:io';

import 'package:dio/dio.dart';

import 'hash.dart';
import 'update_checker.dart';
import 'update_config.dart';
import 'update_models.dart';

/// 下载进度快照。
class DownloadProgress {
  const DownloadProgress({
    required this.received,
    required this.total,
    required this.currentSource,
  });
  final int received;
  final int total;
  final String currentSource;
  double get ratio => total <= 0 ? 0 : received / total;
}

/// 经多源下载产物：失败自动换下一个源；完成后按 asset digest 校验 SHA-256。
///
/// 安全（提示词 3「安全」）：第三方镜像可能投毒/截断，下载后用 GitHub asset 的
/// `sha256:` digest 校验；不匹配则视为该源不可信，删文件并换源重下；digest 缺失时
/// 跳过校验不阻断。用户取消（CancelToken）立即终止，不再试下一源。
class UpdateDownloader {
  const UpdateDownloader({required this.dio});
  final Dio dio;

  Future<String> download({
    required GhAsset asset,
    required String targetPath,
    required void Function(DownloadProgress) onProgress,
    CancelToken? cancelToken,
    List<String>? mirrors,
  }) async {
    final List<String> sources = buildDownloadSourceOrder(
      asset.browserDownloadUrl,
      mirrors: mirrors,
    );
    DioException? lastErr;

    for (final String url in sources) {
      try {
        onProgress(DownloadProgress(
          received: 0,
          total: asset.size,
          currentSource: url,
        ));
        await dio.download(
          url,
          targetPath,
          cancelToken: cancelToken,
          options: Options(
            headers: <String, String>{'User-Agent': UpdateConfig.userAgent},
            responseType: ResponseType.bytes,
          ),
          onReceiveProgress: (int received, int total) {
            onProgress(DownloadProgress(
              received: received,
              total: total > 0 ? total : asset.size,
              currentSource: url,
            ));
          },
        );

        // 校验哈希（digest 缺失则跳过）。
        final String? expected = asset.sha256;
        if (expected != null) {
          final String? actual = await computeFileSha256(targetPath);
          if (actual == null || actual != expected) {
            // 该源不可信：删掉半成品，换下一源重下。
            throw DioException(
              requestOptions: RequestOptions(path: url),
              type: DioExceptionType.unknown,
              message: 'sha256 mismatch (expected $expected, got $actual)',
            );
          }
        }
        return targetPath;
      } on DioException catch (e) {
        // 用户取消：立即终止整个流程，不再试下一源。
        if (e.type == DioExceptionType.cancel ||
            cancelToken?.isCancelled == true) {
          rethrow;
        }
        lastErr = e;
        try {
          await File(targetPath).delete();
        } catch (_) {
          // 忽略删除失败
        }
        continue;
      }
    }
    throw lastErr ??
        DioException(
          requestOptions: RequestOptions(path: sources.first),
          message: 'all download sources failed',
        );
  }
}
