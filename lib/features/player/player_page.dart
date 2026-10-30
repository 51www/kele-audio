import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/theme/app_tokens.dart';
import '../../core/api/subtitle_source.dart';
import '../../core/domain/album.dart';
import '../../core/services/offline/offline_cache_service.dart';
import '../../core/services/player/player_service.dart';
import '../../core/services/shelf_controller.dart';
import 'transcript_body.dart';

/// 播放页（PRD §5.4）—— M2：真实播放控制。
///
/// 布局（拇指区重构）：上区「封面（默认）⇄ 文稿」二态切换（弹性高度，
/// 短屏自动压缩封面）；页面下部拇指区自上而下为——功能图标带
/// （收藏/定时/文稿/缓存/更多，无背景图标-only，语义进 tooltip，
/// 非默认状态用主色 + 状态点提示）→ 进度条 → 传输控件
/// （倍速文字居左、章节目录居右，参考同类产品播放页）。
/// 状态一律来自 [PlayerService]（唯一事实源）。
/// 播放模式不再提供页内切换，由设置页「默认播放模式」决定。
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  /// 上区视图开关：false=封面，true=文稿
  bool _showTranscript = false;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final player = context.watch<PlayerService>();
    final album = player.album;

    return Scaffold(
      appBar: AppBar(
        title: const Text('播放'),
        leading: IconButton(
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
          tooltip: '收起',
          onPressed: () {
            // go_router 栈：push 进入时弹回来源页；直达 /player 无栈可弹时兜底回发现页
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/discover');
            }
          },
        ),
        actions: [
          // 演练菜单：debug/profile 构建可见（release 不出现）
          if (!kReleaseMode)
            PopupMenuButton<String>(
              tooltip: '验收演练',
              icon: const Icon(Icons.bug_report_outlined),
              onSelected: (v) {
                if (v == 'expire') {
                  player.debugExpireCurrentUrl();
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(
                      const SnackBar(content: Text('P-05 演练：已作废当前地址，观察自动重取续播')),
                    );
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'expire', child: Text('模拟地址失效（P-05 演练）')),
              ],
            ),
        ],
      ),
      body: SafeArea(
        child: !player.hasSession
            // 「播放全部」先跳转后装载：装载完成前会话尚未提交，
            // 此时呈现装载态而非空闲态，避免页面跳转后闪过空态
            ? (player.loading ? const _LoadingView() : const _IdleView())
            : Padding(
                padding: EdgeInsets.symmetric(horizontal: tokens.spaceLg),
                child: Column(
                  children: [
                    // ── 睡眠定时：开启倒计时停止时顶部居中显示剩余时间 ──
                    if (player.hasSleepTimer || player.stopAtChapterEnd)
                      _SleepCountdown(player: player),

                    // ── 上区：封面（默认）⇄ 文稿（开关打开：顶端固定标题 +
                    // 下方滚动文本；跟随播放进度高亮，点击句子不 seek） ──
                    Expanded(
                      child: _showTranscript
                          ? _TranscriptView(player: player)
                          : _CoverPane(player: player, album: album),
                    ),

                    // ── 拇指区：功能图标带 → 进度条 → 传输控件，整体贴近页面下部 ──
                    _ControlBand(
                      player: player,
                      album: album,
                      showTranscript: _showTranscript,
                      onToggleTranscript: () => setState(
                        () => _showTranscript = !_showTranscript,
                      ),
                    ),
                    SizedBox(height: tokens.spaceMd),

                    // 进度条：位置更新走 positionTick（独立刷新，不整页重建）
                    _ProgressBar(player: player),
                    SizedBox(height: tokens.spaceSm),

                    // 传输控件：倍速（左）| 上一章/播放/下一章 | 章节（右），
                    // 参考同类产品播放页，常用功能贴拇指区两侧
                    Row(
                      children: [
                        _SpeedLabel(player: player),
                        Expanded(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                onPressed: player.hasPrev
                                    ? player.previous
                                    : null,
                                icon: const Icon(Icons.skip_previous_rounded),
                                iconSize: 34,
                              ),
                              const SizedBox(width: 8),
                              _PlayButton(player: player),
                              const SizedBox(width: 8),
                              IconButton(
                                onPressed: player.hasNext ? player.next : null,
                                icon: const Icon(Icons.skip_next_rounded),
                                iconSize: 34,
                              ),
                            ],
                          ),
                        ),
                        _IconAction(
                          icon: Icons.toc_rounded,
                          tooltip: '章节目录（${player.chapters.length}）',
                          onTap: () =>
                              _PlayerPageState._showChapterSheet(context, player),
                        ),
                      ],
                    ),
                    SizedBox(height: tokens.spaceMd),
                  ],
                ),
              ),
      ),
    );
  }

  static String _sleepLabel(PlayerService p) {
    if (p.stopAtChapterEnd) return '本章结束';
    if (!p.hasSleepTimer) return '定时';
    final m = p.sleepRemaining.inMinutes;
    final s = p.sleepRemaining.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  // ------------------------------------------------------------------ 面板

  static void _showSpeedSheet(BuildContext context, PlayerService player) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // 根节点必须撑满：Wrap 只按「最宽的一行」定宽，直接当根会用内容宽度
      // 收窄整张面板（手机上看就是两侧缺一条）。竖排用 Column + 无限宽兜底。
      builder: (context) => SafeArea(
        child: SizedBox(
          width: double.infinity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text('倍速', style: AppTokens.of(context).sectionStyle),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final v in PlayerService.speedSteps)
                      ChoiceChip(
                        label: Text('${_rateText(v)}x'),
                        selected: (v - player.rate).abs() < 0.001,
                        onSelected: (_) async {
                          await player.setRate(v);
                          if (context.mounted) Navigator.of(context).pop();
                        },
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  static String _rateText(double v) => v == v.roundToDouble()
      ? '${v.toInt()}'
      : v
            .toStringAsFixed(2)
            .replaceFirst(RegExp(r'0+$'), '')
            .replaceFirst(RegExp(r'\.$'), '');

  /// 定时关闭面板（PRD §5.4）：时长 / 本章结束 / 取消 三组语义分层——
  /// 6 个时长按 3×2 等宽网格排布（比列表更紧凑、对齐可比），
  /// 「本章结束」与「关闭定时」作为两个停止条件并排在底部。
  static void _showSleepSheet(BuildContext context, PlayerService player) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final tokens = AppTokens.of(sheetContext);
        final none = !player.hasSleepTimer && !player.stopAtChapterEnd;

        Future<void> apply(Future<void> Function() task) async {
          await task();
          if (sheetContext.mounted) Navigator.of(sheetContext).pop();
        }

        return SafeArea(
          top: false,
          // 底部安全距离：避开手势条/圆角屏，内容不贴边
          minimum: const EdgeInsets.only(bottom: 12),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text('定时关闭', style: tokens.sectionStyle),
                      const Spacer(),
                      _SleepStatusPill(player: player),
                    ],
                  ),
                  const SizedBox(height: 14),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      const gap = 8.0;
                      final w = (constraints.maxWidth - gap * 2) / 3;
                      return Wrap(
                        spacing: gap,
                        runSpacing: gap,
                        children: [
                          for (final m in const [5, 10, 15, 30, 45, 60])
                            SizedBox(
                              width: w,
                              child: _SleepOption(
                                label: '$m 分钟',
                                selected: _sel(player, m, none),
                                onTap: () => apply(
                                  () => player.setSleepTimer(minutes: m),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _SleepOption(
                          label: '本章结束',
                          selected: player.stopAtChapterEnd,
                          onTap: () =>
                              apply(() => player.setSleepTimer(minutes: 0)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _SleepOption(
                          label: '关闭定时',
                          selected: false,
                          enabled: !none,
                          onTap: () => apply(player.cancelSleepTimer),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  static bool _sel(PlayerService p, int minutes, bool none) {
    if (none || !p.hasSleepTimer || p.stopAtChapterEnd) return false;
    final diff = p.sleepRemaining.inMinutes - minutes;
    return diff == 0 || diff == -1;
  }

  /// 缓存面板：缓存本章 / 整本缓存（PRD §5.8；下载图标即入口语义）。
  static void _showCacheSheet(
    BuildContext context,
    PlayerService player,
    OfflineCacheService offline,
  ) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final tokens = AppTokens.of(sheetContext);
        final album = player.album;
        final chapter = player.currentChapter;
        final done = chapter != null && offline.isDone(chapter.id);
        final remaining = player.chapters
            .where((c) => !offline.isDone(c.id))
            .length;

        Future<void> run(Future<void> Function() task, String toast) async {
          await task();
          if (sheetContext.mounted) Navigator.of(sheetContext).pop();
          if (!context.mounted) return;
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(toast),
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 240),
              ),
            );
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('缓存', style: tokens.sectionStyle),
                ),
              ),
              ListTile(
                dense: true,
                leading: Icon(
                  done ? Icons.download_done_rounded : Icons.download_rounded,
                  color: done
                      ? Theme.of(sheetContext).colorScheme.primary
                      : null,
                ),
                title: Text(done ? '本章已缓存' : '缓存本章', style: tokens.bodyStyle),
                subtitle: chapter == null
                    ? null
                    : Text(
                        chapter.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tokens.captionStyle,
                      ),
                onTap: done || album == null || chapter == null
                    ? null
                    : () => run(
                        () => offline.cacheChapter(album, chapter),
                        '已加入缓存队列：${chapter.title}',
                      ),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.download_for_offline_outlined),
                title: Text(
                  remaining > 0 ? '整本缓存（$remaining 章待缓存）' : '整本已缓存',
                  style: tokens.bodyStyle,
                ),
                onTap: album == null || remaining == 0
                    ? null
                    : () => run(
                        () => offline.cacheAlbum(album, player.chapters),
                        '已加入缓存队列：${album.title}（$remaining 章）',
                      ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  static void _showChapterSheet(BuildContext context, PlayerService player) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        builder: (context, controller) {
          final tokens = AppTokens.of(context);
          final scheme = Theme.of(context).colorScheme;
          final chapters = player.chapters;
          return ListView.builder(
            controller: controller,
            padding: const EdgeInsets.only(bottom: 16),
            itemCount: chapters.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    '章节目录（${chapters.length}）',
                    style: tokens.sectionStyle,
                  ),
                );
              }
              final c = chapters[i - 1];
              final current = i - 1 == player.index;
              return ListTile(
                dense: true,
                selected: current,
                selectedTileColor: scheme.primary.withValues(alpha: 0.08),
                leading: Text(
                  current && player.playing
                      ? '▶'
                      : i.toString().padLeft(2, '0'),
                  style: tokens.numStyle.copyWith(
                    color: current ? scheme.primary : null,
                  ),
                ),
                title: Text(
                  c.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.bodyStyle.copyWith(
                    color: current ? scheme.primary : null,
                    fontWeight: current ? FontWeight.w700 : null,
                  ),
                ),
                trailing: Text(
                  _fmtDur(c.durationSec),
                  style: tokens.captionStyle,
                ),
                onTap: () {
                  player.playChapterAt(i - 1);
                  Navigator.of(context).pop();
                },
              );
            },
          );
        },
      ),
    );
  }

  static String _fmtDur(int sec) {
    if (sec <= 0) return '--:--';
    return fmtClock(Duration(seconds: sec));
  }
}

