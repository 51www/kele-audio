import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/theme/app_tokens.dart';
import '../../app/widgets/local_cover_image.dart';
import '../../core/services/reader/book_store.dart';
import '../../core/services/reader/reader_bridge.dart';
import '../../core/services/tts/mimo_tts_client.dart';
import '../../core/services/tts/tts_engine.dart';
import '../../core/services/tts/tts_session.dart';
import '../profile/pages/settings_page.dart';
import 'reader_toc_sheet.dart';

/// 本地书听书播放页（M9.6 精简形态）。
///
/// 入口不变：播放条 `TtsMiniPlayerSlot` / 阅读页 `ReaderTtsBar` 点条身 → `/listen/:id`。
/// 状态一律取自同一个 [TtsSession]（与播放条、阅读页同源），本页不持有播放状态。
///
/// 主体只留封面 / 书名 / 章节 / 段进度 / 主播放键 / 「回到阅读」；
/// 语速、引擎、睡眠定时、章节目录收进底部一排图标，点开才是紧凑弹窗。
class ReaderTtsPage extends StatefulWidget {
  const ReaderTtsPage({super.key, required this.bookId});

  final String bookId;

  @override
  State<ReaderTtsPage> createState() => _ReaderTtsPageState();
}

class _ReaderTtsPageState extends State<ReaderTtsPage> {
  late final TtsSession _tts;
  ModalRoute<dynamic>? _route;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _tts = context.read<TtsSession>();
    _tts.addListener(_onSessionChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route ??= ModalRoute.of(context);
  }

  @override
  void dispose() {
    _tts.removeListener(_onSessionChanged);
    super.dispose();
  }

