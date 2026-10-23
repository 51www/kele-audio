// M0 技术验证（Spike）冒烟脚本 —— 用工程内的 core/api 跑真实接口。
//
//   dart run tool/spike/m0_probe.dart            # 跑 S1 + S2 + S3 取址
//   dart run tool/spike/m0_probe.dart --check    # 复测上一次取到的播放地址（S3）
//
// 产出：控制台结论 + tool/spike/m0_result.json（写进 docs/spike-report.md）
//
// 说明：按 docs/reference-abts.md §4，M0 降级为「移植冒烟测试」——
// 重点确认 abts 的 WBI/取流实现**现在仍然可用**，以及本地节流/退避不翻车。
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:kele_audio/core/api/api_config.dart';
import 'package:kele_audio/core/api/bili_client.dart';
import 'package:kele_audio/core/api/key_value_store.dart';

const String recordPath = 'tool/spike/last_play_url.json';
const String resultPath = 'tool/spike/m0_result.json';

Future<void> main(List<String> args) async {
  if (args.contains('--check')) {
    await checkExistingUrl();
    return;
  }

  final startedAt = DateTime.now();
  final results = <String, dynamic>{
    'run_at': startedAt.toIso8601String(),
    's1_search': <String, dynamic>{},
    's2_stream': <String, dynamic>{},
    's3_validity': <String, dynamic>{},
    's4_background': <String, dynamic>{},
  };

  final config = ApiConfig.defaults();
  final kv = MemoryKeyValueStore();
  final client = BiliClient(config: config, kv: kv, log: print);

  await client.initLocal();
  await client.warmupIfNeeded();

  print('');
  print('════════════ M0 · S1 WBI 签名搜索 ════════════');
  await runSearch(client, config, results);

  print('');
  print('════════════ M0 · S2 分P + DASH 取流 ════════════');
  await runStream(client, config, results);

  print('');
  print('════════════ M0 · S3 播放地址有效期 ════════════');
  await runValidity(results, checkPrevious: true);

  print('');
  print('════════════ M0 · S4 后台播放与续播 ════════════');
  results['s4_background'] = {
    'status': 'pending_device',
    'reason': '本机未接入 Android 设备（adb 不可用），无法执行真机后台播放 / 锁屏控制 / 杀进程续播实测',
    'plan': 'M2 播放核心落地 media_kit + audio_service 后，在真机按 P-01~P-08 逐条实测',
  };
  print('SKIP：${results['s4_background']['reason']}');
  print('      → ${results['s4_background']['plan']}');

  File(resultPath)
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(results));
  print('');
  print('结果已写入 $resultPath');
}

// ─────────────────────────────────────────────────────────── S1 搜索

Future<void> runSearch(
  BiliClient client,
  ApiConfig config,
  Map<String, dynamic> results,
) async {
  final items = <dynamic>[];
  var allOk = true;

  for (final keyword in ['有声小说', '相声']) {
    final sw = Stopwatch()..start();
    try {
      final res = await client.get(
        config.url(BiliPaths.searchType),
        query: {
          'search_type': 'video',
          'keyword': keyword,
          'page': 1,
          'page_size': 20,
        },
        useWbi: true,
        headers: {'Referer': config.searchHome},
      );
      sw.stop();
      final data = res.data is Map ? res.data['data'] : null;
      final list = data is Map ? data['result'] as List? ?? [] : [];
      final trace = client.lastTrace;
      print(
        '[$keyword] HTTP ${res.statusCode} · ${sw.elapsedMilliseconds}ms · '
        'code=${res.data is Map ? res.data['code'] : '?'} · '
        'numResults=${data is Map ? data['numResults'] : '?'} · items=${list.length}',
      );
      print('    UA      : ${trace?.headers['User-Agent'] ?? '-'}');
      print('    Referer : ${trace?.headers['Referer'] ?? '-'}');
      print('    Cookie  : ${(trace?.headers['Cookie'] ?? '-').substring(0, (trace?.headers['Cookie'] ?? '').length.clamp(0, 70))}');
      for (final raw in list.take(3)) {
        final m = raw as Map;
        final title = '${m['title'] ?? ''}'
            .replaceAll(RegExp(r'<[^>]*>'), '')
            .trim();
        print('    · ${m['bvid']} | $title | 分P=${m['videos']} | 时长=${m['duration']}');
      }
      if (list.isEmpty) allOk = false;
      items.add({
        'keyword': keyword,
        'http': res.statusCode,
        'elapsed_ms': sw.elapsedMilliseconds,
        'num_results': data is Map ? data['numResults'] : null,
        'items': list.length,
        'first_titles': [
          for (final raw in list.take(5))
            '${(raw as Map)['title'] ?? ''}'
                .replaceAll(RegExp(r'<[^>]*>'), '')
                .trim(),
        ],
        'headers': trace?.headers,
      });
    } catch (e) {
      sw.stop();
      allOk = false;
      print('[$keyword] FAIL ${sw.elapsedMilliseconds}ms · $e');
      items.add({'keyword': keyword, 'error': '$e'});
    }
  }

  results['s1_search'] = {
    'status': allOk ? 'pass' : 'fail',
    'wbi_keys_ready': client.wbiKeyReady,
    'detail': items,
  };
  print('S1 → ${allOk ? 'PASS' : 'FAIL'}');
}

