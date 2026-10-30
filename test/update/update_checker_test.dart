import 'package:flutter_test/flutter_test.dart';
import 'package:kele_audio/features/update/update_checker.dart';
import 'package:kele_audio/features/update/update_models.dart';

GhAsset _asset(String name, {String? digest}) => GhAsset(
      name: name,
      browserDownloadUrl: 'https://github.com/o/r/releases/download/t/$name',
      digest: digest,
    );

void main() {
  group('版本比较', () {
    test('1.10.0 > 1.9.9', () {
      expect(compareVersions('1.10.0', '1.9.9'), 1);
    });
    test('1.1 == 1.1.0', () {
      expect(compareVersions('1.1', '1.1.0'), 0);
    });
    test('去 v 前缀与 -beta 后缀', () {
      expect(compareVersions('v1.2.0-beta', '1.2.0'), 0);
      expect(compareVersions('v1.3.0', '1.2.9'), 1);
      expect(compareVersions('1.0.0+build5', '1.0.0'), 0);
    });
    test('isUpdateAvailable：同版本/更旧不提示，更新才提示', () {
      expect(isUpdateAvailable('1.1.0', '1.1.0'), isFalse);
      expect(isUpdateAvailable('1.0.9', '1.1.0'), isFalse);
      expect(isUpdateAvailable('2.0.0', '1.9.9'), isTrue);
    });
  });

  group('产物挑选', () {
    test('优先 universal 且排除 aab', () {
      final assets = <GhAsset>[
        _asset('app-release.aab'),
        _asset('app-release.apk'),
        _asset('app-android-universal.apk'),
      ];
      expect(selectAsset(assets)!.name, 'app-android-universal.apk');
    });
    test('无 universal 时兼容历史 app-release.apk', () {
      final assets = <GhAsset>[
        _asset('app-release.apk'),
        _asset('foo.apk'),
      ];
      expect(selectAsset(assets)!.name, 'app-release.apk');
    });
    test('排除 aab：仅 aab 时返回 null', () {
      expect(selectAsset(<GhAsset>[_asset('app.aab')]), isNull);
    });
    test('空列表返回 null', () {
      expect(selectAsset(<GhAsset>[]), isNull);
    });
  });

  group('源排序（提示词 3）', () {
    const String assetUrl = 'https://github.com/o/r/releases/download/t/x.apk';
    test('下载源：镜像在前，官方在最后', () {
      final List<String> order =
          buildDownloadSourceOrder(assetUrl, mirrors: <String>['https://m1/']);
      expect(order.first, startsWith('https://m1/'));
      expect(order.last, assetUrl);
    });
    test('接口源：官方优先（最权威），镜像在后', () {
      final List<String> order =
          buildApiSourceOrder(mirrors: <String>['https://m1/']);
      expect(order.first, contains('api.github.com'));
      expect(order.last, startsWith('https://m1/'));
    });
    test('自定义镜像排最前（dart-define 等价入参）', () {
      final List<String> order = buildDownloadSourceOrder(
        assetUrl,
        mirrors: <String>['https://custom/', 'https://m1/'],
      );
      expect(order[0], 'https://custom/https://github.com/o/r/releases/download/t/x.apk');
      expect(order[1], 'https://m1/https://github.com/o/r/releases/download/t/x.apk');
      expect(order.last, assetUrl);
    });
  });

  group('错误码翻译', () {
    test('常见码映射', () {
      expect(translateApiError(404), contains('未找到'));
      expect(translateApiError(403), contains('访问被拒绝'));
      expect(translateApiError(429), contains('限流'));
      expect(translateApiError(500), contains('暂时不可用'));
      expect(translateApiError(null, message: 'x'), contains('网络异常'));
    });
  });

  group('sha256 提取', () {
    test('提取并转小写', () {
      final GhAsset a = _asset('x.apk', digest: 'sha256:AbC123');
      expect(a.sha256, 'abc123');
    });
    test('非 sha256 返回 null（跳过校验不阻断）', () {
      final GhAsset a = _asset('x.apk', digest: 'sha1:deadbeef');
      expect(a.sha256, isNull);
    });
    test('缺 digest 返回 null', () {
      expect(_asset('x.apk').sha256, isNull);
    });
  });
}
