// M3 spike: does seasons_archives_list work with season_id / series_id alone (no mid)?
import 'dart:convert';
import 'dart:io';

import 'package:kele_audio/core/api/api_config.dart';
import 'package:kele_audio/core/api/bili_client.dart';
import 'package:kele_audio/core/api/key_value_store.dart';

Future<void> main() async {
  final config = ApiConfig.defaults();
  final client = BiliClient(config: config, kv: MemoryKeyValueStore());
  await client.initLocal();
  final out = <String, dynamic>{};

  Future<Map<String, dynamic>?> probe(Map<String, String> params) async {
    try {
      final res = await client.get(
        config.url(BiliPaths.upCollectionArchives),
        query: params,
        useWbi: true,
      );
      final data = res.data is Map ? res.data['data'] as Map : null;
      final page = data?['page'] as Map?;
      final archives = data?['archives'] as List? ?? const [];
      return {
        'ok': true,
        'total': page?['total'],
        'first': archives.isEmpty
            ? null
            : {
                'bvid': (archives.first as Map)['bvid'],
                'title': (archives.first as Map)['title'],
                'duration': (archives.first as Map)['duration'],
              },
      };
    } catch (e) {
      return {'ok': false, 'err': e.toString()};
    }
  }

  out['season_no_mid'] =
      await probe({'season_id': '472823', 'page_num': '1', 'page_size': '3'});
  out['series_no_mid'] =
      await probe({'series_id': '132528', 'page_num': '1', 'page_size': '3'});
  out['series_with_mid'] = await probe({
    'mid': '3493285641823557',
    'series_id': '132528',
    'page_num': '1',
    'page_size': '3',
  });

  File('tool/spike/season_result.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(out));
  // ignore: avoid_print 调试脚本，直接 stdout 输出结果
  print(const JsonEncoder.withIndent('  ').convert(out));
}
