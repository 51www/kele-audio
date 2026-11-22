import 'package:flutter_test/flutter_test.dart';
import 'package:kele_audio/core/api/up_profile_source.dart';
import 'package:kele_audio/core/domain/album.dart';

/// M11 主播主页：arc/search 投稿条目 → 专辑映射的单测。
void main() {
  test('arc 投稿条目归一成与搜索页同构的专辑（bvid / 时长 / mid）', () {
    final album = UpProfileSource.albumFromArc({
      'bvid': 'BV1xx411c7mD',
      'title': '有声书《三体》第 1 集',
      'pic': '//i1.hdslb.com/bfs/archive/a.jpg',
      'author': '紫襟丶白',
      'length': '12:34',
      'play': 12345,
      'created': 1700000000,
      'mid': 19566500,
    });

    expect(album, isNotNull);
    expect(album!.id, 'BV1xx411c7mD');
    expect(album.sourceType, SourceType.multiPart);
    expect(album.bvid, 'BV1xx411c7mD');
    expect(album.upName, '紫襟丶白');
    expect(album.upMid, 19566500);
    expect(album.totalDurationSec, 12 * 60 + 34);
    expect(album.playCount, 12345);
    expect(album.coverUrl, startsWith('https://'));
  });

  test('arc 条目缺 mid 时回退到传入的主播 mid', () {
    final album = UpProfileSource.albumFromArc(
      {'bvid': 'BV1yy', 'title': '作品'},
      fallbackMid: 42,
    );
    expect(album, isNotNull);
    expect(album!.upMid, 42);
    expect(album.upName, '');
    expect(album.totalDurationSec, 0);
  });

  test('bvid 为空的无效条目返回 null', () {
    expect(
      UpProfileSource.albumFromArc({'bvid': '', 'title': '无 bvid'}),
      isNull,
    );
  });
}
