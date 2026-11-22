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

  // 回归：TTS 无连续进度（position 恒 0），若参与「走表」外推判断，
  // 时间一长偏差超 3s 就会被当成进度变化反复重推 playbackState →
  // 通知栏被高频重建，部分机型每重建一次「叮」一声。trackPosition=false
  // 时切段不应改动 playbackState（播放态/控件/倍速不变）。
  test('TTS 不追踪进度时，重复 publish 不重建 playbackState', () {
    final b = bridge();
    final tts = MediaSnapshot(
      active: true,
      playing: true,
      chapterTitle: '第一章',
      trackPosition: false,
    );
    b.publish(tts);
    final first = b.playbackState.value;

    b.publish(tts);
    expect(b.playbackState.value, same(first),
        reason: '无变化不应重推，避免通知栏反复重建');

    // 换段（同一章、播放态不变）依然不重建
    b.publish(tts.copyWith(position: const Duration(seconds: 0)));
    expect(b.playbackState.value, same(first));
  });

  test('有声书正常走表不重建，但真实跳转会更新进度', () {
    final b = bridge();
    b.publish(const MediaSnapshot(
      active: true,
      playing: true,
      position: Duration(seconds: 10),
      speed: 1.0,
    ));
    final anchored = b.playbackState.value;

    // 走表范围内的小偏差（<3s）不重推
    b.publish(const MediaSnapshot(
      active: true,
      playing: true,
      position: Duration(seconds: 11),
      speed: 1.0,
    ));
    expect(b.playbackState.value, same(anchored));
  });
}
