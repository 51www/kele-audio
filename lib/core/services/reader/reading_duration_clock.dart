/// 阅读计时的纯状态机：只累加页面「可见」的停留时长。
///
/// 页面负责把路由可见性（RouteAware）与应用前后台（WidgetsBindingObserver）
/// 两种统一信号翻译成 [pause] / [resume] / [stop]；计时本身只按可见时间段
/// 累加，不判断被哪个页面覆盖，也不持有页面状态。
///
/// 被覆盖期间调用 [pause]，恢复时 [resume] 重新开一段，因此不会把后台时间
/// 一次性补进统计；[takeIncrement] 只返回「尚未写入统计」的增量，重复调用
/// 不会重复累加，也不会返回负数。
class ReadingDurationClock {
  ReadingDurationClock({this.minDuration = const Duration(seconds: 5)});

  /// 可见总时长短于该阈值时不计入统计（沿用「满 5 秒才记」的既有口径）。
  final Duration minDuration;

  DateTime? _segmentStart;
  Duration _settled = Duration.zero;
  int _loggedSec = 0;
  bool _stopped = false;

  /// 累计可见时长（含正在进行的可见段）。
  Duration get _elapsed {
    final start = _segmentStart;
    if (start == null) return _settled;
    return _settled + DateTime.now().difference(start);
  }

  /// 暂停计时（页面被覆盖 / 退到后台），结算当前可见段。
  void pause() {
    if (_stopped) return;
    _settle();
  }

  /// 恢复计时（重新露出前台且当前路由可见）。
  void resume() {
    if (_stopped || _segmentStart != null) return;
    _segmentStart = DateTime.now();
  }

  /// 结束计时并冻结总时长；之后 [resume] 不会继续累加。
  void stop() {
    if (_stopped) return;
    _settle();
    _stopped = true;
  }

  /// 取走尚未写入统计的新增秒数。
  ///
  /// 总时长不足 [minDuration] 时返回 0 且不推进水位，等可见总时长够了再
  /// 一次性写入，避免短段先被丢弃、后面又重复累加同一段时间。
  int takeIncrement() {
    final total = _elapsed;
    if (total < minDuration) return 0;
    final totalSec = total.inSeconds;
    final delta = totalSec - _loggedSec;
    if (delta <= 0) return 0;
    _loggedSec = totalSec;
    return delta;
  }

  void _settle() {
    final start = _segmentStart;
    if (start == null) return;
    _settled += DateTime.now().difference(start);
    _segmentStart = null;
  }
}
