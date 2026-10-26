import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kele_audio/core/services/player/audio_service_bridge.dart';
import 'package:kele_audio/core/services/player/media_bridge.dart';

/// P-02 回归：真机（2026-10-26）发现 `androidCompactActionIndices` 写死 4 个下标
/// 触发 PlaybackState 构造断言（≤3），整条状态推送被丢弃 → 通知栏/锁屏永远空。
void main() {
  AudioServiceBridge bridge() => AudioServiceBridge();

  test('紧凑栏下标随控件数量计算，且永远不超过 3 个', () {
    final b = bridge();

    b.publish(const MediaSnapshot(
      active: true,
      playing: true,
      hasPrev: true,
      hasNext: true,
    ));
    final full = b.playbackState.value;
    expect(full.controls.length, lessThanOrEqualTo(4));
    expect(full.androidCompactActionIndices, isNotNull);
    expect(full.androidCompactActionIndices!.length, lessThanOrEqualTo(3));
    // 下标必须指向真实存在的控件
    for (final i in full.androidCompactActionIndices!) {
      expect(i, lessThan(full.controls.length));
    }
    // 播放中显示「暂停」
    expect(
      full.controls.map((c) => c.action),
      contains(MediaAction.pause),
    );

    b.publish(const MediaSnapshot(active: true, playing: false));
    final bare = b.playbackState.value;
    expect(bare.androidCompactActionIndices!.length, lessThanOrEqualTo(3));
    expect(bare.controls.map((c) => c.action), contains(MediaAction.play));
    expect(bare.controls.map((c) => c.action), isNot(contains(MediaAction.pause)));
  });

  test('倍速随快照推给系统（锁屏进度按倍速外推）', () {
    final b = bridge();
    b.publish(const MediaSnapshot(active: true, playing: true, speed: 1.25));
    expect(b.playbackState.value.speed, 1.25);
  });

  test('无播放任务时推 idle 并清掉媒体项', () {
    final b = bridge();
    b.publish(const MediaSnapshot(active: true, playing: true));
    expect(b.mediaItem.value, isNotNull);

    b.publish(const MediaSnapshot());
    expect(b.mediaItem.value, isNull);
    expect(b.playbackState.value.processingState, AudioProcessingState.idle);
  });
}
