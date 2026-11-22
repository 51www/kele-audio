import 'package:flutter_test/flutter_test.dart';
import 'package:kele_audio/core/api/key_value_store.dart';
import 'package:kele_audio/core/domain/dictionary_entry.dart';
import 'package:kele_audio/core/services/dictionary/dictionary_pack_config.dart';
import 'package:kele_audio/core/services/dictionary/dictionary_state_store.dart';

void main() {
  test('词库状态存取', () async {
    final kv = MemoryKeyValueStore();
    final store = DictionaryStateStore(kv);
    store.load();
    expect(store.isInstalled, isFalse);

    final installed = DictionaryInstallState(
      version: DictionaryPackConfig.version,
      installedAt: DateTime(2026, 11, 22, 9),
      size: 10 * 1024 * 1024,
      sha256: 'abc',
    );
    await store.save(installed);
    final reloaded = DictionaryStateStore(kv)..load();
    expect(reloaded.isInstalled, isTrue);
    expect(reloaded.state!.sha256, 'abc');
    expect(reloaded.state!.size, 10 * 1024 * 1024);

    await reloaded.clear();
    expect(reloaded.isInstalled, isFalse);
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
