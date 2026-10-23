import '../domain/playback.dart';
import 'api_config.dart';
import 'bili_client.dart';

/// DASH 音轨（`playurl` → `dash.audio[]` 的一条）。
class AudioTrack {
  const AudioTrack({
    required this.id,
    required this.baseUrl,
    this.backupUrls = const [],
    this.bandwidth = 0,
    this.codecs = '',
  });

  /// 音轨 id：30216=64K、30232=132K、30280=192K、30251=Hi-Res、30250=Dolby
  final int id;
  final String baseUrl;
  final List<String> backupUrls;
  final int bandwidth;
  final String codecs;

  bool get playable => baseUrl.isNotEmpty || backupUrls.isNotEmpty;

  String get qualityLabel => switch (id) {
        30280 => '192K',
        30232 => '132K',
        30216 => '64K',
        30251 => 'Hi-Res',
        30250 => 'Dolby',
        _ => '$id',
      };
}

/// `playurl`（fnval=16 DASH）解析结果。
class PlayUrlResult {
  const PlayUrlResult({
    this.tracks = const [],
    this.flac,
    this.dolby,
    this.timelengthMs = 0,
  });

  final List<AudioTrack> tracks;
  final AudioTrack? flac;
  final AudioTrack? dolby;
  final int timelengthMs;

  bool get hasPlayableUrl =>
      (flac?.playable ?? false) ||
      (dolby?.playable ?? false) ||
      tracks.any((t) => t.playable);
}

/// 播放地址服务（M2 任务 2）：**DASH 取址 + 音质选择 + 内存缓存**。
///
/// 硬约束（AGENT.md / R5）：
/// 1. **播放地址永不落库**，只存本类的内存 Map，有效期 90 分钟、上限 6 条；
/// 2. 取址接口最易触发风控，沿用 `BiliClient` 的 450ms 节流与阶梯退避，
///    这里只追加「响应无可用音轨也视为失败」的重试（防止静默跳集，abts 同款）；
/// 3. CDN 必须带 UA + Referer，否则 403/412 —— 统一由 [headersFor] 提供。
class PlayUrlService {
  PlayUrlService({
    required this.client,
    required this.config,
    this.cacheTtl = const Duration(minutes: 90),
    this.maxCacheEntries = 6,
    this.log,
  });

  final BiliClient client;
  final ApiConfig config;

  /// 地址有效期（R5：abts 实测 90 分钟，保守值）
  final Duration cacheTtl;

  /// 内存缓存上限（超限按插入顺序淘汰最旧）
  final int maxCacheEntries;

  final void Function(String message)? log;

  static const String playUrlPath = BiliPaths.playUrl;

  /// cid → (候选地址, 取址时间)。**仅内存，进程退出即失效。**
  final Map<String, ({List<String> urls, int ts})> _cache = {};

  int get cacheSize => _cache.length;

  /// 取流请求头（B 站 CDN 校验 UA + Referer，缺一即 403/412）
  Map<String, String> headersFor(String bvid) => {
        'User-Agent': config.userAgent,
        'Referer': '${config.homeBase}/video/$bvid',
      };

