/// 离线词库下载源配置。
///
/// 默认下载从 ECDICT（MIT）裁剪而来的精简英汉词库 JSON（约 3.9MB，
/// 26,974 词条 + 27,241 条词形），通过多个 CDN 镜像回退。
/// 也可用 `DICTIONARY_URL` dart-define 或在 App 内填写自定义地址。
class DictionaryPackConfig {
  DictionaryPackConfig._();

  static const String version = 'ecdict-compact-v1';
  static const String innerFileName = 'dict.json';
  static const String tempFileName = 'dictionary.part';

  static const String _dictPath =
      'Gty2408/dsh-word-translate@HEAD/data/dict.json';
  static const List<String> builtinSources = <String>[
    'https://gcore.jsdelivr.net/gh/$_dictPath',
    'https://fastly.jsdelivr.net/gh/$_dictPath',
    'https://jsd.onmicrosoft.cn/gh/$_dictPath',
    'https://ghproxy.net/https://raw.githubusercontent.com/'
        'Gty2408/dsh-word-translate/HEAD/data/dict.json',
  ];

  static String? get dartDefineUrl {
    const raw = String.fromEnvironment('DICTIONARY_URL');
    return raw.isEmpty ? null : raw;
  }

  static String? get expectedSha256 {
    const raw = String.fromEnvironment('DICTIONARY_SHA256');
    return raw.isEmpty ? null : raw.toLowerCase();
  }

  static List<String> sourcesWith(String? customUrl) {
    final custom = customUrl?.trim();
    return <String>[
      ?dartDefineUrl,
      if (custom != null && custom.isNotEmpty) custom,
      ...builtinSources,
    ];
  }
}