  /// 朗读结束/切书（含通知栏停止、B 站抢占）时自动退出本页。
  void _onSessionChanged() {
    if (!mounted || _leaving) return;
    if (_tts.active && _tts.bookId == widget.bookId) return;
    _leaving = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final navigator = Navigator.of(context);
      final route = _route;
      // 若配置弹窗还开着，先关弹窗再退出本页（maybePop 只会弹最上层）。
      if (route != null) {
        navigator.popUntil((current) => current == route);
      } else {
        navigator.maybePop();
      }
    });
  }

  String _labelFor(int index) {
    final labels = _tts.chapterLabels;
    if (index >= 0 && index < labels.length && labels[index].isNotEmpty) {
      return labels[index];
    }
    return '第${index + 1}章';
  }

  /// 回到阅读页：会话仍挂着阅读页时直接返回，否则换入阅读页（深度定位沿用
  /// 阅读页既有的 listening 分支，读 `chapterIndex / paragraphIndex` 断点）。
  void _backToReader() {
    if (!mounted) return;
    if (_tts.readerBound && context.canPop()) {
      context.pop();
      return;
    }
    context.pushReplacement('/reader/${widget.bookId}');
  }

  void _showReaderHint([String? message]) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message ?? '已切到「${_tts.chapterTitle}」，回到阅读页后继续朗读'),
          duration: const Duration(seconds: 4),
          action: SnackBarAction(label: '去阅读', onPressed: _backToReader),
        ),
      );
  }

  void _openToc() {
    final count = _chapterCount;
    if (count <= 0) return;
    showReaderTocSheet(
      context,
      items: [
        for (var i = 0; i < count; i++)
          ReaderTocItem(index: i, label: _labelFor(i), href: ''),
      ],
      currentIndex: _tts.chapterIndex,
      onSelect: (item) async {
        final before = _tts.chapterIndex;
        await _tts.jumpChapter(item.index);
        if (!mounted || _tts.chapterIndex == before) return;
        if (!_tts.readerBound) _showReaderHint();
      },
    );
  }

  Future<void> _setRate(double rate) async {
    await _tts.settings.setRate(rate);
    await _tts.reloadParams();
  }

  Future<void> _switchEngine(TtsEngineKind kind) async {
    if (kind == _tts.engineKind) return;
    try {
      await _tts.switchEngine(kind);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('切换朗读引擎失败：$e')));
    }
  }

  String _sleepLabel() {
    if (_tts.stopAfterChapter) return '本章读完停止';
    final left = _tts.sleepRemaining;
    if (left == Duration.zero) return '未开启';
    final minutes = left.inMinutes;
    final seconds = left.inSeconds % 60;
    return '剩余 $minutes:${seconds.toString().padLeft(2, '0')}';
  }

  /// 底部图标行用的一行小字：优先展示当前值，过长就退回名称。
  String _sleepToolLabel() {
    if (_tts.stopAfterChapter) return '本章后';
    final left = _tts.sleepRemaining;
    if (left == Duration.zero) return '睡眠';
    return '${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  int get _chapterCount {
    final book = context.read<ReaderBookStore>().byId(widget.bookId);
    if (book != null && book.chapterCount > 0) return book.chapterCount;
    return _tts.chapterLabels.length;
  }

  /// 紧凑底部弹窗：顶部圆角 + 拖拽条，高度按内容自适应。
  Future<T?> _showCompactSheet<T>({
    required String title,
    String? hint,
    required Widget Function(BuildContext sheetContext, AppTokens tokens)
    builder,
    bool scrollable = false,
  }) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    return showModalBottomSheet<T>(
      context: context,
      showDragHandle: true,
      isScrollControlled: scrollable,
      backgroundColor: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(tokens.radiusMd),
        ),
      ),
      builder: (sheetContext) {
        final sheetTokens = AppTokens.of(sheetContext);
        final content = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: sheetTokens.sectionStyle),
            if (hint != null) ...[
              const SizedBox(height: 2),
              Text(
                hint,
                style: sheetTokens.captionStyle.copyWith(
                  color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            SizedBox(height: sheetTokens.spaceSm),
            builder(sheetContext, tokens),
          ],
        );
        return SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              sheetTokens.spaceMd,
              0,
              sheetTokens.spaceMd,
              sheetTokens.spaceMd,
            ),
            // 音色列表等较长内容可滚动，避免在小屏上被底部弹窗高度裁掉。
            child: scrollable ? SingleChildScrollView(child: content) : content,
          ),
        );
      },
    );
  }

  Future<void> _openRateSheet() async {
    final current = _tts.settings.rate;
    final rate = await _showCompactSheet<double>(
      title: '语速',
      hint: '拖动后松开立即生效',
      builder: (sheetContext, tokens) {
        var draft = current;
        return StatefulBuilder(
          builder: (context, setSheetState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_rateLabel(draft), style: tokens.titleStyle),
              Row(
                children: [
                  Text(
                    '0.5x',
                    style: tokens.captionStyle.copyWith(
                      color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: draft.clamp(0.5, 2.0).toDouble(),
                      min: 0.5,
                      max: 2.0,
                      divisions: 30,
                      label: _rateLabel(draft),
                      onChanged: (value) =>
                          setSheetState(() => draft = value),
                      onChangeEnd: (value) =>
                          Navigator.of(sheetContext).pop(value),
                    ),
                  ),
                  Text(
                    '2.0x',
                    style: tokens.captionStyle.copyWith(
                      color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
    if (rate == null || !mounted) return;
    await _setRate(rate);
  }

  /// 音色清单优先用接口 400 探测结果（缓存到本地）；失败保持内置 9 个兜底。
  Future<void> _probeMimoVoices() async {
    final settings = _tts.settings;
    if (!settings.hasMimoApiKey) return;
    try {
      final voices = await MimoTtsClient().probeVoices(
        apiKey: settings.mimoApiKey,
      );
      await settings.setMimoVoices(voices);
      debugPrint('[tts:mimo] 音色探测成功：${voices.length} 个已缓存');
    } catch (e) {
      debugPrint('[tts:mimo] 音色探测失败，沿用内置清单：$e');
    }
  }

  Future<void> _openEngineSheet() async {
    final settings = _tts.settings;
    if (_tts.engineKind == TtsEngineKind.mimo &&
        settings.hasMimoApiKey &&
        !settings.hasCachedMimoVoices) {
      unawaited(_probeMimoVoices());
    }
    var openSettingsRequested = false;
    final kind = await _showCompactSheet<TtsEngineKind>(
      title: '朗读引擎',
      scrollable: true,
      builder: (sheetContext, tokens) {
        var expanded = _tts.engineKind == TtsEngineKind.mimo;
        var probing = false;
        String? notice;
        String? missingKey;

        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final scheme = Theme.of(ctx).colorScheme;
            Widget item(
              TtsEngineKind value,
              IconData icon,
              String desc, {
              VoidCallback? onTap,
            }) {
              final selected = _tts.engineKind == value;
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  icon,
                  size: 22,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
                title: Text(
                  value.label,
                  style: tokens.bodyStyle.copyWith(
                    color: selected ? scheme.primary : null,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                subtitle: Text(
                  desc,
                  style: tokens.captionStyle.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                trailing: selected
                    ? Icon(Icons.check_rounded, size: 18, color: scheme.primary)
                    : null,
                onTap: onTap ?? () => Navigator.of(sheetContext).pop(value),
              );
            }

            void startMimo() {
              if (!settings.hasMimoApiKey) {
                // 缺 Key 不静默切换，给出明确提示与设置入口。
                setSheetState(() {
                  expanded = true;
                  missingKey = '未配置 MiMo API Key，请先到设置页填写';
                  notice = null;
                });
                return;
              }
              setSheetState(() {
                expanded = true;
                missingKey = null;
                notice = null;
              });
              unawaited(
                _switchEngine(TtsEngineKind.mimo).whenComplete(() {
                  if (sheetContext.mounted) setSheetState(() {});
                }),
              );
              if (!settings.hasCachedMimoVoices && !probing) {
                setSheetState(() => probing = true);
                unawaited(
                  _probeMimoVoices().whenComplete(() {
                    if (sheetContext.mounted) {
                      setSheetState(() => probing = false);
                    }
                  }),
                );
              }
            }

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 当前引擎随选中态刷新（放外层 hint 会在切换后仍显示旧引擎）。
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '当前 ${_tts.engineKind.label}',
                    style: tokens.captionStyle.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                SizedBox(height: tokens.spaceXs),
                item(
                  TtsEngineKind.system,
                  Icons.phone_android_rounded,
                  '离线可用，音色随系统',
                ),
                item(TtsEngineKind.edge, Icons.cloud_outlined, '在线合成，音色更自然'),
                item(
                  TtsEngineKind.mimo,
                  Icons.auto_awesome_rounded,
                  '小米 MiMo，9 种中文音色',
                  onTap: startMimo,
                ),
                if (expanded) ...[
                  if (missingKey != null) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            missingKey!,
                            style: tokens.captionStyle.copyWith(
                              color: scheme.error,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            // 先关闭弹窗，等它真正出栈后再跳设置，
                            // 避免弹窗收起动画期间 push 被路由栈吞掉。
                            openSettingsRequested = true;
                            Navigator.of(sheetContext).pop();
                          },
                          child: const Text('去设置'),
                        ),
                      ],
                    ),
                  ],
                  SizedBox(height: tokens.spaceXs),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '音色（切换后从下一片生效）',
                      style: tokens.captionStyle.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final voice in settings.mimoVoiceOptions)
                        ChoiceChip(
                          label: Text(voice.name),
                          selected: settings.mimoVoice == voice.id,
                          showCheckmark: false,
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          labelStyle: tokens.captionStyle,
                          labelPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                          ),
                          onSelected: (_) async {
                            await settings.setMimoVoice(voice.id);
                            if (!sheetContext.mounted) return;
                            setSheetState(() {
                              notice = '已切换到「${voice.name}」，从下一片朗读生效';
                            });
                          },
                        ),
                    ],
                  ),
                  if (probing) ...[
                    const SizedBox(height: 6),
                    const LinearProgressIndicator(minHeight: 2),
                  ],
                  if (notice != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      notice!,
                      style: tokens.captionStyle.copyWith(color: scheme.primary),
                    ),
                  ],
                ],
              ],
            );
          },
        );
      },
    );
    if (!mounted) return;
    if (openSettingsRequested) {
      // 用独立 MaterialPageRoute 打开设置：从 /listen 直接 push 设置分支
      // 会让 StatefulShellRoute 误切分支并退回阅读页，这里绕开分支切换。
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
      );
      return;
    }
    if (kind == null) return;
    await _switchEngine(kind);
  }

  Future<void> _openSleepSheet() async {
    // 有定时在跑时回显当前剩余（向上取到 5 分钟档），没有则停在「关闭」。
    final left = _tts.sleepRemaining;
    final initial = left == Duration.zero
        ? 0
        : math.min(90, math.max(5, ((left.inMinutes + 4) ~/ 5) * 5));
    final minutes = await _showCompactSheet<int>(
      title: '睡眠定时',
      hint: '当前：${_sleepLabel()}',
      builder: (sheetContext, tokens) {
        var draft = initial;
        String label(int value) => value == 0 ? '关闭' : '$value 分钟后停止';
        return StatefulBuilder(
          builder: (context, setSheetState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label(draft), style: tokens.titleStyle),
              Row(
                children: [
                  Text(
                    '关闭',
                    style: tokens.captionStyle.copyWith(
                      color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: draft.toDouble(),
                      min: 0,
                      max: 90,
                      divisions: 18,
                      label: label(draft),
                      onChanged: (value) =>
                          setSheetState(() => draft = value.toInt()),
                      onChangeEnd: (value) =>
                          Navigator.of(sheetContext).pop(value.toInt()),
                    ),
                  ),
                  Text(
                    '90 分钟',
                    style: tokens.captionStyle.copyWith(
                      color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
    if (minutes == null || !mounted) return;
    await _tts.setSleepTimer(minutes: minutes == 0 ? null : minutes);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(minutes == 0 ? '已关闭睡眠定时' : '$minutes 分钟后停止播放'),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final session = context.watch<TtsSession>();
    // 阅读页更新元数据（章节数）时随之刷新。
    final book = context.watch<ReaderBookStore>().byId(widget.bookId);

    if (!session.active || session.bookId != widget.bookId) {
      return Scaffold(
        backgroundColor: scheme.surface,
        body: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('朗读已结束', style: tokens.bodyStyle),
                SizedBox(height: tokens.spaceXs),
                TextButton(
                  onPressed: () =>
                      context.pushReplacement('/reader/${widget.bookId}'),
                  child: Text(
                    '回到阅读',
                    style: tokens.captionStyle.copyWith(color: scheme.primary),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final count = session.paragraphCount;
    final index = session.paragraphIndex;
    final progress = count > 0 ? ((index + 1) / count).clamp(0.0, 1.0) : 0.0;
    final bookTitle = session.bookTitle.isEmpty
        ? (book?.title ?? '本地书朗读')
        : session.bookTitle;

    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            tokens.spaceLg,
            0,
            tokens.spaceLg,
            tokens.spaceMd,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  tooltip: '返回',
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: Icon(
                    Icons.arrow_back_ios_new_rounded,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // 小屏收一点封面，保证整页一屏内可见、不出现滚动。
                    final coverSize = math.min(
                      176.0,
                      constraints.maxHeight * 0.3,
                    );
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // 上半区：封面 / 书名 / 章节；组内紧凑。
                        const Spacer(flex: 2),
                        Center(
                          child: _BookCoverPlaceholder(
                            title: bookTitle,
                            size: coverSize,
                            tokens: tokens,
                            coverPath: book?.coverPath,
                          ),
                        ),
                        SizedBox(height: tokens.spaceLg),
                        Text(
                          bookTitle,
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: tokens.titleStyle,
                        ),
                        SizedBox(height: tokens.spaceSm),
                        Text(
                          session.chapterTitle,
                          maxLines: 1,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: tokens.bodyStyle.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        // 组间留白：上半区与控制区之间拉开最大间距。
                        const Spacer(flex: 3),
                        _buildToolbar(session),
                        SizedBox(height: tokens.spaceMd),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(
                            tokens.radiusPill,
                          ),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 4,
                            backgroundColor: scheme.primary.withValues(
                              alpha: 0.12,
                            ),
                          ),
                        ),
                        SizedBox(height: tokens.spaceSm),
                        Text(
                          count > 0 ? '第 ${index + 1} / $count 段' : '正文待载入',
                          textAlign: TextAlign.center,
                          style: tokens.captionStyle.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        if (count == 0 && !session.readerBound)
                          Padding(
                            padding: EdgeInsets.only(top: tokens.spaceXs),
                            child: Text(
                              '本章正文需回到阅读页载入后继续',
                              textAlign: TextAlign.center,
                              style: tokens.captionStyle.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        if (session.error != null)
                          Padding(
                            padding: EdgeInsets.only(top: tokens.spaceXs),
                            child: Text(
                              '朗读中断：${session.error}',
                              maxLines: 2,
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.ellipsis,
                              style: tokens.captionStyle.copyWith(
                                color: scheme.error,
                              ),
                            ),
                          ),
                        SizedBox(height: tokens.spaceLg),
                        _buildTransportRow(session),
                        // 底部留白，主播放键不贴屏幕边缘。
                        const Spacer(flex: 2),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 进度条上方的一排小图标：语速 / 引擎 / 睡眠定时，三等分等间距。
  Widget _buildToolbar(TtsSession session) {
    return Row(
      children: [
        Expanded(
          child: _ToolButton(
            icon: Icons.speed_rounded,
            label: _rateLabel(session.settings.rate),
            tooltip: '语速',
            onTap: _openRateSheet,
          ),
        ),
        Expanded(
          child: _ToolButton(
            icon: Icons.graphic_eq_rounded,
            label: session.engineKind.label,
            tooltip: '朗读引擎',
            onTap: _openEngineSheet,
          ),
        ),
        Expanded(
          child: _ToolButton(
            icon: Icons.bedtime_outlined,
            label: _sleepToolLabel(),
            tooltip: '睡眠定时',
            active: session.hasSleepTimer,
            onTap: _openSleepSheet,
          ),
        ),
      ],
    );
  }

  /// 主控制行：左「回到阅读」、中播放/暂停、右「章节跳转」，
  /// 三者同一水平线居中，播放键视觉最重。
  Widget _buildTransportRow(TtsSession session) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _ToolButton(
          icon: Icons.menu_book_rounded,
          label: '阅读',
          tooltip: '回到阅读',
          onTap: _backToReader,
        ),
        const SizedBox(width: 48),
        _PlayPauseButton(
          playing: session.playing,
          onTap: () {
            if (!session.readerBound &&
                !session.playing &&
                session.paragraphCount == 0) {
              // 没有阅读页就抽不出新章正文，直接引导回阅读页续读。
              _showReaderHint('本章正文需回到阅读页载入后继续');
              return;
            }
            session.toggle();
          },
        ),
        const SizedBox(width: 48),
        _ToolButton(
          icon: Icons.format_list_bulleted_rounded,
          label: '章节',
          tooltip: '章节目录',
          onTap: _openToc,
        ),
      ],
    );
  }

  static String _rateLabel(double rate) => '${rate.toStringAsFixed(1)}x';
}

/// 本地书封面：有真实封面（`books/{id}/cover.jpg`）就铺满方形展示，
/// 没有（TXT/PDF/网页/解析失败）则回退主题渐变 + 书名首字。
class _BookCoverPlaceholder extends StatelessWidget {
  const _BookCoverPlaceholder({
    required this.title,
    required this.size,
    required this.tokens,
    this.coverPath,
  });

  final String title;
  final double size;
  final AppTokens tokens;
  final String? coverPath;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(tokens.radiusMd);
    final placeholder = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: tokens.accentGradient,
        borderRadius: radius,
      ),
      child: Text(
        title.trim().isEmpty ? '书' : title.trim().characters.first,
        style: TextStyle(
          color: tokens.onAccent,
          fontSize: 56,
          fontWeight: FontWeight.w800,
        ),
      ),
    );

    final path = coverPath;
    if (path == null || path.isEmpty) return placeholder;
    return SizedBox(
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: radius,
        child: localCoverImage(path: path, placeholder: placeholder),
      ),
    );
  }
}

/// 底部一排小图标：无卡片底、无描边阴影，点开紧凑弹窗。
class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final color = active ? scheme.primary : scheme.onSurfaceVariant;
    return InkResponse(
      onTap: onTap,
      radius: 30,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 24, color: color),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tokens.captionStyle.copyWith(color: color, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({required this.playing, required this.onTap});

  final bool playing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: playing ? '暂停朗读' : '继续朗读',
      child: Material(
        color: scheme.primary,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 64,
            height: 64,
            child: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: scheme.onPrimary,
              size: 34,
            ),
          ),
        ),
      ),
    );
  }
}
