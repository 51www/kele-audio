import 'dart:collection';

/// 极简 Cookie 仓库：合并 Set-Cookie / 输出请求头 Cookie 串。
///
/// 移植自 abts（MIT）`lib/core/network/cookie_jar.dart`，改为实例类以便测试。
class CookieJar {
  CookieJar();

  final Map<String, String> _cookies = {};

  int _lastSuccess = 0;
  bool _hasCookie = false;

  bool get ready => _hasCookie;

  int get lastSuccess => _lastSuccess;

  Set<String> get keys => _cookies.keys.toSet();

  void markSuccess() {
    _hasCookie = true;
    _lastSuccess = DateTime.now().millisecondsSinceEpoch;
  }

  /// 从响应头合并 Cookie（支持多个 set-cookie）
  void mergeFromHeaders(List<String>? setCookies) {
    if (setCookies == null) return;
    for (final sc in setCookies) {
      final seg = sc.split(';').first.trim();
      final idx = seg.indexOf('=');
      if (idx <= 0) continue;
      final key = seg.substring(0, idx).trim();
      final value = seg.substring(idx + 1).trim();
      _cookies[key] = value;
    }
    _hasCookie = _cookies.isNotEmpty;
  }

  void mergeFromMap(Map<String, String> map) {
    _cookies.addAll(map);
    _hasCookie = _cookies.isNotEmpty;
  }

  String? get(String key) => _cookies[key];

  /// 本地直接写入一个 Cookie（不经响应头，如自造 buvid3）
  void put(String key, String value) {
    _cookies[key] = value;
    _hasCookie = true;
  }

  /// 删除一个 Cookie（如解除登录时清 SESSDATA）。
  void remove(String key) {
    _cookies.remove(key);
    _hasCookie = _cookies.isNotEmpty;
  }

  String buildHeader() {
    final buf = StringBuffer();
    final keys = SplayTreeSet<String>.of(_cookies.keys);
    for (final k in keys) {
      buf.write('$k=${_cookies[k]}; ');
    }
    final s = buf.toString();
    return s.isEmpty ? '' : s.substring(0, s.length - 2);
  }

  void clear() {
    _cookies.clear();
    _hasCookie = false;
  }
}
