import 'dart:convert';

import 'package:dio/dio.dart';

/// WebDAV 错误：统一抛给上层做提示（401 凭据 / 404 路径 / 网络失败）。
class WebdavException implements Exception {
  WebdavException(this.code, this.message);

  final int? code;
  final String message;

  @override
  String toString() => message;
}

/// 云端文件存储抽象（WebdavSyncService 依赖倒置，单测换假实现）。
abstract class CloudStore {
  /// 连通性 + 凭据校验。
  Future<void> testConnection();

  /// 逐级创建目录（已存在视为成功）。
  Future<void> ensureDir(String path);

  /// 覆盖写入文本文件。
  Future<void> putFile(String path, String content);

  /// 读取文本文件；不存在返回 null。
  Future<String?> getFile(String path);
}

/// 最小 WebDAV 客户端（RFC 4918 子集：PROPFIND / MKCOL / GET / PUT + Basic Auth）。
///
/// 兼容坚果云、Nextcloud 等市面 WebDAV 网盘（用户决策：用标准协议、从简实现，
/// 不引第三方库）——只读写几个 JSON 文件，GET/PUT/MKCOL 足够。
class WebdavClient implements CloudStore {
  WebdavClient({
    required this.baseUrl,
    required this.username,
    required this.password,
    Dio? dio,
  }) : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 30),
              responseType: ResponseType.plain,
            ));

  /// 服务地址，如 `https://dav.jianguoyun.com/dav/`（尾斜杠可有可无）。
  final String baseUrl;
  final String username;
  final String password;
  final Dio _dio;

  static const String _propfindBody =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>';

  /// Basic Auth 头（纯函数，单测覆盖）。
  static String basicAuth(String username, String password) =>
      'Basic ${base64.encode(utf8.encode('$username:$password'))}';

  /// 相对路径 → 完整 URL：容忍 baseUrl 缺尾斜杠，路径段逐段 percent-encode
  ///（同步目录名可含中文）（纯函数，单测覆盖）。
  static String joinUrl(String baseUrl, String path) {
    final base = baseUrl.trim().endsWith('/')
        ? baseUrl.trim()
        : '${baseUrl.trim()}/';
    final encoded = path
        .split('/')
        .where((s) => s.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    return encoded.isEmpty ? base : '$base$encoded';
  }

  Future<Response<dynamic>> _request(
    String method,
    String url, {
    Map<String, String>? headers,
    Object? data,
  }) async {
    try {
      return await _dio.request<dynamic>(
        url,
        data: data,
        options: Options(
          method: method,
          headers: {
            'Authorization': basicAuth(username, password),
            ...?headers,
          },
          validateStatus: (_) => true,
          responseType: ResponseType.plain,
        ),
      );
    } on DioException catch (e) {
      throw WebdavException(-1, '网络请求失败：${e.message}');
    }
  }

  @override
  Future<void> testConnection() async {
    final res = await _request(
      'PROPFIND',
      joinUrl(baseUrl, ''),
      headers: {'Depth': '0', 'Content-Type': 'application/xml'},
      data: _propfindBody,
    );
    final sc = res.statusCode ?? 0;
    if (sc == 207 || (sc >= 200 && sc < 300)) return;
    if (sc == 404) throw WebdavException(404, '服务器地址不存在（404）');
    throw WebdavException(sc, '连接失败（HTTP $sc）');
  }

  @override
  Future<void> ensureDir(String path) async {
    var acc = '';
    for (final seg in path.split('/').where((s) => s.isNotEmpty)) {
      acc = acc.isEmpty ? seg : '$acc/$seg';
      final res = await _request('MKCOL', joinUrl(baseUrl, acc));
      final sc = res.statusCode ?? 0;
      if (sc >= 200 && sc < 300) continue;
      if (sc == 405 || sc == 301 || sc == 302) continue; // 目录已存在
      if (sc == 404) throw WebdavException(404, '父目录不存在，请检查同步目录');
      throw WebdavException(sc, '创建同步目录失败（HTTP $sc）');
    }
  }

  @override
  Future<void> putFile(String path, String content) async {
    final res = await _request(
      'PUT',
      joinUrl(baseUrl, path),
      headers: {'Content-Type': 'application/json; charset=utf-8'},
      data: content,
    );
    final sc = res.statusCode ?? 0;
    if (sc >= 200 && sc < 300) return;
    if (sc == 404) throw WebdavException(404, '同步目录不存在');
    if (sc == 507) throw WebdavException(507, '云端空间不足');
    throw WebdavException(sc, '上传失败（HTTP $sc）');
  }

  @override
  Future<String?> getFile(String path) async {
    final res = await _request('GET', joinUrl(baseUrl, path));
    final sc = res.statusCode ?? 0;
    if (sc == 404) return null;
    if (sc >= 200 && sc < 300) {
      final d = res.data;
      return d is String ? d : '$d';
    }
    throw WebdavException(sc, '下载失败（HTTP $sc）');
  }
}
