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

  test('AudioQuality 解锁梯度：64K/132K 匿名可用 → 192K 绑定 → Hi-Res 大会员', () {
    // 匿名：仅 64K/132K
    expect(AudioQuality.q64k.isUnlocked(bound: false, isVip: false), isTrue);
    expect(AudioQuality.q132k.isUnlocked(bound: false, isVip: false), isTrue);
    expect(AudioQuality.q192k.isUnlocked(bound: false, isVip: false), isFalse);
    expect(AudioQuality.qHiRes.isUnlocked(bound: false, isVip: false), isFalse);

    // 已绑定未会员：192K 解锁，Hi-Res 仍锁
    expect(AudioQuality.q192k.isUnlocked(bound: true, isVip: false), isTrue);
    expect(AudioQuality.qHiRes.isUnlocked(bound: true, isVip: false), isFalse);

    // 大会员：全解锁
    expect(AudioQuality.qHiRes.isUnlocked(bound: true, isVip: true), isTrue);

    // needsBinding / needsVip 口径
    expect(AudioQuality.q132k.needsBinding, isFalse);
    expect(AudioQuality.q192k.needsBinding, isTrue);
    expect(AudioQuality.qHiRes.needsBinding, isTrue);
    expect(AudioQuality.q192k.needsVip, isFalse);
    expect(AudioQuality.qHiRes.needsVip, isTrue);
  });

  test('AudioQuality.highestUnlocked：解绑→132K、会员过期→192K、大会员→Hi-Res', () {
    expect(
      AudioQuality.highestUnlocked(bound: false, isVip: false),
      AudioQuality.q132k,
    );
    expect(
      AudioQuality.highestUnlocked(bound: true, isVip: false),
      AudioQuality.q192k,
    );
    expect(
      AudioQuality.highestUnlocked(bound: true, isVip: true),
      AudioQuality.qHiRes,
    );
  });

  test('AudioQuality wire：hires 档位可持久化往返', () {
    final kv = MemoryKeyValueStore();
    final prefs = PlayerPrefs(kv);
    prefs.saveQuality(AudioQuality.qHiRes);
    expect(PlayerPrefs(kv).quality, AudioQuality.qHiRes);
    expect(AudioQuality.qHiRes.wire, 'hires');
    expect(AudioQuality.fromWire('hires'), AudioQuality.qHiRes);
  });

  test('PlayerPrefs.hiresHintShown：一次性流量提示标记，默认未提示', () {
    final kv = MemoryKeyValueStore();
    final prefs = PlayerPrefs(kv);
    expect(prefs.hiresHintShown, isFalse);

    prefs.saveHiresHintShown();
    expect(PlayerPrefs(kv).hiresHintShown, isTrue);
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

  test('SettingsStore.featuredVisible：默认显示，关闭后重启保留', () {
    final kv = MemoryKeyValueStore();
    expect(SettingsStore(kv).featuredVisible, isTrue);

    final store = SettingsStore(kv);
    store.setFeaturedVisible(false);
    expect(SettingsStore(kv).featuredVisible, isFalse);

    store.setFeaturedVisible(true);
    expect(SettingsStore(kv).featuredVisible, isTrue);
  });

  test('SettingsStore 分类显隐：默认全显，隐藏后重启保留，可再显示', () {
    final kv = MemoryKeyValueStore();
    final store = SettingsStore(kv);
    expect(store.isCategoryVisible('xiaoshuo'), isTrue);

    store.setCategoryVisible('xiaoshuo', false);
    store.setCategoryVisible('boke', false);
    expect(SettingsStore(kv).isCategoryVisible('xiaoshuo'), isFalse);
    expect(SettingsStore(kv).isCategoryVisible('boke'), isFalse);
    expect(SettingsStore(kv).isCategoryVisible('music'), isTrue);

    store.setCategoryVisible('xiaoshuo', true);
    expect(SettingsStore(kv).isCategoryVisible('xiaoshuo'), isTrue);
    expect(SettingsStore(kv).isCategoryVisible('boke'), isFalse);
  });

  test('「推荐」类固定显示：无法被隐藏', () {
    final kv = MemoryKeyValueStore();
    final store = SettingsStore(kv);

    store.setCategoryVisible(SettingsStore.pinnedCategoryId, false);
    expect(store.isCategoryVisible(SettingsStore.pinnedCategoryId), isTrue);
    expect(store.hiddenCategoryIds, isEmpty);
    expect(SettingsStore(kv).isCategoryVisible(SettingsStore.pinnedCategoryId),
        isTrue);
  });
}
