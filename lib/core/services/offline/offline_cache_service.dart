import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../api/album_source.dart';
import '../../api/bili_client.dart';
import '../../api/key_value_store.dart';
import '../../api/play_url_service.dart';
import '../../data/daos.dart';
import '../../domain/album.dart';
import '../../domain/records.dart';
import 'audio_store.dart';

/// 离线缓存服务（M8 / PRD §5.6.3 / §5.8）。
///
/// 职责：
/// 1. **整本缓存**：`cacheAlbum` 把专辑未完成章节全部入队，串行下载
///    （取址 → 拉音频字节 → [AudioStore] 落盘），状态写 `download` 表；
/// 2. 暂停 / 继续（专辑级）、单集删除、整本删除、全部清理（含字节删除）；
/// 3. `cachedUrlFor`：播放器取「已缓存的本地/blob 地址」（优先于网络取址）；
/// 4. `onlyCached`：「仅播放已缓存」开关（持久化到 KV）。
///
/// 纪律：
/// - **播放地址仍然不落库**——落库的只有字节键（章节 id）与状态/大小；
/// - 音频流是 CDN 直链，用独立的 [AudioFetcher] 拉取（不占 API 的 450ms
///   节流额度）；Web 端经 dev_proxy `/audio` 反代绕开 CORS；
/// - 失败逐章标记 failed，不阻塞队列（R8）。
class OfflineCacheService extends ChangeNotifier {
  OfflineCacheService({
    required this.daos,
    required this.playUrl,
    required this.albumSource,
    required this.store,
    required this.fetcher,
    this.log,
  });

  final Daos daos;
  final PlayUrlService playUrl;

  /// 合集/系列章节的 cid 解析（与播放链路同源，M8 修复：缓存前补 cid）。
  final AlbumSource albumSource;

  /// 音频字节存储（IO 文件 / Web IndexedDB）。
  final AudioStore store;

  /// 音频字节拉取器（独立 Dio，测试可注入 mock）。
  final AudioFetcher fetcher;

  final void Function(String message)? log;

  static const String keyOnlyCached = 'offline_only_cached';

  /// 已暂停（专辑级）：排队任务不继续跑。
  final Set<String> _pausedAlbums = {};

  /// 请求「取消中」的章节（暂停/删除时置位，下载协程在检查点消费）。
  final Set<String> _cancelling = {};

  bool _busy = false;
  KeyValueStore? _kv;
  bool _onlyCachedFlag = false;

  /// Web 预览端走 `/audio` 同源反代拉字节（CDN 直链会被 CORS 拦）。
  bool useAudioProxy = false;

  /// 「仅播放已缓存」开关（PRD §5.6.3，持久化）。
  bool get onlyCached => _onlyCachedFlag;

  /// 从 KV 恢复开关状态（DI 装配后调用一次）。
  Future<void> initFlags(KeyValueStore kv) async {
    _kv = kv;
    _onlyCachedFlag = kv.getString(keyOnlyCached) == '1';
    notifyListeners();
  }

  Future<void> setOnlyCached(bool v) async {
    _onlyCachedFlag = v;
    notifyListeners();
    await _kv?.setString(keyOnlyCached, v ? '1' : '0');
  }

  // -------------------------------------------------------------- 查询

  /// 全部任务（含各状态）。
  List<DownloadTask> tasks() => daos.downloads.all();

  /// 某专辑的任务（按章节排序交给 UI）。
  List<DownloadTask> tasksFor(String albumId) => daos.downloads
      .all()
      .where((t) => t.albumId == albumId)
      .toList();

  /// 某章节是否已缓存完成。
  bool isDone(String chapterId) =>
      daos.downloads.get(chapterId)?.status == DownloadStatus.done;

  /// 已缓存的播放地址（播放器优先使用）。
  Future<String?> cachedUrlFor(String chapterId) async {
    final task = daos.downloads.get(chapterId);
    if (task == null || task.status != DownloadStatus.done) return null;
    return store.playableUrl(chapterId);
  }

  /// 总占用字节（缓存页头部）。
  int get totalBytes => daos.downloads.totalBytes();

  /// 队列是否在消费中。
  bool get running => _busy;

