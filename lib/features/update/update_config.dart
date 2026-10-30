/// 检查更新功能配置（提示词 2 / 3）。
///
/// 仓库 owner/repo 为单一来源：同时驱动 API 地址与「发布页」链接，避免口径不一致。
class UpdateConfig {
  const UpdateConfig._();

  /// GitHub owner/repo（与 `git remote` 一致：51www/kele-audio）。
  static const String ownerRepo = '51www/kele-audio';

  /// 发布页 / 反馈页链接（用户查看、跳转用）。
  static const String repoUrl = 'https://github.com/$ownerRepo';

  /// GitHub Releases API 基址（官方）。
  static const String apiBase = 'https://api.github.com/repos/$ownerRepo';

  /// 最新发布接口（官方）。
  static String get latestReleaseUrl => '$apiBase/releases/latest';

  /// HTTP 超时：连接 12s / 传输 20s（提示词 2）。
  static const Duration connectTimeout = Duration(seconds: 12);
  static const Duration receiveTimeout = Duration(seconds: 20);

  /// User-Agent：GitHub API 强制要求，否则返回 403。
  static const String userAgent = 'kele-audio-updater';

  /// 国内镜像候选前缀（默认集；运行时经 dart-define 追加/覆盖，见 [customMirrors]）。
  ///
  /// ⚠️ 沙箱环境无法联网实测，此处保留常用 ghproxy 风格候选。请在能联网的机器上
  /// 用 `curl -w '%{http_code} %{time_total}' -m 15 <前缀>https://api.github.com/...`
  /// 甄选，把返回 200（或 404，说明镜像可达）的留下来，其余删除。
  /// 也可不改代码，改 `--dart-define=UPDATE_MIRROR=https://你的镜像/` 追加。
  static const List<String> defaultMirrorPrefixes = <String>[
    'https://ghproxy.net/',
    'https://ghproxy.com/',
    'https://ghfast.top/',
  ];

  /// 从 `--dart-define=UPDATE_MIRROR=...` 读取用户自有镜像（逗号分隔，排最前）。
  /// 镜像失效时改 dart-define 即可，无需发版（提示词 3-4）。
  static List<String> get customMirrors {
    const String raw =
        String.fromEnvironment('UPDATE_MIRROR', defaultValue: '');
    return raw
        .split(',')
        .map((String e) => e.trim())
        .where((String e) => e.isNotEmpty)
        .toList();
  }
}
