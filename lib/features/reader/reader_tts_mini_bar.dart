import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/theme/app_tokens.dart';
import '../../core/services/tts/tts_session.dart';
import 'reader_tts_compact_bar.dart';

/// 本地书朗读的全局常驻播放条。
///
/// 与 B 站听书播放条（`MiniPlayer`）同一落位：底部留白、距屏幕边缘间距一致；
/// 阅读页内用简洁控制条 [ReaderTtsBar]，两者共用 [ReaderTtsCompactBar] 主体，
/// 因此不会出现两套视觉或两条控制条。
///
/// 点条身进入听书播放页；停止（✕）终止朗读。
class TtsMiniPlayerSlot extends StatelessWidget {
  const TtsMiniPlayerSlot({super.key, this.alignToHomeBar = false});

  /// 二级页没有底部导航栏时，预留与首页导航栏等高的空间，保持与首页同一水平线。
  final bool alignToHomeBar;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<TtsSession>();
    if (!session.active) return const SizedBox.shrink();

    final tokens = AppTokens.of(context);
    final bottomGap = alignToHomeBar
        ? (Theme.of(context).navigationBarTheme.height ?? 80.0) +
            MediaQuery.paddingOf(context).bottom
        : 0.0;
    final bookTitle =
        session.bookTitle.isEmpty ? '本地书朗读' : session.bookTitle;
    final bookId = session.bookId;
    final canOpen = bookId != null && bookId.isNotEmpty;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spaceMd,
        tokens.spaceSm,
        tokens.spaceMd,
        tokens.spaceXs + bottomGap,
      ),
      child: ReaderTtsCompactBar(
        title: bookTitle,
        subtitle: session.chapterTitle,
        playing: session.playing,
        onToggle: session.toggle,
        onStop: session.stop,
        onOpen: canOpen ? () => context.push('/listen/$bookId') : null,
      ),
    );
  }
}
