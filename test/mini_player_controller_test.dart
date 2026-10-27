import 'package:flutter_test/flutter_test.dart';
import 'package:kele_audio/core/services/mini_player_controller.dart';

MiniPlayerState _task({bool playing = false}) => MiniPlayerState(
      hasTask: true,
      albumTitle: '测试专辑',
      chapterTitle: '第1章',
      playing: playing,
    );

void main() {
  test('无播放内容不可见；有播放任务可见（需求1）', () {
    final c = MiniPlayerController();
    expect(c.visible, isFalse); // idle：无任务

    c.update(_task());
    expect(c.visible, isTrue);

    c.update(const MiniPlayerState.idle()); // 播放内容清空
    expect(c.visible, isFalse);
  });

  test('close 后不可见，reopen 后恢复（需求2）', () {
    final c = MiniPlayerController();
    c.update(_task(playing: true));
    expect(c.visible, isTrue);

    c.close();
    expect(c.closed, isTrue);
    expect(c.visible, isFalse); // 有任务但已关闭 → 隐藏

    // 播放状态推送不改变关闭标记（仍隐藏）
    c.update(_task(playing: false));
    expect(c.visible, isFalse);

    c.reopen(); // 新播放任务
    expect(c.closed, isFalse);
    expect(c.visible, isTrue);
  });

  test('close/reopen 幂等，无重复通知', () {
    final c = MiniPlayerController();
    var notified = 0;
    c.addListener(() => notified++);

    c.close();
    c.close();
    expect(notified, 1);

    c.reopen();
    c.reopen();
    expect(notified, 2);
  });

  test('reset 回到空闲并清除关闭标记', () {
    final c = MiniPlayerController();
    c.update(_task());
    c.close();
    expect(c.visible, isFalse);

    c.reset();
    expect(c.closed, isFalse);
    expect(c.state.hasTask, isFalse);
    expect(c.visible, isFalse); // 无任务仍不可见

    c.update(_task()); // 关闭标记已清 → 新任务直接显示
    expect(c.visible, isTrue);
  });
}
