import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../app/widgets/common.dart';
import '../../../core/services/dictionary/dictionary_pack_config.dart';
import '../../../core/services/dictionary/dictionary_service.dart';

class DictionaryPage extends StatefulWidget {
  const DictionaryPage({super.key});

  @override
  State<DictionaryPage> createState() => _DictionaryPageState();
}

class _DictionaryPageState extends State<DictionaryPage> {
  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final dict = context.watch<DictionaryService>();
    final state = dict.state.state;
    final mode = dict.state.mode;

    return Scaffold(
      appBar: AppBar(title: const Text('离线词库')),
      body: ListView(
        padding: EdgeInsets.all(tokens.spaceMd),
        children: [
          KeleCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('词库类型', style: tokens.sectionStyle),
                SizedBox(height: tokens.spaceSm),
                Row(
                  children: [
                    Expanded(
                      child: _ModeTile(
                        mode: DictionaryMode.simple,
                        selected: mode == DictionaryMode.simple,
                        installed: dict.state.isInstalledFor(DictionaryMode.simple),
                        enabled: !dict.downloading,
                        onTap: () => dict.switchMode(DictionaryMode.simple),
                      ),
                    ),
                    SizedBox(width: tokens.spaceSm),
                    Expanded(
                      child: _ModeTile(
                        mode: DictionaryMode.full,
                        selected: mode == DictionaryMode.full,
                        installed: dict.state.isInstalledFor(DictionaryMode.full),
                        enabled: !dict.downloading,
                        onTap: () => dict.switchMode(DictionaryMode.full),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: tokens.spaceMd),
                Text(DictionaryPackConfig.descriptionFor(mode), style: tokens.bodyStyle),
                SizedBox(height: tokens.spaceXs),
                Text(
                  '两种词库分别下载与保存，切换后仍可切回已下载的类型。',
                  style: tokens.captionStyle,
                ),
              ],
            ),
          ),
          SizedBox(height: tokens.spaceLg),
          KeleCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('英汉词典 · ECDICT', style: tokens.sectionStyle),
                SizedBox(height: tokens.spaceSm),
                Text(
                  '当前选择：${DictionaryPackConfig.titleFor(mode)}（'
                  '${DictionaryPackConfig.subtitleFor(mode)}）。'
                  '词库仅用于单词/短语释义；查询完全离线，不会上传选中的阅读内容。',
                  style: tokens.bodyStyle,
                ),
                SizedBox(height: tokens.spaceMd),
                Text('下载说明示例', style: tokens.sectionStyle),
                SizedBox(height: tokens.spaceXs),
                Text(
                  '下载完成后，在阅读页选中英文单词或短语即可查看释义。'
                  '例如选中 “fox”，会显示音标 /fɒks/ 与释义「n. 狐狸」；'
                  '选中整句只给逐词释义，不提供整句翻译。',
                  style: tokens.bodyStyle,
                ),
                SizedBox(height: tokens.spaceMd),
                if (state != null) ...[
                  Text('版本：${state.version}', style: tokens.captionStyle),
                  Text(
                    '大小：${_formatSize(state.size)} · '
                    '安装时间：${_format(state.installedAt)}',
                    style: tokens.captionStyle,
                  ),
                  SizedBox(height: tokens.spaceSm),
                ],
                if (dict.downloading) ...[
                  LinearProgressIndicator(
                    value: dict.total > 0 ? dict.received / dict.total : null,
                  ),
                  SizedBox(height: tokens.spaceXs),
                  Text(
                    dict.total > 0
                        ? '${_formatSize(dict.received)} / ${_formatSize(dict.total)}'
                        : '正在连接词库源…',
                    style: tokens.captionStyle,
                  ),
                ] else if (dict.error != null) ...[
                  Text(
                    dict.error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                  SizedBox(height: tokens.spaceSm),
                ],
                SizedBox(height: tokens.spaceSm),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: dict.downloading ? null : dict.download,
                      icon: const Icon(Icons.download_rounded),
                      label: Text(state == null ? '下载词库' : '重新下载'),
                    ),
                    SizedBox(width: tokens.spaceSm),
                    if (dict.downloading)
                      OutlinedButton(
                        onPressed: dict.cancelDownload,
                        child: const Text('取消'),
                      )
                    else if (state != null)
                      OutlinedButton.icon(
                        onPressed: dict.uninstall,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('卸载'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(height: tokens.spaceLg),
          Text(
            '词库数据：ECDICT（MIT，Copyright © 2017 Linwei）。'
            '下载时仅访问内置发布源，不涉及任何阅读内容。',
            style: tokens.captionStyle,
          ),
        ],
      ),
    );
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  static String _format(DateTime time) =>
      '${time.year}-${time.month.toString().padLeft(2, '0')}-'
      '${time.day.toString().padLeft(2, '0')}';
}

class _ModeTile extends StatelessWidget {
  const _ModeTile({
    required this.mode,
    required this.selected,
    required this.installed,
    required this.enabled,
    required this.onTap,
  });

  final DictionaryMode mode;
  final bool selected;
  final bool installed;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final primary = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(tokens.radiusMd),
      child: Container(
        padding: EdgeInsets.all(tokens.spaceSm),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(tokens.radiusMd),
          border: Border.all(
            color: selected ? primary : tokens.hairlineColor,
            width: selected ? 1.6 : 1,
          ),
          color: selected ? primary.withValues(alpha: 0.08) : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  size: 18,
                  color: selected ? primary : tokens.onHairline,
                ),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    DictionaryPackConfig.titleFor(mode),
                    style: tokens.sectionStyle,
                  ),
                ),
              ],
            ),
            SizedBox(height: tokens.spaceXs),
            Text(DictionaryPackConfig.subtitleFor(mode), style: tokens.captionStyle),
            SizedBox(height: tokens.spaceXs),
            Text(
              installed ? '已下载' : '未下载',
              style: installed
                  ? tokens.captionStyle.copyWith(color: primary)
                  : tokens.captionStyle,
            ),
          ],
        ),
      ),
    );
  }
}
