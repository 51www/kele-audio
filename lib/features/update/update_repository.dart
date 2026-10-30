import 'package:dio/dio.dart';

import 'update_checker.dart';
import 'update_config.dart';
import 'update_models.dart';

/// 业务异常：带可展示文案，区别于 DioException。
class UpdateException implements Exception {
  const UpdateException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

/// 拉取最新 Release：官方接口优先，失败按序走镜像（提示词 3-3）。
class UpdateRepository {
  const UpdateRepository({required this.dio});
  final Dio dio;

  /// [mirrors] 可覆盖默认镜像候选（实测甄选后传入，便于单测）。
  Future<GhRelease> fetchLatestRelease({List<String>? mirrors}) async {
    final List<String> sources = buildApiSourceOrder(mirrors: mirrors);
    DioException? lastErr;
    for (final String url in sources) {
      try {
        final Response<Map<String, dynamic>> resp = await dio.get(
          url,
          options: Options(
            headers: <String, String>{'User-Agent': UpdateConfig.userAgent},
            responseType: ResponseType.json,
            // 仅接受 2xx，其余交给下方分支处理
            validateStatus: (int? s) => s != null && s >= 200 && s < 300,
          ),
        );
        final Map<String, dynamic>? data = resp.data;
        if (data == null) {
          throw DioException(
            requestOptions: resp.requestOptions,
            type: DioExceptionType.badResponse,
            response: resp,
            message: 'empty body',
          );
        }
        return GhRelease.fromJson(data);
      } on DioException catch (e) {
        final int? code = e.response?.statusCode;
        // 404 确定性错误：仓库无 Release，镜像不可能不同，直接终止。
        if (code == 404) {
          throw const UpdateException('NOT_FOUND',
              '未找到发布信息（仓库可能暂无 Release）');
        }
        // 403 限流 / 网络错误：继续尝试下一镜像源。
        lastErr = e;
        continue;
      }
    }
    throw lastErr ??
        UpdateException('UNKNOWN', '检查更新失败：所有接口源均不可用');
  }
}