  /// 拿候选播放地址（按音质优先排序，逐个 fallback 到播放器）。
  ///
  /// [quality] 指定的档位缺失时自动退到最接近的档位（B 站并非每个视频
  /// 都提供全部三档），因此返回值**永远非空**（接口正常时）。
  Future<List<String>> resolve({
    required String bvid,
    required int cid,
    AudioQuality quality = AudioQuality.q132k,
    bool forceRefresh = false,
  }) async {
    final key = '$bvid:$cid';
    if (!forceRefresh) {
      final hit = _cache[key];
      if (hit != null &&
          DateTime.now().millisecondsSinceEpoch - hit.ts <
              cacheTtl.inMilliseconds) {
        return hit.urls;
      }
    }

    final result = await _fetch(bvid, cid);
    final urls = _order(result, quality);
    if (urls.isEmpty) {
      throw BiliApiException(-1, '获取音频地址失败：该章节没有可用音轨');
    }

    _cache[key] =
        (urls: urls, ts: DateTime.now().millisecondsSinceEpoch);
    while (_cache.length > maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
    _log('[playurl] $bvid/$cid → ${urls.length} 条候选'
        '（$quality·期望 ${quality.label}）');
    return urls;
  }

  /// 让某章节的内存地址失效（P-05 自愈第一步）
  void invalidate(String bvid, int cid) => _cache.remove('$bvid:$cid');

  /// 清空全部内存地址（P-05 调试入口 / 退出登录）
  void invalidateAll() => _cache.clear();

  /// 实际取址：风控与「无音轨」都重试，最多 3 次（abts 同款退避 1800ms×n）
  Future<PlayUrlResult> _fetch(String bvid, int cid) async {
    BiliApiException? last;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(milliseconds: 1800 * attempt));
      }
      try {
        final res = await client.get(
          config.url(playUrlPath),
          query: {
            'bvid': bvid,
            'cid': cid,
            'qn': AudioQuality.q192k.trackId,
            'fnval': 16, // DASH（PRD M2 任务 2；M0 冒烟已验证）
            'fnver': 0,
            'fourk': 1,
          },
          useWbi: true,
          headers: {'Referer': '${config.homeBase}/video/$bvid'},
        );
        final data = res.data is Map ? res.data['data'] : null;
        if (data is! Map) throw BiliApiException(-1, 'playurl 响应缺少 data');
        final parsed = _parse(Map<String, dynamic>.from(data));
        if (parsed.hasPlayableUrl) return parsed;
        last = BiliApiException(-1, '未返回可用音频地址');
      } on BiliApiException catch (e) {
        last = e;
        // 只有风控类值得重试：404/410 之类重试同样会失败
        if (e.code != -412 && e.code != -352 && e.code != -509) rethrow;
      }
    }
    throw last ?? BiliApiException(-1, '获取音频地址失败');
  }

  static PlayUrlResult _parse(Map<String, dynamic> data) {
    final dash = data['dash'];
    if (dash is! Map) return const PlayUrlResult();

    AudioTrack? parseTrack(Object? raw) {
      if (raw is! Map) return null;
      final track = AudioTrack(
        id: int.tryParse('${raw['id'] ?? 0}') ?? 0,
        baseUrl: '${raw['baseUrl'] ?? ''}',
        backupUrls: <String>[
          for (final e in (raw['backup_url'] as List? ?? []))
            if ('$e'.isNotEmpty) '$e',
        ],
        bandwidth: int.tryParse('${raw['bandwidth'] ?? 0}') ?? 0,
        codecs: '${raw['codecs'] ?? ''}',
      );
      return track.playable ? track : null;
    }

    final audioList = dash['audio'];
    final tracks = <AudioTrack>[
      if (audioList is List)
        for (final raw in audioList)
          if (parseTrack(raw) case final AudioTrack t) t,
    ];

    AudioTrack? flac;
    final flacMap = dash['flac'];
    if (flacMap is Map && flacMap['audio'] is Map) {
      flac = parseTrack(flacMap['audio']);
    }
    AudioTrack? dolby;
    final dolbyMap = dash['dolby'];
    if (dolbyMap is Map) {
      final list = dolbyMap['audio'];
      if (list is List && list.isNotEmpty) dolby = parseTrack(list.first);
    }

    return PlayUrlResult(
      tracks: tracks,
      flac: (flac?.playable ?? false) ? flac : null,
      dolby: (dolby?.playable ?? false) ? dolby : null,
      timelengthMs: int.tryParse('${data['timelength'] ?? 0}') ?? 0,
    );
  }

  /// 音质选择 + fallback 排序：
  /// 1. 目标档位（最接近的一档）放最前；
  /// 2. 其余音轨按 bandwidth 降序（192K 优先于 64K）；
  /// 3. flac / dolby 兜底（仅当 AAC 全挂时才轮到）。
  ///
  /// 每条音轨都展开 `baseUrl + backup_url`，`http://` 统一转 `https://`。
  List<String> _order(PlayUrlResult result, AudioQuality quality) {
    final seen = <String>{};
    String toHttps(String u) =>
        u.startsWith('http://') ? 'https://${u.substring(7)}' : u;

    void collect(AudioTrack? t) {
      if (t == null) return;
      if (t.baseUrl.isNotEmpty) seen.add(toHttps(t.baseUrl));
      for (final b in t.backupUrls) {
        if (b.isNotEmpty) seen.add(toHttps(b));
      }
    }

    final sorted = [...result.tracks]
      ..sort((a, b) => b.bandwidth.compareTo(a.bandwidth));

    // 目标档位（或最接近的一档）优先
    final target = sorted.where((t) => t.id == quality.trackId).toList();
    if (target.isEmpty) {
      final byGap = sorted.where((t) => t.id >= 30216 && t.id <= 30280).toList()
        ..sort((a, b) =>
            (a.id - quality.trackId).abs().compareTo(
                (b.id - quality.trackId).abs()));
      if (byGap.isNotEmpty) target.add(byGap.first);
    }
    for (final t in target) {
      collect(t);
    }
    for (final t in sorted) {
      if (!target.contains(t)) collect(t);
    }
    collect(result.flac);
    collect(result.dolby);
    return seen.toList();
  }

  void _log(String msg) => log?.call(msg);
}