// ─────────────────────────────────────────────────────────────── 子部件

class _IdleView extends StatelessWidget {
  const _IdleView();

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final player = context.watch<PlayerService>();

    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: tokens.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.headphones_rounded,
              size: 56,
              color: scheme.onSurfaceVariant,
            ),
            SizedBox(height: tokens.spaceMd),
            Text('未选择内容', style: tokens.titleStyle),
            const SizedBox(height: 6),
            Text(
              player.error ?? '在发现页点开专辑选一章开始收听；听过的专辑会在这里续播',
              textAlign: TextAlign.center,
              style: tokens.bodyStyle,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => context.go('/discover'),
              icon: const Icon(Icons.explore_outlined, size: 18),
              label: const Text('去发现页'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 装载态：会话尚未提交（取址/打开引擎中）时替代空闲态，
/// 消除「播放全部」先跳转后装载路径上的空态闪烁。
class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(strokeWidth: 2.6),
          ),
          SizedBox(height: tokens.spaceMd),
          Text(
            '正在准备播放…',
            style: tokens.bodyStyle.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 睡眠定时状态文案：「本章结束」/「剩余 m:ss」/「未开启」。
String _sleepStatusText(PlayerService p) {
  if (p.stopAtChapterEnd) return '本章结束';
  if (!p.hasSleepTimer) return '未开启';
  final r = p.sleepRemaining;
  return '剩余 ${r.inMinutes}:${(r.inSeconds % 60).toString().padLeft(2, '0')}';
}

/// 睡眠定时剩余时间徽标（播放页顶部居中）：定时关闭开启倒计时停止时，
/// 显示「剩余 m:ss」随秒递减（数据源 [PlayerService.sleepRemaining]，每秒
/// notifyListeners 自动刷新）；「本章结束」模式显示模式文案。
class _SleepCountdown extends StatelessWidget {
  const _SleepCountdown({required this.player});

  final PlayerService player;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final label = _sleepStatusText(player);
    return Padding(
      padding: EdgeInsets.only(top: tokens.spaceXs, bottom: tokens.spaceXs),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(tokens.radiusPill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.alarm_rounded, size: 14, color: scheme.primary),
              const SizedBox(width: 5),
              Text(
                label,
                style: tokens.numStyle.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 定时面板头部的当前状态徽标（未开启 / 剩余 m:ss / 本章结束），
/// 与播放页顶部 [_SleepCountdown] 同一视觉语言（主色淡染胶囊 + 数字等宽）。
class _SleepStatusPill extends StatelessWidget {
  const _SleepStatusPill({required this.player});

  final PlayerService player;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final on = player.hasSleepTimer || player.stopAtChapterEnd;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: on
            ? scheme.primary.withValues(alpha: 0.12)
            : scheme.onSurface.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(tokens.radiusPill),
      ),
      child: Text(
        _sleepStatusText(player),
        style: tokens.numStyle.copyWith(
          color: on ? scheme.primary : scheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 定时面板选项按钮：胶囊形、高度 40、圆角/配色沿用主题 token——
/// 选中态主色淡染底 + 主色描边与文字 + 对勾，未选中态纸面淡底 + 发丝描边；
/// 禁用态（已关闭定时时点「关闭定时」）降透明度且不响应点击。
class _SleepOption extends StatelessWidget {
  const _SleepOption({
    required this.label,
    required this.selected,
    required this.onTap,
    this.enabled = true,
  });

  static const double height = 40;

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final Color fg = !enabled
        ? scheme.onSurfaceVariant.withValues(alpha: 0.45)
        : selected
        ? scheme.primary
        : scheme.onSurface;
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.14)
          : scheme.onSurface.withValues(alpha: 0.05),
      shape: StadiumBorder(
        side: BorderSide(
          color: selected
              ? scheme.primary.withValues(alpha: 0.45)
              : tokens.hairlineColor,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: SizedBox(
          height: height,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (selected) ...[
                Icon(Icons.check_rounded, size: 14, color: fg),
                SizedBox(width: tokens.spaceXs),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.bodyStyle.copyWith(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                    color: fg,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 上区默认视图：封面 + 标题（弹性高度，短屏自动压缩封面）。
class _CoverPane extends StatelessWidget {
  const _CoverPane({required this.player, required this.album});

  final PlayerService player;
  final Album? album;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final chapter = player.currentChapter;
    return LayoutBuilder(
      builder: (context, constraints) {
        final raw = math.min(
          constraints.maxWidth * 0.58,
          constraints.maxHeight * 0.58,
        );
        final coverSize = raw.clamp(140.0, 230.0).toDouble();
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: constraints.maxHeight,
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Cover(
                    coverUrl: album?.coverUrl ?? '',
                    size: coverSize,
                  ),
                  SizedBox(height: tokens.spaceLg),
                  Text(
                    album?.title ?? '未选择内容',
                    style: tokens.titleStyle,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    chapter?.title ?? '准备播放',
                    style: tokens.captionStyle,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (player.error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      player.error!,
                      style: tokens.captionStyle.copyWith(
                        color: scheme.error,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 上区文稿视图：顶端固定「专辑 + 章节」标题，下方整段滚动展示本章文稿。
///
/// **跟随播放进度高亮**：当前句高亮 + 自动滚动跟随，逻辑见
/// [TranscriptBody]（`transcript_body.dart`）；仍保持仅浏览的 PRD 收口：
/// 点击句子不 seek。
/// 数据源 [SubtitleSource]（按 `bvid:cid` 内存缓存）；加载中转圈，
/// 无字幕 / 拉取失败统一显示「本章暂无文稿」空态，不影响播放主链路。
class _TranscriptView extends StatefulWidget {
  const _TranscriptView({required this.player});

  final PlayerService player;

  @override
  State<_TranscriptView> createState() => _TranscriptViewState();
}

class _TranscriptViewState extends State<_TranscriptView> {
  /// null = 加载中；空列表 = 本章无文稿
  List<SubtitleCue>? _cues;

  /// 已完成加载的章节键（`bvid:cid`），用于切章重载与丢弃过期响应
  String? _loadedKey;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _TranscriptView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切章后重新拉取（同章命中内存缓存，直接返回）
    if (_chapterKey != _loadedKey) _load();
  }

  String? get _chapterKey {
    final c = widget.player.currentChapter;
    if (c == null || c.bvid.isEmpty || c.cid <= 0) return null;
    return '${c.bvid}:${c.cid}';
  }

  Future<void> _load() async {
    final chapter = widget.player.currentChapter;
    final key = _chapterKey;
    _loadedKey = key;
    if (chapter == null || key == null) {
      setState(() => _cues = const []);
      return;
    }
    setState(() => _cues = null);
    try {
      final cues = await context.read<SubtitleSource>().fetch(
            bvid: chapter.bvid,
            cid: chapter.cid,
          );
      // 已切章 / 页面已销毁：丢弃过期响应
      if (!mounted || _chapterKey != key) return;
      setState(() => _cues = cues);
    } catch (_) {
      if (!mounted || _chapterKey != key) return;
      setState(() => _cues = const []);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final album = widget.player.album;
    final chapter = widget.player.currentChapter;

    return Column(
      children: [
        // ── 顶端固定标题（不随文稿滚动） ──
        Padding(
          padding: EdgeInsets.only(top: tokens.spaceXs, bottom: tokens.spaceSm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                album?.title ?? '未选择内容',
                style: tokens.titleStyle,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                chapter?.title ?? '准备播放',
                style: tokens.captionStyle,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        // ── 文稿正文（可滚动） ──
        Expanded(child: _buildBody(tokens, Theme.of(context).colorScheme)),
      ],
    );
  }

  Widget _buildBody(AppTokens tokens, ColorScheme scheme) {
    final cues = _cues;
    if (cues == null) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      );
    }
    if (cues.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.menu_book_rounded,
              size: 40,
              color: scheme.onSurfaceVariant,
            ),
            SizedBox(height: tokens.spaceSm),
            Text('本章暂无文稿', style: tokens.bodyStyle),
            const SizedBox(height: 4),
            Text('该章节没有可用的字幕内容', style: tokens.captionStyle),
          ],
        ),
      );
    }
    // 跟随播放进度高亮 + 自动滚动（key 含章节：切章时走全新 State，
    // 高亮/滚动/测高缓存一并重建）
    return TranscriptBody(
      key: ValueKey(_loadedKey),
      cues: cues,
      positionTick: widget.player.positionTick,
    );
  }
}

/// 播放页封面。
///
/// 视觉语言（沿用当前主题配色，仅移植提示词的光影/质感/构图/氛围）：
/// 米白大圆角卡片承载核心视觉（封面图），柔光弥漫无硬阴影、边缘柔和不割裂；
/// 封面缺失时以「纸感卡片 + 琥珀→焦糖渐变插画（羽毛意象）+ 同色系虚化书本」
/// 营造纵深与治愈纸质人文氛围，渐变插画为全画面唯一高饱和焦点。
class _Cover extends StatelessWidget {
  const _Cover({required this.coverUrl, this.size = 230});

  final String coverUrl;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = AppTokens.of(context);
    final radius = tokens.radiusLg; // 大圆角

    // 柔光弥漫：无硬偏移、低浓度暖色弥散投影
    final softGlow = BoxShadow(
      color: scheme.primary.withValues(alpha: 0.20),
      blurRadius: 40,
      spreadRadius: -8,
      offset: Offset.zero,
    );

    // 核心视觉：封面图或纸感插画占位
    // 地址归一兜底：历史/系列专辑可能是 `//` 协议相对或明文 HTTP（Android 会拒绝加载）
    final url = Album.normalizeCover(coverUrl);
    final Widget visual;
    if (url.isEmpty) {
      visual = _CoverPlaceholder(size: size, scheme: scheme, tokens: tokens);
    } else {
      final decodeWidth = (size * MediaQuery.devicePixelRatioOf(context))
          .round();
      visual = Stack(
        fit: StackFit.expand,
        children: [
          Image.network(
            url,
            width: size,
            height: size,
            fit: BoxFit.cover,
            cacheWidth: decodeWidth,
            errorBuilder: (_, _, _) =>
                _CoverPlaceholder(size: size, scheme: scheme, tokens: tokens),
          ),
          // 底部同色系虚化书本：纵深与场景沉浸
          Align(
            alignment: const Alignment(0.92, 0.96),
            child: Transform.rotate(
              angle: 0.1,
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 9, sigmaY: 9),
                child: _buildBookStack(size, radius, scheme, tokens),
              ),
            ),
          ),
          // 卡片微微泛暖光：顶光 + 底晕，边缘柔和不割裂
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  scheme.primary.withValues(alpha: 0.12),
                  Colors.transparent,
                  scheme.secondary.withValues(alpha: 0.14),
                ],
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
          ),
        ],
      );
    }

    // 米白大圆角卡片承载核心视觉
    return SizedBox(
      width: size,
      height: size,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: [softGlow],
        ),
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          // 极浅暖光描边，避免边缘割裂
          border: Border.all(
            color: scheme.primary.withValues(alpha: 0.14),
            width: 1.5,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: visual,
        ),
      ),
    );
  }
}

/// 封面缺失时的纸感插画占位：暖奶油米白卡片 + 琥珀→焦糖渐变羽毛意象 +
/// 同色系虚化书本，营造温暖沉静的纸质人文氛围。
class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder({
    required this.size,
    required this.scheme,
    required this.tokens,
  });

  final double size;
  final ColorScheme scheme;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) {
    final radius = tokens.radiusLg;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: tokens.cardGradient, // 米白纸感微渐变
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 纸感暖光：柔和顶光，无硬阴影
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0.2, -0.35),
                radius: 1.15,
                colors: [
                  scheme.primary.withValues(alpha: 0.10),
                  Colors.transparent,
                ],
              ),
            ),
          ),
          // 虚化衬托物：堆叠书本（同色系），营造纵深
          Align(
            alignment: const Alignment(0.95, 0.98),
            child: Transform.rotate(
              angle: 0.12,
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 7, sigmaY: 7),
                child: _buildBookStack(size, radius, scheme, tokens),
              ),
            ),
          ),
          // 核心元素：琥珀橙/焦糖棕渐变插画（羽毛意象）唯一的焦点
          Center(child: _buildFeather(size, scheme, tokens)),
          // 顶部柔光弥漫，画面干净通透
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withValues(alpha: 0.20),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 同色系虚化「堆叠书本」衬托物，低浓度营造纵深。
Widget _buildBookStack(
  double size,
  double radius,
  ColorScheme scheme,
  AppTokens tokens,
) {
  final book = (double w, double h, Color c) => Container(
    width: w,
    height: h,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(radius * 0.4),
      color: c,
    ),
  );
  return SizedBox(
    width: size * 0.52,
    height: size * 0.52,
    child: Stack(
      alignment: Alignment.bottomCenter,
      children: [
        Positioned(
          bottom: 0,
          left: size * 0.03,
          child: book(
            size * 0.44,
            size * 0.11,
            scheme.secondary.withValues(alpha: 0.16),
          ),
        ),
        Positioned(
          bottom: size * 0.06,
          left: size * 0.07,
          child: book(
            size * 0.38,
            size * 0.10,
            scheme.primary.withValues(alpha: 0.14),
          ),
        ),
      ],
    ),
  );
}

