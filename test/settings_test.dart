import 'package:flutter_test/flutter_test.dart';

import 'package:kele_audio/core/api/key_value_store.dart';
import 'package:kele_audio/core/domain/playback.dart';
import 'package:kele_audio/core/services/player/progress_store.dart';
import 'package:kele_audio/core/services/settings_store.dart';

/// M5 设置持久化单测：自动连播开关、仅 Wi-Fi 占位开关、默认音质写入。
void main() {
  test('PlayerPrefs.autoNext：默认开，关闭后重启保留', () {
    final kv = MemoryKeyValueStore();
    expect(PlayerPrefs(kv).autoNext, isTrue); // 老数据无 key → 保持连播

    final prefs = PlayerPrefs(kv);
    prefs.saveAutoNext(false);
    expect(PlayerPrefs(kv).autoNext, isFalse);

    prefs.saveAutoNext(true);
    expect(PlayerPrefs(kv).autoNext, isTrue);
  });

  test('PlayerPrefs 音质/播放模式：写入后同 key 重启保留', () {
    final kv = MemoryKeyValueStore();
    final prefs = PlayerPrefs(kv);
    prefs.saveQuality(AudioQuality.q192k);
    prefs.saveMode(PlayMode.loopOne);

    final p2 = PlayerPrefs(kv);
    expect(p2.quality, AudioQuality.q192k);
    expect(p2.mode, PlayMode.loopOne);
  });

  test('SettingsStore.wifiOnlyDownload：默认开，可关可开并重启保留', () {
    final kv = MemoryKeyValueStore();
    expect(SettingsStore(kv).wifiOnlyDownload, isTrue);

    final store = SettingsStore(kv);
    store.setWifiOnlyDownload(false);
    expect(SettingsStore(kv).wifiOnlyDownload, isFalse);

    store.setWifiOnlyDownload(true);
    expect(SettingsStore(kv).wifiOnlyDownload, isTrue);
  });

  test('SettingsStore 变更触发 notifyListeners（设置页 watch 刷新）', () async {
    final store = SettingsStore(MemoryKeyValueStore());
    var notified = 0;
    store.addListener(() => notified++);

    await store.setWifiOnlyDownload(false);
    await store.setWifiOnlyDownload(true);
    expect(notified, 2);
  });
}
