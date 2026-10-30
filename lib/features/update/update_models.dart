/// GitHub Releases API 数据模型（最小字段集）。
class GhAsset {
  const GhAsset({
    required this.name,
    required this.browserDownloadUrl,
    this.size = 0,
    this.label,
    this.digest,
  });

  factory GhAsset.fromJson(Map<String, dynamic> json) => GhAsset(
        name: (json['name'] as String?) ?? '',
        browserDownloadUrl:
            (json['browser_download_url'] as String?) ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        label: json['label'] as String?,
        digest: json['digest'] as String?,
      );

  final String name;
  final String browserDownloadUrl;
  final int size;
  final String? label;

  /// GitHub 返回的资产摘要，形如 `sha256:xxxx...` 或 `sha1:xxxx`。
  final String? digest;

  /// 提取 sha256 十六进制（无 / 非 sha256 / 格式不符则返回 null，跳过校验不阻断）。
  String? get sha256 {
    final String? d = digest;
    if (d == null) return null;
    final int idx = d.indexOf(':');
    if (idx < 0) return null;
    final String algo = d.substring(0, idx).toLowerCase();
    final String hex = d.substring(idx + 1).trim();
    if (algo != 'sha256' || hex.isEmpty) return null;
    return hex.toLowerCase();
  }
}

class GhRelease {
  const GhRelease({
    required this.tagName,
    this.name,
    this.body,
    required this.assets,
    this.prerelease = false,
    this.htmlUrl = '',
  });

  factory GhRelease.fromJson(Map<String, dynamic> json) => GhRelease(
        tagName: (json['tag_name'] as String?) ?? '',
        name: json['name'] as String?,
        body: json['body'] as String?,
        prerelease: (json['prerelease'] as bool?) ?? false,
        htmlUrl: (json['html_url'] as String?) ?? '',
        assets: (json['assets'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .map(GhAsset.fromJson)
                .toList() ??
            const <GhAsset>[],
      );

  final String tagName;
  final String? name;
  final String? body;
  final List<GhAsset> assets;
  final bool prerelease;
  final String htmlUrl;
}
