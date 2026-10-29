import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:kele_audio/core/api/album_source.dart';
import 'package:kele_audio/core/api/api_config.dart';
import 'package:kele_audio/core/api/bili_client.dart';
import 'package:kele_audio/core/api/bili_login_api.dart';
import 'package:kele_audio/core/api/key_value_store.dart';
import 'package:kele_audio/core/api/play_url_service.dart';
import 'package:kele_audio/core/data/daos.dart';
import 'package:kele_audio/core/data/local_database.dart';
import 'package:kele_audio/core/domain/playback.dart';
import 'package:kele_audio/core/services/bili_account_service.dart';
import 'package:kele_audio/core/services/mini_player_controller.dart';
import 'package:kele_audio/core/services/player/media_bridge.dart';
import 'package:kele_audio/core/services/player/player_service.dart';
import 'package:kele_audio/core/services/player/progress_store.dart';
import 'package:kele_audio/features/profile/pages/bili_account_page.dart';

/// 脚本化假网关：按序回放 poll 结果，可模拟生成/轮询失败。
class FakeGateway implements QrLoginGateway {
  FakeGateway({this.account});

  BiliAccount? account;
  final List<QrPollResult> pollResults = [];
  final List<String> polledKeys = [];
  Object? generateError;
  Object? pollError;

  int _pollIndex = 0;

  @override
  Future<QrTicket> generateQr() async {
    if (generateError != null) throw generateError!;
    return const QrTicket(
      qrContent: 'https://example.com/qr?key-1',
      qrcodeKey: 'key-1',
    );
  }

  @override
  Future<QrPollResult> pollQr(String qrcodeKey) async {
    polledKeys.add(qrcodeKey);
    if (pollError != null) throw pollError!;
    if (_pollIndex >= pollResults.length) {
      return const QrPollResult(status: QrScanStatus.waiting);
    }
    return pollResults[_pollIndex++];
  }

  @override
  Future<BiliAccount?> fetchAccount() async => account;
}

({BiliClient client, BiliAccountService service, FakeGateway gateway, MemoryKeyValueStore kv})
    buildService({
  List<QrPollResult> polls = const [],
  Object? generateError,
  BiliAccount? account,
  MemoryKeyValueStore? kv,
}) {
  final store = kv ?? MemoryKeyValueStore();
  final client = BiliClient(config: ApiConfig.defaults(), kv: store);
  final gateway = FakeGateway(account: account)
    ..pollResults.addAll(polls)
    ..generateError = generateError;
  final service = BiliAccountService(
    client: client,
    kv: store,
    gateway: gateway,
    // 单测手动 pollOnce，定时器拉长到不会触发
    pollInterval: const Duration(days: 1),
  );
  return (client: client, service: service, gateway: gateway, kv: store);
}

/// 冒烟用最小 PlayerService（不 init、不碰引擎；页面只读写音质档位）。
PlayerService buildPlayer(MemoryKeyValueStore kv) {
  final config = ApiConfig.defaults();
  final client = BiliClient(config: config, kv: kv);
  final db = LocalDatabase(kv);
  return PlayerService(
    playUrl: PlayUrlService(client: client, config: config),
    albumSource: AlbumSource(client: client, config: config),
    daos: Daos(db),
    store: ProgressStore(Daos(db)),
    prefs: PlayerPrefs(kv),
    miniPlayer: MiniPlayerController(),
    saveInterval: const Duration(seconds: 15),
    media: NoopMediaBridge(),
  );
}

