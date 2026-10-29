import 'dart:convert';

import 'api_config.dart';
import 'bili_client.dart';

/// 一条文稿（字幕）句子：`from`～`to` 秒之间显示 [content]。
class SubtitleCue {
  const SubtitleCue({
    required this.fromSec,
    required this.toSec,
    required this.content,
  });

  final double fromSec;
  final double toSec;
  final String content;
}

/// 字幕（文稿）来源：`/x/player/wbi/v2` 取字幕列表 → 下载 bcc JSON → 解析句子。
///
/// 纪律（对齐 [PlayUrlService]/AGENT.md）：
/// 1. 复用 [BiliClient] 的 WBI 签名 / 450ms 节流 / 风控阶梯退避，不另起一套；
/// 2. 文稿**只存内存缓存**（按 `bvid:cid`），进程退出即失效；
///    不落库、不二次分发（R3 版权口径：仅在线展示）；
/// 3. 任何失败（接口挂 / 风控 / 该章无字幕）一律回落**空列表**，
///    播放页据此显示「本章暂无文稿」空态，不打断收听主链路。
class SubtitleSource {
  SubtitleSource({
    required this.client,
    required this.config,
    this.log,
    this.maxCacheEntries = 24,
  });

  final BiliClient client;
  final ApiConfig config;
  final void Function(String message)? log;

  /// 内存缓存上限（超限按插入顺序淘汰最旧）
  final int maxCacheEntries;

  /// `bvid:cid` → 句子列表。**仅内存**；空结果同样缓存，避免反复探测。
  final Map<String, List<SubtitleCue>> _cache = {};

  int get cacheSize => _cache.length;

  /// 清空内存文稿（退出登录时调用，防 AI 字幕残留）。
  void invalidateAll() => _cache.clear();

  /// 拉取一章的文稿。
  ///
  /// 人工字幕无需登录即可获取；AI 字幕需要绑定 B 站账号（Cookie 里有
  /// SESSDATA 时接口自动返回 `ai-zh` 条目，此处优先选中文轨）。
  Future<List<SubtitleCue>> fetch({
    required String bvid,
    required int cid,
  }) async {
    final key = '$bvid:$cid';
    final hit = _cache[key];
    if (hit != null) return hit;

    List<SubtitleCue> cues = const [];
    try {
      final res = await client.get(
        config.url(BiliPaths.playerInfo),
        query: {'bvid': bvid, 'cid': cid},
        useWbi: true,
        headers: {'Referer': '${config.homeBase}/video/$bvid'},
      );
      final data = res.data is Map ? res.data['data'] : null;
      final url = _pickSubtitleUrl(data);
      if (url != null) {
        cues = await _downloadCues(url, bvid: bvid);
      }
    } catch (e) {
      // 拉取失败按「无文稿」处理：只记日志，不给播放页抛错
      _log('[subtitle] $bvid/$cid fetch failed: $e');
      cues = const [];
    }

    _cache[key] = cues;
    while (_cache.length > maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
    _log('[subtitle] $bvid/$cid → ${cues.length} cues');
    return cues;
  }

  /// 从 `playerInfo` 响应里挑一条字幕：优先中文轨（lan 含 `zh`），否则第一条。
  static String? _pickSubtitleUrl(Object? data) {
    if (data is! Map) return null;
    final subtitle = data['subtitle'];
    if (subtitle is! Map) return null;
    final list = subtitle['subtitles'];
    if (list is! List || list.isEmpty) return null;

    Map? pick;
    for (final e in list) {
      if (e is! Map) continue;
      if ('${e['lan'] ?? ''}'.contains('zh')) {
        pick = e;
        break;
      }
      pick ??= e;
    }
    final url = pick?['subtitle_url'];
    return url is String && url.isNotEmpty ? url : null;
  }

  /// 下载 bcc 字幕 JSON 并解析成句子（`{ body: [{from,to,content}] }`）。
  Future<List<SubtitleCue>> _downloadCues(String rawUrl,
      {required String bvid}) async {
    // 字幕文件在 aisubtitle.hdslb.com，常见协议相对地址（`//`）
    final url = rawUrl.startsWith('//') ? 'https:$rawUrl' : rawUrl;
    final res = await client.get(
      url,
      headers: {'Referer': '${config.homeBase}/video/$bvid'},
    );

    Object? payload = res.data;
    if (payload is String && payload.isNotEmpty) {
      // content-type 非 JSON 时 dio 保留字符串，这里手动兜底解码
      try {
        payload = jsonDecode(payload);
      } catch (_) {
        return const [];
      }
    }
    if (payload is! Map) return const [];
    final body = payload['body'];
    if (body is! List) return const [];

    final cues = <SubtitleCue>[];
    for (final item in body) {
      if (item is! Map) continue;
      final content = '${item['content'] ?? ''}'.trim();
      if (content.isEmpty) continue;
      final from = (item['from'] as num?)?.toDouble() ?? 0;
      final to = (item['to'] as num?)?.toDouble() ?? from;
      cues.add(SubtitleCue(fromSec: from, toSec: to, content: content));
    }
    cues.sort((a, b) => a.fromSec.compareTo(b.fromSec));
    return cues;
  }

  void _log(String msg) => log?.call(msg);
}
