// M3 内容源接口形态探针 —— 用工程内 core/api 抓真实响应，确认解析字段。
//
//   dart run tool/spike/m3_shape_probe.dart
//
// 目的：写 discover_source 解析代码前，确认这些接口的真实 JSON 形态：
//   1) 搜索 search_type=video 结果条目字段（bvid/pic/videos/duration/mid…）
//   2) 搜索 search_type=bili_user（UP 名 → mid 解析）
//   3) seasons_series_list（UP 合集/系列 meta 形态：标题、封面、集数字段）
//   4) seasons_archives_list（合集档案 meta + archives 形态）
//   5) 各分类关键词的过滤基线（标题/时长采样，用于定 filter 阈值）
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

  final out = <String, dynamic>{};

  // 1) 视频搜索条目形态
  final search = await client.get(
    config.url(BiliPaths.searchType),
    query: {
      'search_type': 'video',
      'keyword': '有声小说',
      'page': 1,
      'page_size': 20,
      'platform': 'pc',
      'web_location': 1430654,
      'order': 'click',
    },
    useWbi: true,
    headers: {
      'origin': config.searchHome,
      'referer': '${config.searchHome}/video?keyword=%E6%9C%89%E5%A3%B0%E5%B0%8F%E8%AF%B4',
    },
  );
  final sdata = (search.data as Map)['data'] as Map;
  final slist = (sdata['result'] as List?) ?? const [];
  print('1) video search: numResults=${sdata['numResults']} items=${slist.length}');
  if (slist.isNotEmpty) {
    final first = (slist.first as Map).cast<String, dynamic>();
    out['search_item_keys'] = first.keys.toList();
    out['search_item_sample'] = {
      for (final k in ['bvid', 'title', 'pic', 'author', 'mid', 'videos', 'episode_count_text', 'duration', 'play', 'pubdate', 'typeid', 'tag', 'description'])
        k: '${first[k]}',
    };
    print('   keys: ${first.keys.toList()}');
    print('   sample: ${jsonEncode(out['search_item_sample'])}');
  }

  // 2) UP 主解析（bili_user）
  await Future<void>.delayed(const Duration(milliseconds: 500));
  try {
    final user = await client.get(
      config.url(BiliPaths.searchType),
      query: {'search_type': 'bili_user', 'keyword': '紫襟', 'page': 1, 'page_size': 5},
      useWbi: true,
      headers: {
        'origin': config.searchHome,
        'referer': '${config.searchHome}/upuser?keyword=%E7%B4%AB%E8%A3%9B',
      },
    );
    final udata = (user.data as Map)['data'] as Map;
    final ulist = (udata['result'] as List?) ?? const [];
    print('2) bili_user search: items=${ulist.length}');
    out['bili_user_items'] = [
      for (final raw in ulist.take(3))
        if (raw is Map)
          {
            'mid': '${raw['mid']}',
            'uname': '${raw['uname']}',
            'fans': '${raw['fans']}',
            'keys': raw.keys.toList(),
            'usign': _cut('${raw['usign']}', 40),
          },
    ];
    print('   ${jsonEncode(out['bili_user_items'])}');
  } catch (e) {
    print('2) bili_user FAIL: $e');
    out['bili_user_error'] = '$e';
  }

  // 3) seasons_series_list（合集/系列 meta 形态）
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final mid = _firstMid(out);
  if (mid != null) {
    try {
      final res = await client.get(
        config.url(BiliPaths.upCollections),
        query: {'mid': mid, 'page_num': 1, 'page_size': 20},
        headers: {
          'origin': config.homeBase,
          'referer': '${config.homeBase}/space/$mid',
        },
      );
      final data = (res.data as Map)['data'] as Map?;
      final box = data?['items_lists'];
      print('3) seasons_series_list: data keys=${data?.keys.toList()}');
      out['seasons_series_data_keys'] = data?.keys.toList();
      if (box is Map) {
        final seasons = box['seasons_list'] as List? ?? const [];
        final series = box['series_list'] as List? ?? const [];
        print('   seasons=${seasons.length} series=${series.length}');
        if (seasons.isNotEmpty) {
          final meta = (seasons.first as Map)['meta'] as Map?;
          final archives = (seasons.first as Map)['archives'] as List? ?? const [];
          out['season_meta_keys'] = meta?.keys.toList();
          out['season_meta_sample'] = meta == null ? null : Map<String, dynamic>.from(meta);
          out['season_archives_len'] = archives.length;
          print('   season meta keys: ${meta?.keys.toList()}');
          print('   season meta: ${jsonEncode(meta)}');
          print('   archives preview len: ${archives.length}');
        }
        if (series.isNotEmpty) {
          final meta = (series.first as Map)['meta'] as Map?;
          out['series_meta_keys'] = meta?.keys.toList();
          out['series_meta_sample'] = meta == null ? null : Map<String, dynamic>.from(meta);
          print('   series meta keys: ${meta?.keys.toList()}');
          print('   series meta: ${jsonEncode(meta)}');
        }
      }
    } catch (e) {
      print('3) seasons_series_list FAIL: $e');
      out['seasons_error'] = '$e';
    }

    // 4) seasons_archives_list meta 形态
    final seasonId = _firstSeasonId(out);
    if (seasonId != null) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      try {
        final res = await client.get(
          config.url(BiliPaths.upCollectionArchives),
          query: {'season_id': seasonId, 'page_num': 1, 'page_size': 10},
          headers: {
            'origin': config.homeBase,
            'referer': '${config.homeBase}/space/$mid',
          },
        );
        final data = (res.data as Map)['data'] as Map?;
        final meta = data?['meta'] as Map?;
        final archives = data?['archives'] as List? ?? const [];
        print('4) seasons_archives_list: meta keys=${meta?.keys.toList()} archives=${archives.length}');
        print('   meta: ${jsonEncode(meta)}');
        out['archives_meta_keys'] = meta?.keys.toList();
        out['archives_meta_sample'] = meta == null ? null : Map<String, dynamic>.from(meta);
        out['archives_len'] = archives.length;
        if (archives.isNotEmpty) {
          final a = (archives.first as Map).cast<String, dynamic>();
          out['archive_item_keys'] = a.keys.toList();
          print('   archive item keys: ${a.keys.toList()}');
        }
      } catch (e) {
        print('4) seasons_archives_list FAIL: $e');
        out['archives_error'] = '$e';
      }
    }
  }

  // 5) 各分类关键词采样（过滤阈值基线）
  for (final kw in ['相声', '讲书', '纯音乐', '有声小说 全集']) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    try {
      final res = await client.get(
        config.url(BiliPaths.searchType),
        query: {
          'search_type': 'video',
          'keyword': kw,
          'page': 1,
          'page_size': 20,
          'platform': 'pc',
          'order': 'click',
        },
        useWbi: true,
        headers: {
          'origin': config.searchHome,
          'referer': '${config.searchHome}/video?keyword=${Uri.encodeComponent(kw)}',
        },
      );
      final data = (res.data as Map)['data'] as Map;
      final list = (data['result'] as List?) ?? const [];
      final samples = <Map<String, String>>[];
      for (final raw in list.take(12)) {
        if (raw is! Map) continue;
        samples.add({
          'title': '${raw['title'] ?? ''}'.replaceAll(RegExp(r'<[^>]*>'), ''),
          'dur': '${raw['duration']}',
          'videos': '${raw['videos']}',
          'typeid': '${raw['typeid']}',
        });
      }
      out['kw_$kw'] = {'total': '${data['numResults']}', 'samples': samples};
      print('5) [$kw] total=${data['numResults']} 采样:');
      for (final s in samples) {
        print('   ${s['dur']}s · ${s['videos']}P · type${s['typeid']} · ${s['title']}');
      }
    } catch (e) {
      print('5) [$kw] FAIL: $e');
      out['kw_${kw}_error'] = '$e';
    }
  }

  File('tool/spike/m3_shape_result.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(out));
  print('');
  print('已写入 tool/spike/m3_shape_result.json');
}

String _cut(String s, int n) => s.length <= n ? s : s.substring(0, n);

int? _firstMid(Map<String, dynamic> out) {
  final items = out['bili_user_items'];
  if (items is List && items.isNotEmpty) {
    return int.tryParse('${(items.first as Map)['mid']}');
  }
  return null;
}

int? _firstSeasonId(Map<String, dynamic> out) {
  final meta = out['season_meta_sample'];
  if (meta is Map && meta['season_id'] != null) {
    return int.tryParse('${meta['season_id']}');
  }
  return null;
}