/// 核心插画：琥珀→焦糖渐变「羽毛」意象（羽片 + 羽轴 + 顶部柔光高光），
/// 为全画面唯一高饱和焦点；羽轴用深棕炭灰细线点缀，克制不抢戏。
Widget _buildFeather(double size, ColorScheme scheme, AppTokens tokens) {
  final h = size * 0.52;
  final w = size * 0.17;
  return SizedBox(
    height: h,
    width: w,
    child: Stack(
      alignment: Alignment.center,
      children: [
        // 羽片：渐变胶囊，微微倾斜
        Transform.rotate(
          angle: -0.16,
          child: Container(
            width: w,
            height: h,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(w),
              gradient: tokens.accentGradient, // 琥珀橙 → 焦糖棕
              boxShadow: [
                BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.28),
                  blurRadius: 20,
                  spreadRadius: -4,
                ),
              ],
            ),
          ),
        ),
        // 羽轴：深棕炭灰细线
        Container(
          width: 2,
          height: h * 0.9,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(2),
            color: scheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
        // 顶部柔光高光
        Positioned(
          top: h * 0.07,
          child: Container(
            width: w * 0.5,
            height: h * 0.28,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(w),
              color: Colors.white.withValues(alpha: 0.4),
            ),
          ),
        ),
      ],
    ),
  );
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.player});

  final PlayerService player;

  @override
  Widget build(BuildContext context) {
    final busy = player.loading || player.recovering;
    final IconData icon;
    if (busy) {
      icon = Icons.hourglass_top_rounded;
    } else if (player.buffering) {
      icon = Icons.wifi_tethering_rounded;
    } else {
      icon = player.playing ? Icons.pause_rounded : Icons.play_arrow_rounded;
    }
    return FilledButton(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.all(0),
        minimumSize: const Size(72, 72),
        shape: const CircleBorder(),
      ),
      onPressed: busy ? null : player.toggle,
      child: busy
          ? const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 2.6),
            )
          : Icon(icon, size: 42),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.player});

  final PlayerService player;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Column(
      children: [
        ValueListenableBuilder<Duration>(
          valueListenable: player.positionTick,
          builder: (context, pos, _) {
            final total = player.duration.inMilliseconds;
            final value = total <= 0
                ? 0.0
                : (pos.inMilliseconds / total).clamp(0.0, 1.0);
            return Slider(
              value: value,
              onChanged: total <= 0
                  ? null
                  : (v) {
                      player.seek(Duration(milliseconds: (v * total).round()));
                    },
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              ValueListenableBuilder<Duration>(
                valueListenable: player.positionTick,
                builder: (context, pos, _) =>
                    Text(fmtClock(pos), style: tokens.numStyle),
              ),
              Text(fmtClock(player.duration), style: tokens.numStyle),
            ],
          ),
        ),
      ],
    );
  }
}