  /// 某专辑是否被暂停。
  bool isPaused(String albumId) => _pausedAlbums.contains(albumId);

  // -------------------------------------------------------------- 入队/控制

  /// 整本缓存：未完成的章节全部入队（已 done 的跳过，failed 重新入队）。
  Future<void> cacheAlbum(Album album, List<Chapter> chapters) async {
    await daos.downloads.upsertAll([
      for (final c in chapters)
        if (daos.downloads.get(c.id)?.status != DownloadStatus.done)
          DownloadTask(
            chapterId: c.id,
            albumId: album.id,
            filePath: '',
            sizeBytes: 0,
            status: DownloadStatus.queued,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
    ]);
    _pausedAlbums.remove(album.id);
    notifyListeners();
    unawaited(_drain());
  }

  /// 缓存单章（播放页缓存面板「缓存本章」；已 done 的幂等跳过）。
  Future<void> cacheChapter(Album album, Chapter chapter) async {
    if (daos.downloads.get(chapter.id)?.status == DownloadStatus.done) return;
    await daos.downloads.upsert(DownloadTask(
      chapterId: chapter.id,
      albumId: album.id,
      filePath: '',
      sizeBytes: 0,
      status: DownloadStatus.queued,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ));
    _pausedAlbums.remove(album.id);
    notifyListeners();
    unawaited(_drain());
  }

  /// 暂停一个专辑（取消进行中的请求，剩余 queued 任务原地等待）。
  Future<void> pauseAlbum(String albumId) async {
    _pausedAlbums.add(albumId);
    for (final t in tasksFor(albumId)) {
      if (t.status == DownloadStatus.running) {
        _cancelling.add(t.chapterId);
        await daos.downloads.upsert(_withStatus(t, DownloadStatus.queued));
      }
    }
    notifyListeners();
  }

  /// 继续（恢复排队 + 重新拉起队列）。
  Future<void> resumeAlbum(String albumId) async {
    _pausedAlbums.remove(albumId);
    notifyListeners();
    unawaited(_drain());
  }

  /// 删除单集（含字节）。
  Future<void> deleteChapter(String chapterId) async {
    _cancelling.add(chapterId);
    try {
      await store.delete(chapterId);
    } catch (_) {}
    await daos.downloads.remove(chapterId);
    notifyListeners();
  }

  /// 整本删除（含字节；进行中的任务会被取消）。
  Future<void> deleteAlbum(String albumId) async {
    _pausedAlbums.add(albumId);
    for (final t in tasksFor(albumId)) {
      if (t.status == DownloadStatus.running) _cancelling.add(t.chapterId);
    }
    // 给下载协程一个检查点窗口，避免刚删完又被回写
    await Future<void>.delayed(const Duration(milliseconds: 200));
    for (final t in tasksFor(albumId)) {
      try {
        await store.delete(t.chapterId);
      } catch (_) {}
      await daos.downloads.remove(t.chapterId);
    }
    _pausedAlbums.remove(albumId);
    notifyListeners();
  }

  /// 全部清理（含字节；进行中的任务会被取消）。
  Future<void> clearAll() async {
    _pausedAlbums.addAll(tasks().map((t) => t.albumId));
    for (final t in tasks()) {
      if (t.status == DownloadStatus.running) _cancelling.add(t.chapterId);
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    try {
      await store.clearAll();
    } catch (_) {}
    await daos.downloads.clear();
    _pausedAlbums.clear();
    notifyListeners();
  }

  // -------------------------------------------------------------- 队列核心

  /// 串行消费队列（多入口调用只会有一个循环在跑）。
  Future<void> _drain() async {
    if (_busy) return;
    _busy = true;
    try {
      while (true) {
        final queued = tasks()
            .where((t) => t.status == DownloadStatus.queued)
            .toList();
        if (queued.isEmpty) break;
        final task = queued.firstWhere(
          (t) => !_pausedAlbums.contains(t.albumId),
          orElse: () => queued.first,
        );
        if (_pausedAlbums.contains(task.albumId)) break;
        await _runOne(task);
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _runOne(DownloadTask task) async {
    final chapter = daos.chapters.get(task.chapterId);
    if (chapter == null) {
      await daos.downloads.upsert(_withStatus(
        task,
        DownloadStatus.failed,
        error: '章节记录不存在（album/chapter 表缺失）',
      ));
      notifyListeners();
      return;
    }
    await daos.downloads.upsert(_withStatus(task, DownloadStatus.running));
    notifyListeners();

    try {
      // 1. 取址（复用 PlayUrlService 的重试/音质选择；地址只进内存）
      final album = daos.albums.get(task.albumId);
      final bvid = chapter.bvid.isNotEmpty ? chapter.bvid : (album?.bvid ?? '');
      var cid = chapter.cid;
      if (cid == 0) {
        // 合集/系列章节：与播放链路一致，取址前先解析 cid
        cid = await albumSource.resolveCid(chapter);
        if (cid == 0) throw BiliApiException(-1, '章节地址解析失败（cid 为空）');
      }
      if (bvid.isEmpty) throw BiliApiException(-1, '章节缺少 bvid，无法取址');
      final urls = await playUrl.resolve(bvid: bvid, cid: cid);
      if (_cancelling.remove(task.chapterId)) {
        _log('下载已暂停：${chapter.title}');
        return; // 保持 queued 状态
      }

      // 2. 拉字节（web 走同源反代；CDN 校验头仅原生需要）
      final headers = playUrl.headersFor(bvid);
      final bytes = await fetcher.fetchBytes(
        url: urls.first,
        headers: useAudioProxy ? const {} : headers,
        proxyUrlFor: useAudioProxy
            ? (u) => proxyUrlFor(u, headers)
            : null,
        isCancelled: () => _cancelling.contains(task.chapterId),
      );
      if (_cancelling.remove(task.chapterId)) {
        _log('下载已暂停：${chapter.title}');
        return;
      }

      // 3. 落盘 + 状态（filePath 键 = 章节 id，真实地址不落库）
      await store.save(task.chapterId, bytes);
      final size = await store.sizeOf(task.chapterId);
      await daos.downloads.upsert(DownloadTask(
        chapterId: task.chapterId,
        albumId: task.albumId,
        filePath: task.chapterId,
        sizeBytes: size,
        status: DownloadStatus.done,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ));
      _log('已缓存：${chapter.title}'
          '（${(size / 1024 / 1024).toStringAsFixed(1)}MB）');
    } catch (e) {
      if (_cancelling.remove(task.chapterId)) {
        _log('下载已暂停：${chapter.title}');
        return; // 暂停不算失败
      }
      await daos.downloads.upsert(
        _withStatus(task, DownloadStatus.failed, error: '$e'),
      );
      _log('缓存失败：${chapter.title} — $e');
    }
    notifyListeners();
  }

  DownloadTask _withStatus(
    DownloadTask t,
    DownloadStatus s, {
    String error = '',
  }) =>
      DownloadTask(
        chapterId: t.chapterId,
        albumId: t.albumId,
        filePath: t.filePath,
        sizeBytes: t.sizeBytes,
        status: s,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        error: error,
      );

  /// Web 预览：把 CDN 直链改写成 dev_proxy 的同源 `/audio` 反代
  /// （浏览器 XHR 拉 CDN 会被 CORS 拦；播放本身走 media_kit 引擎层不受限）。
  static String proxyUrlFor(String url, Map<String, String> headers) {
    final buf = StringBuffer('/audio?u=${Uri.encodeComponent(url)}');
    final ref = headers['Referer'];
    if (ref != null && ref.isNotEmpty) {
      buf.write('&ref=${Uri.encodeComponent(ref)}');
    }
    final ua = headers['User-Agent'];
    if (ua != null && ua.isNotEmpty) {
      buf.write('&ua=${Uri.encodeComponent(ua)}');
    }
    return buf.toString();
  }

  void _log(String msg) => log?.call(msg);
}

/// 音频字节拉取器（抽象便于测试注入）。
abstract class AudioFetcher {
  Future<List<int>> fetchBytes({
    required String url,
    required Map<String, String> headers,
    String Function(String url)? proxyUrlFor,
    bool Function()? isCancelled,
  });
}
