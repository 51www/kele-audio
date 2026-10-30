import 'update_config.dart';
import 'update_models.dart';

/// 纯函数集合：版本比较 / 产物挑选 / 下载与接口源排序 / 错误码翻译。
/// 无任何 I/O 依赖，便于单测（提示词 2「代码组织」）。
///
/// 这些函数只依赖 [UpdateConfig]，不触碰网络 / 文件，可在 `flutter test` 中直接验证。

/// 解析版本号为数值段。
///
/// 规则（提示词 2）：去 `v` 前缀、去 `-beta` 等预发布后缀，按 `.` 拆段逐段转 int。
/// 例：`v1.10.0-beta.2` → `[1, 10, 0]`。
List<int> parseVersion(String version) {
  String v = version.trim();
  if (v.toLowerCase().startsWith('v')) v = v.substring(1);
  // 截断预发布 / 构建元数据后缀（遇 '-' 或 '+' 即止）。
  final int dash = v.indexOf('-');
  final int plus = v.indexOf('+');
  int cut = v.length;
  if (dash >= 0 && dash < cut) cut = dash;
  if (plus >= 0 && plus < cut) cut = plus;
  if (cut < v.length) v = v.substring(0, cut);
  if (v.isEmpty) return <int>[0];
  return v
      .split('.')
      .map((String s) =>
          int.tryParse(s.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
      .toList();
}

/// 比较版本：a > b 返回 1，相等返回 0，a < b 返回 -1。逐段数值比较。
///
/// 验证点：`1.10.0` > `1.9.9`，`1.1` == `1.1.0`。
int compareVersions(String a, String b) {
  final List<int> la = parseVersion(a);
  final List<int> lb = parseVersion(b);
  final int n = la.length > lb.length ? la.length : lb.length;
  for (int i = 0; i < n; i++) {
    final int x = i < la.length ? la[i] : 0;
    final int y = i < lb.length ? lb[i] : 0;
    if (x != y) return x > y ? 1 : -1;
  }
  return 0;
}

/// 是否「真正有更新」：latest 严格大于 current 才提示；同版本或更旧一律不提示。
bool isUpdateAvailable(String latest, String current) =>
    compareVersions(latest, current) > 0;

/// 从 GitHub asset 列表中挑选本平台产物（当前仅 Android 闭环）。
///
/// Android 优先级（提示词 2「产物选择」）：
///   1) `*-android-universal.apk`（通用包，优先）
///   2) 历史手动命名 `app-release.apk` / `*-release.apk`
///   3) 其他 `*.apk`
///   一律排除 `.aab`。
/// 桌面 / iOS / Web 关键字 `-windows-` / `-linux-` / `-macos-` / `-web.` 保留以备扩展。
GhAsset? selectAsset(List<GhAsset> assets) {
  if (assets.isEmpty) return null;
  final List<GhAsset> apks = assets.where((GhAsset a) {
    final String n = a.name.toLowerCase();
    return n.endsWith('.apk') && !n.endsWith('.aab');
  }).toList();
  if (apks.isEmpty) return null;

  GhAsset? byPattern(String re) {
    final RegExp r = RegExp(re);
    for (final GhAsset a in apks) {
      if (r.hasMatch(a.name.toLowerCase())) return a;
    }
    return null;
  }

  // 1) universal 优先
  final GhAsset? universal = byPattern(r'-android-universal\.apk$');
  if (universal != null) return universal;
  // 2) 历史手动命名
  final GhAsset? legacy =
      byPattern(r'(^|[-_])app-release\.apk$|(^|[-_])release\.apk$');
  if (legacy != null) return legacy;
  // 3) 其他 apk（如带 abi 的）
  return apks.first;
}

List<String> _normalizeMirrors(List<String> mirrors) =>
    mirrors.map((String m) => m.endsWith('/') ? m : '$m/').toList();

/// 接口源顺序：官方 `api.github.com` 优先（最权威）→ 镜像兜底（提示词 3-3）。
///
/// [mirrors] 可覆盖默认镜像候选（实测后传入）；[UpdateConfig.customMirrors] 始终排最前。
List<String> buildApiSourceOrder({
  List<String>? mirrors,
  bool includeOfficial = true,
}) {
  final List<String> m = _normalizeMirrors(<String>[
    ...UpdateConfig.customMirrors,
    ...(mirrors ?? UpdateConfig.defaultMirrorPrefixes),
  ]);
  final List<String> list = <String>[];
  if (includeOfficial) {
    list.add(UpdateConfig.latestReleaseUrl);
  }
  for (final String prefix in m) {
    list.add('$prefix${UpdateConfig.latestReleaseUrl}');
  }
  return list;
}

/// 下载源顺序：国内镜像在前 → GitHub 官方直连兜底（提示词 3-2）。
///
/// [assetUrl] 为官方原始下载地址（形如 `https://github.com/.../x.apk`）。
List<String> buildDownloadSourceOrder(
  String assetUrl, {
  List<String>? mirrors,
  bool includeOfficial = true,
}) {
  final List<String> m = _normalizeMirrors(<String>[
    ...UpdateConfig.customMirrors,
    ...(mirrors ?? UpdateConfig.defaultMirrorPrefixes),
  ]);
  final List<String> list = <String>[];
  for (final String prefix in m) {
    list.add('$prefix$assetUrl');
  }
  if (includeOfficial) {
    list.add(assetUrl);
  }
  return list;
}

/// HTTP 错误码 → 用户可读中文（提示词 2 测试项「错误码翻译」）。
String translateApiError(int? statusCode, {String? message}) {
  switch (statusCode) {
    case null:
      return message != null && message.isNotEmpty
          ? '网络异常：$message'
          : '网络异常，请检查连接后重试';
    case 200:
      return '已是最新';
    case 401:
    case 403:
      return '访问被拒绝（可能触发限流或未授权），稍后重试';
    case 404:
      return '未找到发布信息（仓库可能暂无 Release）';
    case 429:
      return '请求过于频繁，已被限流，请稍后重试';
    case 500:
    case 502:
    case 503:
    case 504:
      return 'GitHub 服务暂时不可用，请稍后重试';
    default:
      return '检查更新失败（HTTP $statusCode）';
  }
}
