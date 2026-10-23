import '../domain/album.dart';
import '../domain/records.dart';
import 'daos.dart';

/// M1 准出证据：建表 + DAO 读写跑一遍，返回逐步结果给「工程自检」卡片展示。
class DaoDemoReport {
  const DaoDemoReport({
    required this.ok,
    required this.steps,
    required this.counts,
    required this.elapsedMs,
    required this.createInfo,
  });

  final bool ok;
  final List<String> steps;
  final Map<String, int> counts;
  final int elapsedMs;
  final String createInfo;

  String get summary => ok
      ? 'DAO 读写 Demo 通过 · ${elapsedMs}ms'
      : 'DAO 读写 Demo 失败：${steps.last}';
}

Future<DaoDemoReport> runDaoDemo(Daos daos) async {
  final steps = <String>[];
  final sw = Stopwatch()..start();
  var ok = true;
  Map<String, int> counts = {};

  try {
    final db = daos.db;
    final created = await db.ensureCreated();
    steps.add(created.describe);

    // ── 写：专辑 + 2 章 + 收藏 + 进度 ────────────────────────────────
    const albumId = 'm1-demo-album';
    await daos.albums.upsert(const Album(
      id: albumId,
      sourceType: SourceType.multiPart,
      title: 'M1 冒烟专辑（写入自检）',
      coverUrl: '',
      upName: 'kele-audio',
      chapterCount: 2,
      categoryId: 'demo',
      createdAt: 0,
    ));
    await daos.chapters.upsertAll(const [
      Chapter(
        id: '$albumId:1001',
        albumId: albumId,
        index: 1,
        title: '第一章 · 分层骨架',
        durationSec: 600,
        cid: 1001,
      ),
      Chapter(
        id: '$albumId:1002',
        albumId: albumId,
        index: 2,
        title: '第二章 · 主题与路由',
        durationSec: 720,
        cid: 1002,
      ),
    ]);
    await daos.shelf.add(albumId);
    await daos.playHistory.put(PlayHistory(
      albumId: albumId,
      chapterId: '$albumId:1002',
      positionSec: 128,
      durationSec: 720,
      playedAt: DateTime.now().millisecondsSinceEpoch,
      chapterTitle: '第二章 · 主题与路由',
    ));
    steps.add('写入 album×1、chapter×2、shelf×1、play_history×1');

    // ── 读：按主键回查 + 关联查询 ────────────────────────────────────
    final album = daos.albums.get(albumId);
    final chapters = daos.chapters.byAlbum(albumId);
    final history = daos.playHistory.forChapter(albumId, '$albumId:1002');
    final next = daos.chapters.nextOf('$albumId:1001');

    ok = album != null &&
        album.title == 'M1 冒烟专辑（写入自检）' &&
        chapters.length == 2 &&
        chapters.first.index == 1 &&
        history != null &&
        history.positionSec == 128 &&
        next != null &&
        next.index == 2;
    steps.add(
      '读回 album=${album != null ? '✓' : '✗'} '
      'chapters=${chapters.length}/2 '
      'progress=${history?.positionSec}s '
      'next=${next?.index == 2 ? '✓' : '✗'}',
    );
    steps.add(
      'shelf=${daos.shelf.has(albumId) ? '✓' : '✗'} '
      'history_count=${daos.playHistory.count} '
      'total=${daos.playLogs.count}条/${daos.playLogs.totalSeconds()}s',
    );

    // ── 删：清理 demo 数据（写→读→删 全链路） ───────────────────────
    await daos.shelf.remove(albumId);
    await daos.db.albums.deleteById(albumId);
    await daos.db.chapters.removeWhere((c) => c.albumId == albumId);
    await daos.playHistory.removeAlbum(albumId);
    ok = ok && !daos.shelf.has(albumId) && daos.albums.get(albumId) == null;
    steps.add('删除 demo 数据：shelf=${daos.shelf.has(albumId) ? '残留✗' : '✓'} '
        'album=${daos.albums.get(albumId) != null ? '残留✗' : '✓'}');

    counts = await daos.db.counts();
  } catch (e) {
    ok = false;
    steps.add('异常：$e');
  }

  sw.stop();
  return DaoDemoReport(
    ok: ok,
    steps: steps,
    counts: counts,
    elapsedMs: sw.elapsedMilliseconds,
    createInfo: steps.isEmpty ? '' : steps.first,
  );
}
