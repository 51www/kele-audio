import 'package:flutter_test/flutter_test.dart';

import 'package:kele_audio/core/api/api_config.dart';
import 'package:kele_audio/core/api/bili_client.dart';
import 'package:kele_audio/core/api/key_value_store.dart';
import 'package:kele_audio/core/api/play_url_service.dart';
import 'package:kele_audio/core/domain/playback.dart';

/// PlayUrlService._order 音质选择 + fallback 排序单测：
/// Hi-Res 目标档 flac 置顶（缺档时 192K 起降级），AAC 档位目标优先，
/// flac / dolby 殿后兜底。
PlayUrlService makeService() => PlayUrlService(
      client: BiliClient(
        config: ApiConfig.defaults(),
        kv: MemoryKeyValueStore(),
      ),
      config: ApiConfig.defaults(),
    );

AudioTrack track(int id, String url, {int bandwidth = 0, List<String> backup = const []}) =>
    AudioTrack(id: id, baseUrl: url, backupUrls: backup, bandwidth: bandwidth);

void main() {
  // 三个 AAC 档位：bandwidth 降序 = 192K > 132K > 64K
  final aacTracks = [
    track(30216, 'https://cdn/64k.m4a', bandwidth: 67000),
    track(30232, 'https://cdn/132k.m4a', bandwidth: 132000),
    track(30280, 'https://cdn/192k.m4a', bandwidth: 192000),
  ];

  test('Hi-Res 目标档：flac 置顶，其后 192K 起降级', () {
    final flac = track(30251, 'https://cdn/hires.flac', bandwidth: 1000000);
    final result = PlayUrlResult(
      tracks: aacTracks,
      flac: flac,
      dolby: track(30250, 'https://cdn/dolby.m4a', bandwidth: 256000),
    );

    final urls = makeService().orderUrls(result, AudioQuality.qHiRes);
    expect(urls, [
      'https://cdn/hires.flac', // ① flac 置顶
      'https://cdn/192k.m4a', // ② 192K 起降级
      'https://cdn/132k.m4a',
      'https://cdn/64k.m4a',
      'https://cdn/dolby.m4a', // ③ dolby 殿后
    ]);
  });

  test('Hi-Res 缺 flac：从 192K 起降级（不会先落到 132K）', () {
    final result = PlayUrlResult(tracks: aacTracks);

    final urls = makeService().orderUrls(result, AudioQuality.qHiRes);
    expect(urls.first, 'https://cdn/192k.m4a');
    expect(urls, [
      'https://cdn/192k.m4a',
      'https://cdn/132k.m4a',
      'https://cdn/64k.m4a',
    ]);
  });

  test('AAC 目标档：目标档最前，其余按 bandwidth 降序，flac/dolby 殿后', () {
    final result = PlayUrlResult(
      tracks: aacTracks,
      flac: track(30251, 'https://cdn/hires.flac', bandwidth: 1000000),
      dolby: track(30250, 'https://cdn/dolby.m4a', bandwidth: 256000),
    );

    final urls = makeService().orderUrls(result, AudioQuality.q132k);
    expect(urls, [
      'https://cdn/132k.m4a', // 目标 132K 置顶
      'https://cdn/192k.m4a',
      'https://cdn/64k.m4a',
      'https://cdn/hires.flac', // flac 兜底（非目标档不置顶）
      'https://cdn/dolby.m4a',
    ]);
  });

  test('AAC 目标档缺失：落到最接近的一档', () {
    // 只有 64K/132K，目标 192K → 132K（差距更小）优先
    final result = PlayUrlResult(tracks: [
      track(30216, 'https://cdn/64k.m4a', bandwidth: 67000),
      track(30232, 'https://cdn/132k.m4a', bandwidth: 132000),
    ]);

    final urls = makeService().orderUrls(result, AudioQuality.q192k);
    expect(urls.first, 'https://cdn/132k.m4a');
  });

  test('backup_url 展开 + http→https + 去重', () {
    final result = PlayUrlResult(tracks: [
      track(
        30280,
        'http://cdn/192k.m4a',
        backup: ['https://bak/192k.m4a', 'http://cdn/192k.m4a'],
      ),
      track(30232, 'https://bak/192k.m4a', bandwidth: 132000),
    ]);

    final urls = makeService().orderUrls(result, AudioQuality.q192k);
    expect(urls, [
      'https://cdn/192k.m4a', // http 转 https
      'https://bak/192k.m4a', // backup 展开且与第二条去重
    ]);
  });
}
