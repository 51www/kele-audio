// M3 补充探针：mid → UP 主名称（合集卡片的「UP 主」字段来源）。
//
//   dart run tool/spike/upname_probe.dart
//
// 备选接口各打一发，确认哪个匿名可用、字段形态如何。
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:kele_audio/core/api/api_config.dart';
import 'package:kele_audio/core/api/bili_client.dart';
import 'package:kele_audio/core/api/key_value_store.dart';

Future<void> main() async {
  final config = ApiConfig.defaults();
  final kv = MemoryKeyValueStore();
  final client = BiliClient(config: config, kv: kv, log: print);
  await client.initLocal();
  await client.warmupIfNeeded();

  const mid = 19566500;
  final out = <String, dynamic>{};

  // A) 经典 card 接口（无 WBI）
  try {
    final res = await client.get(
      '${config.apiBase}/x/web-interface/card',
      query: {'mid': mid, 'photo': 'false'},
    );
    final data = res.data is Map ? (res.data['data'] as Map?) : null;
    final card = data?['card'];
    print('A) card: data keys=${data?.keys.toList()}');
    if (card is Map) {
      print('   card.name=${card['name']}  face=${card['face']}');
      out['card'] = {
        'ok': true,
        'name': '${card['name']}',
        'keys': card.keys.toList(),
      };
    } else {
      out['card'] = {'ok': false, 'data_keys': data?.keys.toList()};
    }
  } catch (e) {
    print('A) card FAIL: $e');
    out['card'] = {'ok': false, 'error': '$e'};
  }

  await Future<void>.delayed(const Duration(milliseconds: 500));

  // B) space 投稿搜索 meta.uname（WBI）
  try {
    final res = await client.get(
      config.url(BiliPaths.spaceArcSearch),
      query: {'mid': mid, 'ps': 1, 'pn': 1, 'order': 'pubdate'},
      useWbi: true,
    );
    final data = res.data is Map ? (res.data['data'] as Map?) : null;
    final meta = data?['meta'];
    print('B) arc/search: data keys=${data?.keys.toList()}');
    if (meta is Map) {
      print('   meta.uname=${meta['uname']}');
      out['arc_search'] = {
        'ok': true,
        'uname': '${meta['uname']}',
        'keys': meta.keys.toList(),
      };
    } else {
      out['arc_search'] = {'ok': false, 'data_keys': data?.keys.toList()};
    }
  } catch (e) {
    print('B) arc/search FAIL: $e');
    out['arc_search'] = {'ok': false, 'error': '$e'};
  }

  File('tool/spike/upname_result.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(out));
  print('已写入 tool/spike/upname_result.json');
}
