import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:kele_audio/core/api/bili_client.dart';
import 'package:kele_audio/core/api/key_value_store.dart';
import 'package:kele_audio/core/data/local_database.dart';
import 'package:kele_audio/core/data/table.dart';
import 'package:kele_audio/core/domain/album.dart';
import 'package:kele_audio/core/services/backup/backup_crypto.dart';
import 'package:kele_audio/core/services/backup/backup_keys.dart';
import 'package:kele_audio/core/services/backup/backup_service.dart';
import 'package:kele_audio/core/services/settings_store.dart';

/// 组装「一台设备」：内存 KV + 本地库 + 备份服务。
({MemoryKeyValueStore kv, LocalDatabase db, BackupService service}) device() {
  final kv = MemoryKeyValueStore();
  final db = LocalDatabase(kv);
  return (
    kv: kv,
    db: db,
    service: BackupService(kv: kv, db: db),
  );
}

const shelfRow = {
  'album_id': 'al1',
  'created_at': 100,
  'last_chapter_id': 'c1',
  'last_position_sec': 30,
  'last_played_at': 200,
  'finished_chapters': 1,
  'total_chapters': 3,
};

const historyRow = {
  'album_id': 'al1',
  'chapter_id': 'c1',
  'position_sec': 30,
  'duration': 60,
  'played_at': 200,
  'chapter_title': '第一集',
};

const logRow = {
  'date': '2026-11-03',
  'album_id': 'al1',
  'category_id': 'novel',
  'duration_sec': 120,
};

const albumRow = {
  'id': 'al1',
  'source_type': 'multi_part',
  'title': '三体有声书',
  'cover_url': 'https://i0.hdslb.com/bfs/archive/cover.jpg',
  'up_name': '科幻电台',
  'chapter_count': 2,
  'category_id': 'novel',
  'bvid': 'BV1al1',
  'up_mid': 1001,
  'intro': '简介',
  'total_duration_sec': 120,
  'play_count': 999,
  'created_at': 100,
};

const chapterRows = [
  {
    'id': 'al1:101',
    'album_id': 'al1',
    'index': 0,
    'title': '第一集',
    'duration': 60,
    'bvid': 'BV1al1',
    'cid': 101,
  },
  {
    'id': 'al1:102',
    'album_id': 'al1',
    'index': 1,
    'title': '第二集',
    'duration': 60,
    'bvid': 'BV1al1',
    'cid': 102,
  },
];

/// 造专辑缓存 + 曲目（缓存表本身不进备份，只经轻量快照迁移）。
Future<void> seedAlbum(LocalDatabase db) async {
  await db.ensureCreated();
  await db.albums.upsert(db.albums.decode(Map<String, dynamic>.from(albumRow)));
  await db.chapters.upsertAll([
    for (final r in chapterRows)
      db.chapters.decode(Map<String, dynamic>.from(r)),
  ]);
}

/// 在源设备上造一份典型数据（设置 KV + 三表 + 登录态）。
Future<void> seedSource(
  MemoryKeyValueStore kv,
  LocalDatabase db,
) async {
  await db.ensureCreated();
  await kv.setString(SettingsStore.keyWifiOnly, '0');
  await kv.setString('player_rate', '1.5');
  await kv.setString('theme_preset', '3');
  await kv.setString(BiliClient.prefCookie, 'SESSDATA=abc; buvid3=xyz');
  await db.shelf
      .upsert(db.shelf.decode(Map<String, dynamic>.from(shelfRow)));
  await db.playHistory
      .upsert(db.playHistory.decode(Map<String, dynamic>.from(historyRow)));
  await db.playLogs.upsert(db.playLogs.decode(Map<String, dynamic>.from(logRow)));
}