/// 功能图标带（进度条上方，拇指区上沿）：收藏 / 定时 / 文稿 /
/// 缓存 / 更多 —— 无背景、仅保留图标，文字信息收进 tooltip（长按可见并供无障碍
/// 朗读），「非默认值」以主色 + 6dp 状态点提示。倍速（文字）、章节分居
/// 传输行两侧。播放顺序切换已移除（设置页「默认播放模式」收口）。
class _ControlBand extends StatelessWidget {
  const _ControlBand({
    required this.player,
    required this.album,
    required this.showTranscript,
    required this.onToggleTranscript,
  });

  final PlayerService player;
  final Album? album;

  /// 文稿视图开关（true 时图标着主色）
  final bool showTranscript;
  final VoidCallback onToggleTranscript;

  @override
  Widget build(BuildContext context) {
    final sleepOn = player.hasSleepTimer || player.stopAtChapterEnd;

    return Row(
      children: [
        Expanded(child: _FavoriteAction(album: album)),
        Expanded(
          child: _IconAction(
            icon: Icons.alarm_rounded,
            tooltip: sleepOn ? '定时 ${_PlayerPageState._sleepLabel(player)}' : '定时关闭',
            active: sleepOn,
            onTap: () => _PlayerPageState._showSleepSheet(context, player),
          ),
        ),
        Expanded(
          child: _IconAction(
            icon: Icons.menu_book_rounded,
            tooltip: showTranscript ? '文稿（点击收起）' : '文稿',
            active: showTranscript,
            showBadge: false,
            onTap: onToggleTranscript,
          ),
        ),
        Expanded(child: _CacheAction(player: player)),
        Expanded(child: _MoreAction(album: album)),
      ],
    );
  }
}

