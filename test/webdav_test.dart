import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:kele_audio/core/api/key_value_store.dart';
import 'package:kele_audio/core/api/webdav_client.dart';
import 'package:kele_audio/core/data/local_database.dart';
import 'package:kele_audio/core/services/settings_store.dart';
import 'package:kele_audio/core/services/webdav_sync_service.dart';
import 'package:kele_audio/features/profile/pages/webdav_page.dart';

/// 内存假云端：记录 put/get，可注入故障。
class FakeCloudStore implements CloudStore {
  final Map<String, String> files = {};
  final List<String> dirs = [];
  Object? error;
  bool connectionOk = true;

  @override
  Future<void> testConnection() async {
    if (!connectionOk) throw WebdavException(401, '用户名或应用密码错误');
    if (error != null) throw error!;
  }

  @override
  Future<void> ensureDir(String path) async {
    if (error != null) throw error!;
    dirs.add(path);
  }

  @override
  Future<void> putFile(String path, String content) async {
    if (error != null) throw error!;
    files[path] = content;
  }

  @override
  Future<String?> getFile(String path) async {
    if (error != null) throw error!;
    return files[path];
  }
}

const shelfJson =
    '[{"album_id":"al1","created_at":100,"last_chapter_id":"c1",'
    '"last_position_sec":30,"last_played_at":200,"finished_chapters":1,'
    '"total_chapters":3}]';
const historyJson =
    '[{"album_id":"al1","chapter_id":"c1","position_sec":30,"duration":60,'
    '"played_at":200,"chapter_title":"第一集"}]';
const logJson =
    '[{"date":"2026-10-28","album_id":"al1","category_id":"novel",'
    '"duration_sec":120}]';

({
  WebdavSyncService service,
  FakeCloudStore store,
  KeyValueStore kv,
  LocalDatabase db,
}) buildEnv({Future<void> Function()? afterRestore}) {
  final kv = MemoryKeyValueStore();
  final db = LocalDatabase(kv);
  final store = FakeCloudStore();
  final service = WebdavSyncService(
    kv: kv,
    db: db,
    clientFactory: (_, _, _) => store,
    afterRestore: afterRestore,
  );
  return (service: service, store: store, kv: kv, db: db);
}

Future<void> seedLocalData(KeyValueStore kv, LocalDatabase db) async {
  await kv.setString('t_shelf', shelfJson);
  await kv.setString('t_play_history', historyJson);
  await kv.setString('t_play_log', logJson);
  await kv.setString(SettingsStore.keyWifiOnly, '0');
  await kv.setString('theme_preset', '3');
  await db.ensureCreated();
}

Future<void> bindDefault(WebdavSyncService service) => service.bind(
      url: 'https://dav.example.com/dav/',
      username: 'u',
      password: 'p',
    );