void main() {
  test('明文备份导出再导入，数据一致（整体覆盖三表 + 设置 + 登录态）', () async {
    final src = device();
    await seedSource(src.kv, src.db);

    final bytes = await src.service.buildBackup();
    final dst = device();
    final staged = await dst.service.parseImport(bytes);
    await dst.service.applyImport(staged);

    expect(dst.kv.getString(SettingsStore.keyWifiOnly), '0');
    expect(dst.kv.getString('player_rate'), '1.5');
    expect(dst.kv.getString('theme_preset'), '3');
    expect(dst.kv.getString(BiliClient.prefCookie), 'SESSDATA=abc; buvid3=xyz');
    expect(dst.db.shelf.count, 1);
    expect(dst.db.shelf.all().first.albumId, 'al1');
    expect(dst.db.playHistory.count, 1);
    expect(dst.db.playLogs.count, 1);
  });

  test('导出→清空→导入：书架专辑元数据 / 分类 / 封面 URL / 曲目 / 进度齐全', () async {
    final src = device();
    await seedSource(src.kv, src.db);
    await seedAlbum(src.db);

    final bytes = await src.service.buildBackup();
    // 封面只随快照存 URL，不塞图片二进制
    expect(utf8.decode(bytes).contains('cover_url'), isTrue);

    final dst = device();
    final staged = await dst.service.parseImport(bytes);
    expect(staged.albumSnapshots, hasLength(1));
    expect(
      staged.entries.any((e) => e.key == BackupWhitelist.shelfAlbumMetaKey),
      isTrue,
    );
    await dst.service.applyImport(staged);

    final album = dst.db.albums.byId('al1');
    expect(album, isNotNull);
    expect(album!.title, '三体有声书');
    expect(album.categoryId, 'novel');
    expect(album.coverUrl, 'https://i0.hdslb.com/bfs/archive/cover.jpg');
    expect(album.upName, '科幻电台');
    expect(album.upMid, 1001);
    expect(album.sourceType, SourceType.multiPart);
    expect(dst.db.chapters.where((c) => c.albumId == 'al1'), hasLength(2));
    expect(dst.db.chapters.byId('al1:101')!.bvid, 'BV1al1');
    final shelf = dst.db.shelf.byId('al1');
    expect(shelf, isNotNull);
    expect(shelf!.lastChapterId, 'c1');
    expect(shelf.lastPositionSec, 30);
  });

  test('旧格式备份（无专辑快照）导入不崩：收藏保留，元数据留空交给补抓', () async {
    final src = device();
    await seedSource(src.kv, src.db);
    await seedAlbum(src.db);
    final bytes = await src.service.buildBackup();

    // 模拟旧版本导出：把新字段整个去掉
    final envelope = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final keys = (envelope['payload'] as Map)['keys'] as Map<String, dynamic>;
    keys.remove(BackupWhitelist.shelfAlbumMetaKey);
    final legacy = _bytes(jsonEncode(envelope));

    final dst = device();
    final staged = await dst.service.parseImport(legacy);
    expect(staged.albumSnapshots, isEmpty);
    await dst.service.applyImport(staged);
    expect(dst.db.shelf.count, 1); // 收藏还在
    expect(dst.db.albums.count, 0); // 元数据为空 → 书架走补抓/提示
    expect(dst.db.chapters.count, 0);
  });

  test('专辑快照损坏只跳过该段，其余数据正常导入', () async {
    final src = device();
    await seedSource(src.kv, src.db);
    await seedAlbum(src.db);
    final bytes = await src.service.buildBackup();

    final envelope = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final keys = (envelope['payload'] as Map)['keys'] as Map<String, dynamic>;
    keys[BackupWhitelist.shelfAlbumMetaKey] = 'not-a-json';
    final broken = _bytes(jsonEncode(envelope));

    final dst = device();
    final staged = await dst.service.parseImport(broken);
    expect(staged.albumSnapshots, isEmpty);
    await dst.service.applyImport(staged);
    expect(dst.db.shelf.count, 1);
  });

  test('加密备份导出再导入，数据一致', () async {
    final src = device();
    await seedSource(src.kv, src.db);

    final bytes = await src.service.buildBackup(password: 'p@ss word');
    final dst = device();
    final staged = await dst.service.parseImport(bytes, password: 'p@ss word');
    await dst.service.applyImport(staged);

    expect(dst.kv.getString('player_rate'), '1.5');
    expect(dst.db.shelf.count, 1);
  });

  test('加密备份用错密码被拒（统一口径不区分细节）', () async {
    final src = device();
    await seedSource(src.kv, src.db);

    final bytes = await src.service.buildBackup(password: 'right');
    final dst = device();
    expect(
      () => dst.service.parseImport(bytes, password: 'wrong'),
      throwsA(
        isA<BackupFailure>().having(
          (f) => f.kind,
          'kind',
          BackupFailureKind.wrongPassword,
        ),
      ),
    );
  });

  test('加密备份未给密码 → needsPassword（页面弹密码框重试）', () async {
    final src = device();
    await seedSource(src.kv, src.db);

    final bytes = await src.service.buildBackup(password: 'pw');
    final dst = device();
    expect(
      () => dst.service.parseImport(bytes),
      throwsA(
        isA<BackupFailure>().having(
          (f) => f.kind,
          'kind',
          BackupFailureKind.needsPassword,
        ),
      ),
    );
  });

  test('非本应用文件（magic 不匹配）被拒', () async {
    final dst = device();
    final bytes = _bytes(jsonEncode({'hello': 'world'}));
    expect(
      () => dst.service.parseImport(bytes),
      throwsA(
        isA<BackupFailure>().having(
          (f) => f.kind,
          'kind',
          BackupFailureKind.invalidFile,
        ),
      ),
    );
  });

  test('版本过新提示升级（tooNew）', () async {
    final src = device();
    await seedSource(src.kv, src.db);
    final bytes = await src.service.buildBackup();
    final map =
        (jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>)
          ..['formatVersion'] = 99;
    final tampered = _bytes(jsonEncode(map));

    final dst = device();
    expect(
      () => dst.service.parseImport(tampered),
      throwsA(
        isA<BackupFailure>().having(
          (f) => f.kind,
          'kind',
          BackupFailureKind.tooNew,
        ),
      ),
    );
  });

  test('加密备份被篡改（密文损坏）→ wrongPassword 口径', () async {
    final src = device();
    await seedSource(src.kv, src.db);
    final bytes = await src.service.buildBackup(password: 'pw');
    final map =
        (jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>)
            ['payload'] as Map<String, dynamic>;
    final ciphertext = base64Decode(map['ciphertext'] as String);
    ciphertext[0] ^= 0xff; // 翻转一位密文
    map['ciphertext'] = base64Encode(ciphertext);
    final envelope = (jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>)
      ..['payload'] = map;

    final dst = device();
    expect(
      () => dst.service.parseImport(
        _bytes(jsonEncode(envelope)),
        password: 'pw',
      ),
      throwsA(
        isA<BackupFailure>().having(
          (f) => f.kind,
          'kind',
          BackupFailureKind.wrongPassword,
        ),
      ),
    );
  });

  test('前向兼容：未知 key 忽略、null 跳过、文件没给的 key 不清除本机值', () async {
    final src = device();
    await seedSource(src.kv, src.db);
    final bytes = await src.service.buildBackup();

    final envelope = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final payload = envelope['payload'] as Map<String, dynamic>;
    final keys = payload['keys'] as Map<String, dynamic>;
    keys['some_future_key'] = 'whatever'; // 未来版本新增的 key
    keys[SettingsStore.keyWifiOnly] = null; // null 跳过
    keys.remove('player_rate'); // 文件没给的 key
    final tampered = _bytes(jsonEncode(envelope));

    final dst = device();
    // 目标机上本就有别的值：文件没给的 key 必须保持原样
    await dst.kv.setString('player_rate', '2.0');
    final staged = await dst.service.parseImport(tampered);
    await dst.service.applyImport(staged);

    expect(dst.kv.snapshot.containsKey('some_future_key'), isFalse);
    expect(dst.kv.getString('player_rate'), '2.0');
  });

  test('fail-safe：表行损坏 → corrupt，且未确认前本机数据完全不变', () async {
    final src = device();
    await seedSource(src.kv, src.db);
    final bytes = await src.service.buildBackup();

    final envelope = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final payload = envelope['payload'] as Map<String, dynamic>;
    final keys = payload['keys'] as Map<String, dynamic>;
    // 非 Map 行：结构级垃圾，fromJson 宽容兜不住，必须整体拒绝
    keys[Table.storageKey('shelf')] = [
      {'album_id': 'ok'},
      'garbage-not-a-map',
    ];
    final tampered = _bytes(jsonEncode(envelope));

    final dst = device();
    await dst.db.ensureCreated();
    await dst.kv.setString('player_rate', '2.0');

    await expectLater(
      dst.service.parseImport(tampered),
      throwsA(
        isA<BackupFailure>().having(
          (f) => f.kind,
          'kind',
          BackupFailureKind.corrupt,
        ),
      ),
    );
    // 解析失败：本机数据原封不动
    expect(dst.kv.getString('player_rate'), '2.0');
    expect(dst.db.shelf.count, 0);
  });

  test('白名单边界：缓存表（album/chapter）与设备指纹不进备份', () async {
    final src = device();
    await seedSource(src.kv, src.db);
    await src.kv.setString(Table.storageKey('album'), '[]'); // 缓存表
    await src.kv.setString('buvid_device', 'device-fingerprint'); // 设备信息

    final bytes = await src.service.buildBackup();
    final text = utf8.decode(bytes);

    expect(text.contains(Table.storageKey('album')), isFalse);
    expect(text.contains('buvid_device'), isFalse);

    // 备份里的 key 全部落在白名单内
    final payload =
        (jsonDecode(text) as Map<String, dynamic>)['payload']
            as Map<String, dynamic>;
    final keys = (payload['keys'] as Map).keys.toSet();
    final allowed = {
      for (final item in BackupWhitelist.settingsItems) item.key,
      for (final t in BackupWhitelist.tablesOf(src.db))
        Table.storageKey(t.name),
      BackupWhitelist.shelfAlbumMetaKey,
    };
    expect(keys.difference(allowed), isEmpty);
    expect(
      (payload['secure'] as Map).containsKey(BiliClient.prefCookie),
      isTrue,
    );
  });

  test('加密层：HMAC 覆盖 salt/iv/ciphertext，篡改任一部分都被拒', () {
    final payload = {'keys': {'a': '1'}};
    final enc = encryptBackupPayload(payload, 'pw');

    for (final field in ['salt', 'iv', 'ciphertext']) {
      final copy = Map<String, dynamic>.from(enc);
      final raw = base64Decode(copy[field] as String);
      raw[0] ^= 0xff;
      copy[field] = base64Encode(raw);
      expect(
        () => decryptBackupPayload(copy, 'pw'),
        throwsA(isA<BackupCryptoException>()),
        reason: field,
      );
    }
    // 正确密码可解回
    expect(decryptBackupPayload(enc, 'pw'), payload);
  });
}

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));