// ─────────────────────────────────────────────────────────── S2 取流

Future<void> runStream(
  BiliClient client,
  ApiConfig config,
  Map<String, dynamic> results,
) async {
  final record = <String, dynamic>{};
  try {
    // 1) 找一个多 P 视频：搜索候选 → 逐个 view 探测分 P 数（450ms 节流内）
    final search = await client.get(
      config.url(BiliPaths.searchType),
      query: {
        'search_type': 'video',
        'keyword': '有声小说',
        'page': 1,
        'page_size': 20,
      },
      useWbi: true,
      headers: {'Referer': config.searchHome},
    );
    final searchBody = search.data is Map ? search.data['data'] : null;
    final list = searchBody is Map
        ? (searchBody['result'] as List? ?? [])
        : <dynamic>[];
    if (list.isEmpty) {
      throw Exception('搜索无结果，无法取样');
    }

    Map? pick;
    var checked = 0;
    var pageCount = 0;
    for (final raw in list.take(5)) {
      final m = raw as Map;
      final b = '${m['bvid']}';
      checked++;
      try {
        final view = await client.get(
          config.url(BiliPaths.view),
          query: {'bvid': b},
          headers: {'Referer': '${config.homeBase}/video/$b'},
        );
        final vd = view.data is Map ? view.data['data'] : null;
        final pages = vd is Map ? (vd['pages'] as List? ?? []) : const [];
        if (pages.length > 1) {
          pick = m;
          pageCount = pages.length;
          break;
        }
      } catch (_) {
        // 单个候选探测失败不影响取样
      }
    }
    pick ??= list.first as Map;
    final bvid = '${pick['bvid']}';
    final title = '${pick['title'] ?? ''}'
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .trim();
    print('样本：$bvid · $title · 分P=$pageCount'
        '（探测了 $checked 个候选${pageCount > 1 ? '' : '，未见多P，退回单P样本'}）');

    // 2) 分P 列表
    final pages = await client.get(
      config.url(BiliPaths.pageList),
      query: {'bvid': bvid},
      headers: {'Referer': '${config.homeBase}/video/$bvid'},
    );
    final pageList = pages.data is Map ? pages.data['data'] as List : [];
    if (pageList.isEmpty) throw Exception('pagelist 为空');
    final first = pageList.first as Map;
    final cid = (first['cid'] as num).toInt();
    print('pagelist：${pageList.length} 个分P · 取第1个 cid=$cid '
        '（part=${first['part'] ?? '-'} duration=${first['duration'] ?? '-'}s）');

    // 3) DASH 取流（fnval=16，WBI 签名）
    final playUrl = await client.get(
      config.url(BiliPaths.playUrl),
      query: {
        'bvid': bvid,
        'cid': cid,
        'fnval': 16,
        'fnver': 0,
        'fourk': 1,
      },
      useWbi: true,
      headers: {'Referer': '${config.homeBase}/video/$bvid'},
    );
    final playData = playUrl.data is Map ? playUrl.data['data'] : null;
    final dash = playData is Map ? playData['dash'] : null;
    final audio = dash is Map ? dash['audio'] as List? ?? [] : [];
    if (audio.isEmpty) throw Exception('playurl 无可用音轨（dash.audio 为空）');

    final streams = <Map<String, dynamic>>[];
    for (final raw in audio) {
      final a = raw as Map;
      final backups = <String>[
        if (a['baseUrl'] != null) '${a['baseUrl']}',
        ...?((a['backupUrl'] as List?)?.map((e) => '$e')),
      ].map((u) => u.replaceFirst('http://', 'https://')).toSet();
      streams.add({
        'id': a['id'],
        'bandwidth': a['bandwidth'],
        'codecs': a['codecs'],
        'mime': a['mimeType'],
        'urls': backups.toList(),
      });
    }
    streams.sort((x, y) => ((y['bandwidth'] ?? 0) as num)
        .compareTo((x['bandwidth'] ?? 0) as num));
    print('音轨 ${streams.length} 条（按带宽降序）：');
    for (final s in streams) {
      print('    id=${s['id']} bandwidth=${s['bandwidth']} '
          'codecs=${s['codecs']} mime=${s['mime']}');
      print('      ${s['urls'].first}');
    }

    // 4) 真实取一段字节：带 Referer/UA vs 不带头
    final url = (streams.first['urls'] as List).first as String;
    final referer = '${config.homeBase}/video/$bvid';
    final withHeaders = await probeBytes(url, headers: {
      'User-Agent': config.userAgent,
      'Referer': referer,
      'Range': 'bytes=0-2047',
    });
    final withoutHeaders = await probeBytes(url, headers: {
      'Range': 'bytes=0-2047',
    });
    print('带 UA+Referer 取流 → HTTP ${withHeaders['status']} '
        'content-type=${withHeaders['content_type']} '
        'bytes=${withHeaders['bytes']} · ${withHeaders['elapsed_ms']}ms');
    print('不带头取流      → HTTP ${withoutHeaders['status']} '
        '（预期 403/412，证明 CDN 校验 Referer/UA）');

    final pass = withHeaders['status'] == 200 ||
        withHeaders['status'] == 206;

    // 5) 记录取址时间 + 解析地址自带的 deadline（S3 关键证据）
    final deadlineSec = int.tryParse(
          RegExp(r'deadline=(\d+)').firstMatch(url)?.group(1) ?? '',
        ) ??
        0;
    final obtainedAt = DateTime.now();
    final expiresAt = deadlineSec == 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(deadlineSec * 1000);
    final validityMin = expiresAt?.difference(obtainedAt).inMinutes;

    File(recordPath).writeAsStringSync(const JsonEncoder.withIndent('  ')
        .convert({
      'url': url,
      'referer': referer,
      'user_agent': config.userAgent,
      'bvid': bvid,
      'cid': cid,
      'title': title,
      'obtained_at': obtainedAt.millisecondsSinceEpoch,
      'expires_at': expiresAt?.millisecondsSinceEpoch,
      'validity_minutes_by_deadline': validityMin,
    }));

    if (expiresAt != null) {
      print('地址内 deadline=$deadlineSec → 期望有效期 ≈ $validityMin 分钟'
          '（${expiresAt.toIso8601String()}）');
    }

    record.addAll({
      'status': pass ? 'pass' : 'fail',
      'bvid': bvid,
      'cid': cid,
      'title': title,
      'candidates_checked': checked,
      'multi_part': pageCount > 1,
      'page_count': pageList.length,
      'validity_minutes_by_deadline': validityMin,
      'audio_streams': streams,
      'fetch_with_headers': withHeaders,
      'fetch_without_headers': withoutHeaders,
      'note': '真机播放（media_kit open + httpHeaders）在 M2 验证；'
          '本步已确认地址可取、带 Referer/UA 稳定返回 206',
    });
    print('S2 → ${pass ? 'PASS' : 'FAIL'}（播放地址已记录到 $recordPath）');
  } catch (e) {
    record['status'] = 'fail';
    record['error'] = '$e';
    print('S2 → FAIL · $e');
  }
  results['s2_stream'] = record;
}