void main() {
  group('WebdavClient 纯函数', () {
    test('basicAuth：Base64 凭据头', () {
      expect(
        WebdavClient.basicAuth('user', 'pass'),
        'Basic ${base64.encode(utf8.encode('user:pass'))}',
      );
    });

    test('joinUrl：补尾斜杠 + 路径段编码（中文目录可用）', () {
      expect(
        WebdavClient.joinUrl(
          'https://dav.example.com/dav',
          'kele-audio/shelf.json',
        ),
        'https://dav.example.com/dav/kele-audio/shelf.json',
      );
      expect(
        WebdavClient.joinUrl('https://dav.example.com/dav/', '我的备份/a.json'),
        'https://dav.example.com/dav/${Uri.encodeComponent('我的备份')}/a.json',
      );
      expect(WebdavClient.joinUrl('https://x/dav/', ''), 'https://x/dav/');
    });
  });

  group('WebdavSyncService 绑定', () {
    test('testConnection 透传结果；bind 落凭据并暴露 bound', () async {
      final env = buildEnv();
      env.store.connectionOk = false;
      final bad = await env.service.testConnection(
        url: 'https://dav.example.com/dav/',
        username: 'u',
        password: 'p',
      );
      expect(bad.ok, isFalse);
      expect(env.service.bound, isFalse);

      env.store.connectionOk = true;
      final ok = await env.service.testConnection(
        url: 'https://dav.example.com/dav/',
        username: 'u',
        password: 'p',
      );
      expect(ok.ok, isTrue);

      await env.service.bind(
        url: 'https://dav.example.com/dav/',
        username: 'u',
        password: 'p',
        dir: '备份目录',
      );
      expect(env.service.bound, isTrue);
      expect(env.service.serverUrl, 'https://dav.example.com/dav/');
      expect(env.service.dir, '备份目录');

      await env.service.unbind();
      expect(env.service.bound, isFalse);
      expect(env.service.dir, WebdavSyncService.defaultDir);
      expect(env.kv.getString(WebdavSyncService.keyPassword), isNull);
    });
  });

  group('WebdavSyncService 备份/同步（整体覆盖）', () {
    test('backup：建目录并写 4 个文件，内容可解析', () async {
      final env = buildEnv();
      await seedLocalData(env.kv, env.db);
      await bindDefault(env.service);

      final result = await env.service.backup();
      expect(result.ok, isTrue, reason: result.message);
      expect(env.store.dirs, contains('kele-audio'));
      expect(env.store.files.keys, {
        'kele-audio/settings.json',
        'kele-audio/shelf.json',
        'kele-audio/play_history.json',
        'kele-audio/play_log.json',
      });

      final settings =
          jsonDecode(env.store.files['kele-audio/settings.json']!)
              as Map<String, dynamic>;
      expect(settings[SettingsStore.keyWifiOnly], '0');
      expect(settings['theme_preset'], '3');
      expect(jsonDecode(env.store.files['kele-audio/shelf.json']!), hasLength(1));
    });

    test('syncFromCloud：云端缺文件 → 失败且本机不动', () async {
      final env = buildEnv();
      await seedLocalData(env.kv, env.db);
      await bindDefault(env.service);
      await env.service.backup();
      env.store.files.remove('kele-audio/play_log.json');

      final result = await env.service.syncFromCloud();
      expect(result.ok, isFalse);
      expect(result.message, contains('play_log.json'));
      expect(env.db.shelf.all(), hasLength(1)); // 本机未被覆盖
    });

    test('syncFromCloud：备份→改动本机→同步回来，整体覆盖恢复', () async {
      var restored = 0;
      final env = buildEnv(afterRestore: () async => restored++);
      await seedLocalData(env.kv, env.db);
      await bindDefault(env.service);
      await env.service.backup();

      // 本机改动：删收藏、清日志、改设置
      await env.db.shelf.deleteById('al1');
      await env.db.playLogs.clear();
      await env.kv.setString(SettingsStore.keyWifiOnly, '1');
      expect(env.db.shelf.all(), isEmpty);

      final result = await env.service.syncFromCloud();
      expect(result.ok, isTrue);
      expect(restored, 1);
      expect(env.db.shelf.all(), hasLength(1));
      expect(env.db.shelf.all().first.albumId, 'al1');
      expect(env.db.playLogs.all(), hasLength(1));
      expect(env.db.playHistory.all(), hasLength(1));
      expect(env.kv.getString(SettingsStore.keyWifiOnly), '0');
    });

    test('syncFromCloud：云端缺设置 key = 恢复默认（移除本机 key）', () async {
      final env = buildEnv();
      await seedLocalData(env.kv, env.db);
      await bindDefault(env.service);
      await env.service.backup();
      final settings = Map<String, dynamic>.from(
        jsonDecode(env.store.files['kele-audio/settings.json']!)
            as Map<String, dynamic>,
      )..remove('theme_preset');
      env.store.files['kele-audio/settings.json'] = jsonEncode(settings);

      await env.service.syncFromCloud();
      expect(env.kv.getString('theme_preset'), isNull);
    });

    test('syncFromCloud：云端格式异常 → 失败且本机不动', () async {
      final env = buildEnv();
      await seedLocalData(env.kv, env.db);
      await bindDefault(env.service);
      await env.service.backup();
      env.store.files['kele-audio/shelf.json'] = '{"not":"a list"}';

      final result = await env.service.syncFromCloud();
      expect(result.ok, isFalse);
      expect(result.message, contains('格式异常'));
      expect(env.db.shelf.all(), hasLength(1));
    });

    test('未绑定时备份/同步直接失败', () async {
      final env = buildEnv();
      expect((await env.service.backup()).ok, isFalse);
      expect((await env.service.syncFromCloud()).ok, isFalse);
    });
  });

  group('WebdavPage 冒烟', () {
    testWidgets('未绑定渲染表单；已绑定渲染备份/同步/解绑', (tester) async {
      final env = buildEnv();
      await tester.pumpWidget(
        ChangeNotifierProvider<WebdavSyncService>.value(
          value: env.service,
          child: const MaterialApp(home: WebdavPage()),
        ),
      );
      expect(find.text('绑定 WebDAV'), findsOneWidget);
      expect(find.text('测试连接'), findsOneWidget);
      expect(find.text('绑定'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());

      await bindDefault(env.service);
      await tester.pumpWidget(
        ChangeNotifierProvider<WebdavSyncService>.value(
          value: env.service,
          child: const MaterialApp(home: WebdavPage()),
        ),
      );
      expect(find.text('已绑定'), findsOneWidget);
      expect(find.text('备份到云端'), findsOneWidget);
      expect(find.text('从云端同步'), findsOneWidget);
      expect(find.text('解除绑定'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
