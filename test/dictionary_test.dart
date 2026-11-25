import 'package:flutter_test/flutter_test.dart';
import 'package:kele_audio/core/api/key_value_store.dart';
import 'package:kele_audio/core/domain/dictionary_entry.dart';
import 'package:kele_audio/core/services/dictionary/dictionary_pack_config.dart';
import 'package:kele_audio/core/services/dictionary/dictionary_service.dart';
import 'package:kele_audio/core/services/dictionary/dictionary_state_store.dart';

void main() {
  test('词库状态存取与类型切换', () async {
    final kv = MemoryKeyValueStore();
    final store = DictionaryStateStore(kv);
    store.load();
    expect(store.isInstalled, isFalse);
    expect(store.mode, DictionaryMode.simple);

    final compact = DictionaryInstallState(
      version: DictionaryPackConfig.versionFor(DictionaryMode.simple),
      installedAt: DateTime(2026, 11, 22, 9),
      size: 3 * 1024 * 1024,
      sha256: 'abc',
    );
    await store.save(compact);

    await store.setMode(DictionaryMode.full);
    expect(store.mode, DictionaryMode.full);
    expect(store.isInstalled, isFalse);
    expect(store.isInstalledFor(DictionaryMode.simple), isTrue);

    final full = DictionaryInstallState(
      version: DictionaryPackConfig.versionFor(DictionaryMode.full),
      installedAt: DateTime(2026, 11, 23, 9),
      size: 66 * 1024 * 1024,
      sha256: 'def',
    );
    await store.save(full);

    final reloaded = DictionaryStateStore(kv)..load();
    expect(reloaded.mode, DictionaryMode.full);
    expect(reloaded.state!.sha256, 'def');
    expect(reloaded.stateFor(DictionaryMode.simple)!.sha256, 'abc');

    await reloaded.clear();
    expect(reloaded.isInstalled, isFalse);
    expect(reloaded.isInstalledFor(DictionaryMode.simple), isTrue);
  });

  test('旧版单状态按精简词库迁移', () async {
    final kv = MemoryKeyValueStore();
    await kv.setString(
      DictionaryStateStore.key,
      '{"version":"ecdict-compact-v1","installedAt":"2026-11-22T09:00:00.000",'
      '"size":3890023,"sha256":"old"}',
    );
    final store = DictionaryStateStore(kv)..load();
    expect(store.mode, DictionaryMode.simple);
    expect(store.isInstalledFor(DictionaryMode.simple), isTrue);
    expect(store.state!.sha256, 'old');
  });

  test('两种词库使用各自的内置源，不再有自定义地址', () {
    expect(
      DictionaryPackConfig.sourcesFor(DictionaryMode.simple),
      contains('https://gcore.jsdelivr.net/gh/'
          'Gty2408/dsh-word-translate@HEAD/data/dict.json'),
    );
    expect(
      DictionaryPackConfig.sourcesFor(DictionaryMode.full),
      contains('https://raw.githubusercontent.com/'
          'skywind3000/ECDICT/master/ecdict.csv'),
    );
    expect(
      DictionaryPackConfig.versionFor(DictionaryMode.full),
      isNot(DictionaryPackConfig.versionFor(DictionaryMode.simple)),
    );
  });

  test('完整词库 CSV 与精简词库 JSON 均可解析', () {
    final csv = DictionaryService.parseCsvPack(
      'word,phonetic,translation,pos\n'
      'fox,/fɒks/,"n. 狐狸；[网络] 福克斯",n.\n'
      '"ice-cream",,"冰淇淋",\n',
      DictionaryMode.full,
    );
    expect(csv['version'], DictionaryPackConfig.fullVersion);
    final entries = csv['entries'] as Map<String, dynamic>;
    expect(entries.length, 2);
    expect(
      (entries['fox'] as Map)['translation'],
      'n. 狐狸；[网络] 福克斯',
    );
    expect((entries['ice-cream'] as Map)['translation'], '冰淇淋');

    final json = DictionaryService.parseJsonPack(
      '{"words":{"fox":{"ph":"/fɒks/","tr":"n. 狐狸"}},'
      '"lemmas":{"foxes":"fox"}}',
      DictionaryMode.simple,
    );
    expect(json['version'], DictionaryPackConfig.simpleVersion);
    final jsonEntries = json['entries'] as Map<String, dynamic>;
    expect((jsonEntries['fox'] as Map)['phonetic'], '/fɒks/');
    expect((json['aliases'] as Map)['foxes'], 'fox');
  });

  test('词条模型保留音标与词性', () {
    final entry = DictionaryEntry.fromJson({
      'word': 'fox',
      'translation': '狐狸',
      'pos': 'n.',
      'phonetic': '/fɒks/',
    });
    expect(entry.translation, '狐狸');
    expect(entry.pos, 'n.');
    expect(entry.phonetic, '/fɒks/');
    expect(entry.isEmpty, isFalse);
  });
}