/// 倍速入口（传输行左侧）：直接显示当前倍速文字（同类产品惯例），
/// 一眼可读当前值，点按弹倍速面板。
class _SpeedLabel extends StatelessWidget {
  const _SpeedLabel({required this.player});

  final PlayerService player;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final on = (player.rate - 1.0).abs() > 0.001;
    return Tooltip(
      message: '倍速 ${player.rateLabel}',
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: () => _PlayerPageState._showSpeedSheet(context, player),
        child: SizedBox(
          width: 56,
          height: 48,
          child: Center(
            child: Text(
              player.rateLabel,
              style: tokens.captionStyle.copyWith(
                color: on ? scheme.primary : scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 缓存入口：下载图标；当前章节已缓存后变 ✓ 并着主色（状态即语义）。
/// 点按弹「缓存本章 / 整本缓存」面板（PRD §5.8 离线缓存）。
class _CacheAction extends StatelessWidget {
  const _CacheAction({required this.player});

  final PlayerService player;

  @override
  Widget build(BuildContext context) {
    final offline = context.watch<OfflineCacheService>();
    final chapter = player.currentChapter;
    final done = chapter != null && offline.isDone(chapter.id);
    return _IconAction(
      icon: done ? Icons.download_done_rounded : Icons.download_rounded,
      tooltip: done ? '本章已缓存' : '缓存',
      active: done,
      showBadge: false, // ✓ 图标本身已表达完成态
      onTap: () => _PlayerPageState._showCacheSheet(context, player, offline),
    );
  }
}

/// 更多入口：纵向三点弹出菜单（暂含「查看专辑」）。
/// 菜单动作不打断播放：[PlayerService] 为全局单例，与路由无关。
class _MoreAction extends StatelessWidget {
  const _MoreAction({required this.album});

  final Album? album;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      tooltip: '更多',
      iconSize: 22,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      icon: Icon(
        Icons.more_vert_rounded,
        size: 22,
        color: scheme.onSurfaceVariant,
      ),
      onSelected: (v) {
        if (v != 'album') return;
        final id = album?.id;
        if (id == null) return;
        // push 压栈：看完专辑可返回播放页，播放全程不断
        context.push('/album/$id');
      },
      itemBuilder: (_) => [
        // 无专辑信息时置灰（Q4），入口位置保持稳定
        PopupMenuItem(
          value: 'album',
          enabled: album != null,
          child: const Text('查看专辑'),
        ),
      ],
    );
  }
}

/// 图标功能项：48×48 点击热区 + tooltip 语义 + 可选状态点。
class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.showBadge = true,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  /// 非默认状态：图标着主色（可选加状态点）
  final bool active;

  /// 是否在右上角渲染 6dp 状态点
  final bool showBadge;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = active ? scheme.primary : scheme.onSurfaceVariant;
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      iconSize: 22,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      color: color,
      icon: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Icon(icon, size: 22, color: color),
          if (active && showBadge)
            Positioned(
              top: -2,
              right: -4,
              child: Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.primary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 收藏（书架）入口：实心/描边心形即时表达状态，点击弹 Snackbar 确认。
class _FavoriteAction extends StatelessWidget {
  const _FavoriteAction({required this.album});

  final Album? album;

  @override
  Widget build(BuildContext context) {
    // watch：收藏状态实时反映（加入/取消书架）
    final shelf = context.watch<ShelfController>();
    final a = album;
    final inShelf = a != null && shelf.has(a.id);
    return _IconAction(
      icon: inShelf ? Icons.favorite_rounded : Icons.favorite_border_rounded,
      tooltip: inShelf ? '已收藏' : '加入书架',
      active: inShelf,
      showBadge: false, // 实心心形已足够表达状态
      onTap: () async {
        if (a == null) return;
        final wasIn = shelf.has(a.id);
        await shelf.toggle(a.id);
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(wasIn ? '已移出书架：${a.title}' : '已加入书架：${a.title}'),
              // 悬浮避让底部拇指区控制簇，不遮挡进度条/传输控件
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 240),
            ),
          );
      },
    );
  }
}

/// 时长格式化（导出给 MiniPlayer / 详情页复用）
String fmtClock(Duration d) {
  if (d < Duration.zero) return '00:00';
  final total = d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}