void main() {
  group('QrPollResult 解析（纯函数）', () {
    test('parseLoginCookies：crossDomain 参数转 Cookie，排除 gourl', () {
      final cookies = QrPollResult.parseLoginCookies(
        'https://passport.bilibili.com/crossDomain'
        '?DedeUserID=42&DedeUserID__ckMd5=abc&Expires=1730000000'
        '&SESSDATA=s%2C1&bili_jct=t1&gourl=https%3A%2F%2Fwww.bilibili.com',
      );
      expect(cookies, {
        'DedeUserID': '42',
        'DedeUserID__ckMd5': 'abc',
        'Expires': '1730000000',
        'SESSDATA': 's,1',
        'bili_jct': 't1',
      });
    });

    test('parseLoginCookies：非法/空 URL 返回空', () {
      expect(QrPollResult.parseLoginCookies(''), isEmpty);
      expect(QrPollResult.parseLoginCookies('::::'), isEmpty);
    });

    test('parsePollData：0/86038/86090/86101 四态映射（abts 口径）', () {
      expect(
        QrPollResult.parsePollData({'code': 86101}).status,
        QrScanStatus.waiting,
      );
      expect(
        QrPollResult.parsePollData({'code': 86090}).status,
        QrScanStatus.scanned,
      );
      expect(
        QrPollResult.parsePollData({'code': 86038}).status,
        QrScanStatus.expired,
      );
      final ok = QrPollResult.parsePollData({
        'code': 0,
        'url': 'https://passport.bilibili.com/crossDomain'
            '?DedeUserID=42&SESSDATA=s%2C1&bili_jct=t1&gourl=x',
        'refresh_token': 'r1',
      });
      expect(ok.status, QrScanStatus.success);
      expect(ok.cookies, {'DedeUserID': '42', 'SESSDATA': 's,1', 'bili_jct': 't1'});
      expect(ok.refreshToken, 'r1');
      // 非 success 不带 Cookie
      expect(QrPollResult.parsePollData({'code': 86090}).cookies, isEmpty);
    });
  });

  group('BiliAccount.fromNavData（纯函数）', () {
    test('isLogin != true → null（未绑定）', () {
      expect(BiliAccount.fromNavData({'isLogin': false, 'mid': 1}), isNull);
      expect(BiliAccount.fromNavData(const {}), isNull);
    });

    test('会员字段双形态：vip.{type,status} 优先', () {
      final a = BiliAccount.fromNavData({
        'isLogin': true,
        'mid': 42,
        'uname': '可乐',
        'face': 'f.png',
        'vip': {'type': 2, 'status': 1},
        'vipType': 0,
        'vipStatus': 0,
      })!;
      expect(a.mid, 42);
      expect(a.vipType, 2);
      expect(a.vipStatus, 1);
      expect(a.isVip, isTrue);
    });

    test('会员字段双形态：扁平 vipType/vipStatus 回退', () {
      final a = BiliAccount.fromNavData({
        'isLogin': true,
        'mid': 7,
        'vipType': 1,
        'vipStatus': 1,
      })!;
      expect(a.vipType, 1);
      expect(a.vipStatus, 1);
      expect(a.isVip, isTrue);
    });

    test('无会员字段 → 0/0 视为非会员；status!=1 或 type==0 均非会员', () {
      final none = BiliAccount.fromNavData({'isLogin': true, 'mid': 1})!;
      expect(none.isVip, isFalse);

      final expired = BiliAccount.fromNavData({
        'isLogin': true,
        'mid': 1,
        'vip': {'type': 2, 'status': 0},
      })!;
      expect(expired.isVip, isFalse);

      final freeUser = BiliAccount.fromNavData({
        'isLogin': true,
        'mid': 1,
        'vip': {'type': 0, 'status': 1},
      })!;
      expect(freeUser.isVip, isFalse);
    });

    test('toJson/fromJson 保留会员字段（档案缓存重启不丢）', () {
      const a = BiliAccount(
        mid: 9,
        uname: 'x',
        face: '',
        vipType: 2,
        vipStatus: 1,
      );
      final b = BiliAccount.fromJson(a.toJson());
      expect(b.vipType, 2);
      expect(b.vipStatus, 1);
      expect(b.isVip, isTrue);
    });
  });

  group('BiliAccountService 扫码登录状态机', () {
    test('生成二维码 → waiting 并暴露二维码内容', () async {
      final env = buildService();
      addTearDown(env.service.stopQrLogin);

      await env.service.startQrLogin();
      expect(env.service.qrPhase, QrLoginPhase.waiting);
      expect(env.service.qrContent, 'https://example.com/qr?key-1');
      expect(env.service.bound, isFalse);
    });

    test('生成失败 → error 并带提示', () async {
      final env = buildService(generateError: Exception('boom'));
      addTearDown(env.service.stopQrLogin);

      await env.service.startQrLogin();
      expect(env.service.qrPhase, QrLoginPhase.error);
      expect(env.service.qrError, isNotNull);
      expect(env.service.qrContent, isNull);
    });

    test('等待扫码 → 已扫码 → 确认成功：写入会话并拉取档案', () async {
      final env = buildService(
        account: const BiliAccount(mid: 42, uname: '可乐', face: 'f.png'),
        polls: const [
          QrPollResult(status: QrScanStatus.waiting),
          QrPollResult(status: QrScanStatus.scanned),
          QrPollResult(
            status: QrScanStatus.success,
            cookies: {'SESSDATA': 's1', 'bili_jct': 't1', 'DedeUserID': '42'},
          ),
        ],
      );
      addTearDown(env.service.stopQrLogin);

      await env.service.startQrLogin();
      await env.service.pollOnce('key-1');
      expect(env.service.qrPhase, QrLoginPhase.waiting);

      await env.service.pollOnce('key-1');
      expect(env.service.qrPhase, QrLoginPhase.scanned);
      expect(env.service.bound, isFalse);

      await env.service.pollOnce('key-1');
      expect(env.service.qrPhase, QrLoginPhase.success);
      expect(env.service.bound, isTrue);
      expect(env.client.jar.get('SESSDATA'), 's1');
      expect(env.service.account?.uname, '可乐');
      expect(
        env.kv.getString(BiliAccountService.keyProfileCache),
        contains('可乐'),
      );
      expect(env.gateway.polledKeys, everyElement('key-1'));
    });

    test('二维码过期 → expired', () async {
      final env = buildService(polls: const [
        QrPollResult(status: QrScanStatus.expired),
      ]);
      addTearDown(env.service.stopQrLogin);

      await env.service.startQrLogin();
      await env.service.pollOnce('key-1');
      expect(env.service.qrPhase, QrLoginPhase.expired);
    });

    test('连续轮询失败 3 次 → error（R2 不硬刷）', () async {
      final env = buildService();
      addTearDown(env.service.stopQrLogin);
      env.gateway.pollError = Exception('net down');

      await env.service.startQrLogin();
      await env.service.pollOnce('key-1');
      expect(env.service.qrPhase, QrLoginPhase.waiting);
      await env.service.pollOnce('key-1');
      expect(env.service.qrPhase, QrLoginPhase.waiting);
      await env.service.pollOnce('key-1');
      expect(env.service.qrPhase, QrLoginPhase.error);
      expect(env.service.qrError, isNotNull);
    });

    test('档案缓存重启恢复；refreshProfile 未登录回报 → 就地解绑', () async {
      final kv = MemoryKeyValueStore();
      final env = buildService(
        kv: kv,
        account: const BiliAccount(mid: 7, uname: '小明', face: ''),
      );
      addTearDown(env.service.stopQrLogin);

      await env.client.acceptLoginCookies({'SESSDATA': 'sx'});
      await env.service.refreshProfile();
      expect(env.service.account?.uname, '小明');

      // 新实例从缓存恢复档案（模拟重启：initLocal 恢复会话 Cookie，同 bootstrap）
      final env2 = buildService(kv: kv);
      addTearDown(env2.service.stopQrLogin);
      await env2.client.initLocal();
      expect(env2.service.account?.uname, '小明');
      expect(env2.service.bound, isTrue);

      // nav 回报未登录 → 就地解绑并清缓存
      env2.gateway.account = null;
      await env2.service.refreshProfile();
      expect(env2.service.bound, isFalse);
      expect(env2.service.account, isNull);
      expect(kv.getString(BiliAccountService.keyProfileCache), isNull);
    });

    test('logout 解绑：清会话与档案缓存，保留 buvid 设备指纹', () async {
      final env = buildService(
        account: const BiliAccount(mid: 42, uname: '可乐', face: ''),
      );
      addTearDown(env.service.stopQrLogin);

      await env.client.acceptLoginCookies({'SESSDATA': 's1', 'bili_jct': 't1'});
      env.client.jar.put('buvid3', 'DEV-1');
      await env.service.refreshProfile();
      expect(env.service.bound, isTrue);

      await env.service.logout();
      expect(env.service.bound, isFalse);
      expect(env.client.jar.get('SESSDATA'), isNull);
      expect(env.client.jar.get('buvid3'), 'DEV-1');
      expect(env.kv.getString(BiliAccountService.keyProfileCache), isNull);
      expect(env.service.qrPhase, QrLoginPhase.idle);
    });
  });

  group('BiliAccountPage 冒烟', () {
    testWidgets('未绑定渲染扫码卡；已绑定渲染档案卡与解绑入口', (tester) async {
      final env = buildService();
      addTearDown(env.service.stopQrLogin);
      final player = buildPlayer(env.kv);
      addTearDown(player.dispose);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<BiliAccountService>.value(value: env.service),
            ChangeNotifierProvider<PlayerService>.value(value: player),
          ],
          child: const MaterialApp(home: BiliAccountPage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('扫码绑定'), findsOneWidget);
      expect(find.text('等待扫码…'), findsOneWidget);
      // 卸载页面触发 dispose → 停止轮询定时器
      await tester.pumpWidget(const SizedBox.shrink());

      final env2 = buildService(
        account: const BiliAccount(mid: 1, uname: '可乐', face: ''),
      );
      addTearDown(env2.service.stopQrLogin);
      await env2.client.acceptLoginCookies({'SESSDATA': 's'});
      await env2.service.refreshProfile();
      final player2 = buildPlayer(env2.kv);
      addTearDown(player2.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<BiliAccountService>.value(value: env2.service),
            ChangeNotifierProvider<PlayerService>.value(value: player2),
          ],
          child: const MaterialApp(home: BiliAccountPage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('可乐'), findsOneWidget);
      expect(find.text('UID 1'), findsOneWidget);
      expect(find.text('解除绑定'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('绑定成功自动升档：132K → 192K（Q2a）', (tester) async {
      final env = buildService(polls: const [
        QrPollResult(
          status: QrScanStatus.success,
          cookies: {'SESSDATA': 's1', 'bili_jct': 't1', 'DedeUserID': '9'},
        ),
      ]);
      addTearDown(env.service.stopQrLogin);
      env.gateway.account = const BiliAccount(mid: 9, uname: '新绑定', face: '');
      final player = buildPlayer(env.kv);
      addTearDown(player.dispose);
      expect(player.quality, AudioQuality.q132k); // 默认 132K

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<BiliAccountService>.value(value: env.service),
            ChangeNotifierProvider<PlayerService>.value(value: player),
          ],
          child: const MaterialApp(home: BiliAccountPage()),
        ),
      );
      await tester.pumpAndSettle();

      await env.service.startQrLogin();
      await env.service.pollOnce('key-1');
      await tester.pumpAndSettle();

      expect(env.service.bound, isTrue);
      expect(player.quality, AudioQuality.q192k); // 132K 自动升档
      expect(player.prefs.quality, AudioQuality.q192k); // 持久化
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
