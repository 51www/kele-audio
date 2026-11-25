/// 离线词库的两种规格与内置下载源。
///
/// - [DictionaryMode.simple]：ECDICT 裁剪版 JSON，约 3.9MB / 2.7 万词条；
/// - [DictionaryMode.full]：ECDICT 全量 CSV，约 66MB / 77 万词条。
///
/// 下载源固定写在 App 内，不提供自定义下载地址。
enum DictionaryMode { simple, full }

class DictionaryPackConfig {
  DictionaryPackConfig._();

  static const String innerFileName = 'dict.json';
  static const String tempFileName = 'dictionary.part';

  static const String simpleVersion = 'ecdict-compact-v1';
  static const String fullVersion = 'ecdict-full-v1';

  static const String _compactDictPath =
      'Gty2408/dsh-word-translate@HEAD/data/dict.json';
  static const String _fullCsvPath = 'skywind3000/ECDICT/master/ecdict.csv';

  static const List<String> _simpleSources = <String>[
    'https://gcore.jsdelivr.net/gh/$_compactDictPath',
    'https://fastly.jsdelivr.net/gh/$_compactDictPath',
    'https://jsd.onmicrosoft.cn/gh/$_compactDictPath',
    'https://ghproxy.net/https://raw.githubusercontent.com/'
        'Gty2408/dsh-word-translate/HEAD/data/dict.json',
  ];

  static const List<String> _fullSources = <String>[
    'https://gh-proxy.com/https://raw.githubusercontent.com/$_fullCsvPath',
    'https://raw.githubusercontent.com/$_fullCsvPath',
    'https://github.com/skywind3000/ECDICT/raw/refs/heads/master/ecdict.csv',
    'https://ghproxy.net/https://raw.githubusercontent.com/$_fullCsvPath',
  ];

  static String versionFor(DictionaryMode mode) =>
      mode == DictionaryMode.full ? fullVersion : simpleVersion;

  static List<String> sourcesFor(DictionaryMode mode) =>
      mode == DictionaryMode.full ? _fullSources : _simpleSources;

  static String titleFor(DictionaryMode mode) =>
      mode == DictionaryMode.full ? '完整词库' : '精简词库';

  static String subtitleFor(DictionaryMode mode) => mode == DictionaryMode.full
      ? '约 66 MB · 77 万词条'
      : '约 3.9 MB · 2.7 万词条';

  static String descriptionFor(DictionaryMode mode) =>
      mode == DictionaryMode.full
          ? '收录 ECDICT 全量英汉词条，适合查生僻词、专业词与更多词形；'
              '包体较大，首次下载与加载需要更长时间，占用更多存储空间。'
          : '收录日常阅读常用英汉词条与词形，下载快、占用小，'
              '适合大多数小说和文章；查词速度也更快。';

  /// 校验值仅用于精简词库构建包；完整词库跟随上游 CSV 更新，不启用固定校验。
  static String? expectedSha256For(DictionaryMode mode) =>
      mode == DictionaryMode.full ? null : expectedSha256;

  static String? get expectedSha256 {
    const raw = String.fromEnvironment('DICTIONARY_SHA256');
    return raw.isEmpty ? null : raw.toLowerCase();
  }
}