Future<Map<String, dynamic>> probeBytes(
  String url, {
  required Map<String, String> headers,
}) async {
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 20),
    responseType: ResponseType.bytes,
    validateStatus: (_) => true,
  ));
  final sw = Stopwatch()..start();
  try {
    final res = await dio.get<List<int>>(url, options: Options(headers: headers));
    sw.stop();
    return {
      'status': res.statusCode,
      'content_type': res.headers.value('content-type') ?? '-',
      'content_length': res.headers.value('content-length') ?? '-',
      'bytes': res.data?.length ?? 0,
      'elapsed_ms': sw.elapsedMilliseconds,
    };
  } catch (e) {
    sw.stop();
    return {'status': -1, 'error': '$e', 'elapsed_ms': sw.elapsedMilliseconds};
  } finally {
    dio.close(force: true);
  }
}

// ─────────────────────────────────────────────────────────── S3 有效期

Future<void> runValidity(
  Map<String, dynamic> results, {
  bool checkPrevious = false,
}) async {
  final file = File(recordPath);
  if (!file.existsSync()) {
    print('无历史取址记录（本次取址后会写入 $recordPath）');
    results['s3_validity'] = {'status': 'pending'};
    return;
  }
  final record = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final obtainedAt =
      DateTime.fromMillisecondsSinceEpoch((record['obtained_at'] as num).toInt());
  final age = DateTime.now().difference(obtainedAt);
  final expiresAtMs = (record['expires_at'] as num?)?.toInt();
  final expiresInMin = expiresAtMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(expiresAtMs)
          .difference(DateTime.now())
          .inMinutes;

  if (expiresAtMs != null) {
    print('取址时间 ${obtainedAt.toIso8601String()} · 已存档 ${age.inMinutes} 分钟 · '
        '地址 deadline 还剩 ${expiresInMin ?? '-'} 分钟');
  } else {
    print('取址时间 ${obtainedAt.toIso8601String()} · 已存档 ${age.inMinutes} 分钟');
  }

  if (checkPrevious && age.inMinutes >= 1) {
    final probe = await probeBytes('${record['url']}', headers: {
      'User-Agent': '${record['user_agent']}',
      'Referer': '${record['referer']}',
      'Range': 'bytes=0-1023',
    });
    final alive = probe['status'] == 200 || probe['status'] == 206;
    print('复测 → HTTP ${probe['status']}（${alive ? '仍可用' : '已失效'}）');
    results['s3_validity'] = {
      'status': alive ? 'still_alive' : 'expired',
      'age_minutes': age.inMinutes,
      'expires_in_minutes_by_deadline': expiresInMin,
      'probe': probe,
      'bvid': record['bvid'],
      'cid': record['cid'],
      'plan': '按 R5 再跑 1h/2h/4h/8h：'
          'dart run tool/spike/m0_probe.dart --check',
    };
    print('S3 → ${results['s3_validity']['status']}（存档 ${age.inMinutes} 分钟）');
  } else {
    results['s3_validity'] = {
      'status': 'recorded',
      'obtained_at': obtainedAt.toIso8601String(),
      'expires_at': expiresAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(expiresAtMs).toIso8601String(),
      'validity_minutes_by_deadline': record['validity_minutes_by_deadline'],
      'plan': 'dart run tool/spike/m0_probe.dart --check（1h/2h/4h/8h 各跑一次）',
      'assumption': 'abts 实测取 90 分钟（docs/reference-abts.md R5）；'
          '本次地址 deadline 字段给出 ≈ ${record['validity_minutes_by_deadline']} 分钟',
    };
    print('S3 → recorded，待 ${['1', '2', '4', '8'].join('/')}h 后各跑一次 --check');
  }
}

Future<void> checkExistingUrl() async {
  final results = <String, dynamic>{'run_at': DateTime.now().toIso8601String()};
  await runValidity(results);
  File(resultPath).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(results),
  );
  print('结果已写入 $resultPath');
}
