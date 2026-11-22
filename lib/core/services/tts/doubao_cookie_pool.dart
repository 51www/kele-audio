/// 豆包登录 Cookie 轮询池（纯 Dart，无 dart:io 依赖，Web/测试可用）。
///
/// 借鉴同类项目的防风控核心技术：多个 Cookie 轮换使用，被拦截的 Cookie
/// 临时冷却跳过，避免单个账号在短时间内承担全部请求而被封。
///
/// 使用方式：设置页每行粘贴一个完整 Cookie；解析后按序轮流取用，某 Cookie
/// 触发风控（握手非 101）后进入冷却，冷却期内自动改用下一个。
class DoubaoTtsCookiePool {
  DoubaoTtsCookiePool._();

  static final DoubaoTtsCookiePool instance = DoubaoTtsCookiePool._();

  /// 被风控后的冷却时长（同类项目建议几分钟一次；30 秒足够轮换生效）。
  static const cooldown = Duration(seconds: 30);

  int _cursor = 0;
  final Map<String, DateTime> _cooldownUntil = {};

  /// 把粘贴框内容解析为 Cookie 列表。分隔符：换行 / 竖线；Cookie 自身的 `;`
  /// 是字段分隔，不能用于切分。空行忽略，单 Cookie 原样返回（向后兼容）。
  static List<String> parse(String raw) {
    return raw
        .split(RegExp(r'[\r\n|]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
  }

  /// 取下一个可用 Cookie。优先跳过冷却中的；若全部冷却则取下一个（尽力而为）。
  String? next(List<String> cookies) {
    if (cookies.isEmpty) return null;
    final now = DateTime.now();
    _cooldownUntil.removeWhere((_, until) => now.isAfter(until));

    for (var i = 0; i < cookies.length; i++) {
      final idx = (_cursor + i) % cookies.length;
      if (!_cooldownUntil.containsKey(cookies[idx])) {
        _cursor = (idx + 1) % cookies.length;
        return cookies[idx];
      }
    }
    final cookie = cookies[_cursor % cookies.length];
    _cursor = (_cursor + 1) % cookies.length;
    return cookie;
  }

  /// Cookie 被风控拦截：冷却一段时间，期间轮询会跳过它。
  void markFailed(String cookie) {
    _cooldownUntil[cookie] = DateTime.now().add(cooldown);
  }

  /// Cookie 合成成功：清除其冷却（可能之前被误判）。
  void markSuccess(String cookie) {
    _cooldownUntil.remove(cookie);
  }

  /// Cookie 配置变更时重置轮询状态。
  void reset() {
    _cursor = 0;
    _cooldownUntil.clear();
  }
}
