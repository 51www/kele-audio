import 'package:dio/dio.dart';

import 'offline_cache_service.dart';

/// [AudioFetcher] 的 Dio 实现（IO/Web 通用）。
///
/// - Web：`proxyUrlFor` 把 CDN 直链改写为 dev_proxy `/audio` 同源地址，
///   绕开 CORS；响应读全量字节（`ResponseType.bytes`）。
/// - IO：直连 CDN，带 UA/Referer（B 站校验，缺一即 403）。
class DioAudioFetcher implements AudioFetcher {
  DioAudioFetcher({Dio? dio}) : _dio = dio ?? Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 20),
          // 单章音频可到几十 MB，放宽读超时
          receiveTimeout: const Duration(minutes: 10),
          responseType: ResponseType.bytes,
        ));

  final Dio _dio;

  @override
  Future<List<int>> fetchBytes({
    required String url,
    required Map<String, String> headers,
    String Function(String url)? proxyUrlFor,
    bool Function()? isCancelled,
  }) async {
    final target = proxyUrlFor != null ? proxyUrlFor(url) : url;
    final res = await _dio.get<List<int>>(
      target,
      options: Options(headers: headers.isEmpty ? null : headers),
    );
    final data = res.data;
    if (data == null || data.isEmpty) {
      throw StateError('音频流为空（$target）');
    }
    return data;
  }
}
