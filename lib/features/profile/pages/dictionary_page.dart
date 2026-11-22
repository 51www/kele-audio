import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../app/widgets/common.dart';
import '../../../core/services/dictionary/dictionary_service.dart';

class DictionaryPage extends StatefulWidget {
  const DictionaryPage({super.key});

  @override
  State<DictionaryPage> createState() => _DictionaryPageState();
}

class _DictionaryPageState extends State<DictionaryPage> {
  late final TextEditingController _url;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(
      text: context.read<DictionaryService>().state.customUrl ?? '',
    );
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final dict = context.watch<DictionaryService>();
    final state = dict.state.state;

    return Scaffold(
      appBar: AppBar(title: const Text('离线词库')),
      body: ListView(
        padding: EdgeInsets.all(tokens.spaceMd),
        children: [
          KeleCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('英汉词典 · ECDICT 精简版', style: tokens.sectionStyle),
                SizedBox(height: tokens.spaceSm),
                Text(
                  '默认从国内 CDN 下载精简词库（约 3.9MB，含约 2.7 万词条与词形），'
                  '也可填写自己的下载地址。词库仅用于单词/短语释义；查询完全离线，'
                  '不会上传选中的阅读内容。',
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
          KeleCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('自定义下载地址（可选）', style: tokens.sectionStyle),
                SizedBox(height: tokens.spaceSm),
                Text(
                  '可填词库 JSON、ECDICT CSV 或词库 zip 包直链；'
                  '留空则依次尝试内置 CDN 源。',
                  style: tokens.captionStyle,
                ),
                SizedBox(height: tokens.spaceSm),
                TextField(
                  controller: _url,
                  decoration: const InputDecoration(
                    hintText: 'https://…',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.url,
                ),
                SizedBox(height: tokens.spaceSm),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: () async {
                      await dict.state.setCustomUrl(_url.text);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context)
                        ..hideCurrentSnackBar()
                        ..showSnackBar(
                          const SnackBar(content: Text('下载地址已保存')),
                        );
                    },
                    child: const Text('保存'),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: tokens.spaceLg),
          Text(
            '词库数据：ECDICT（MIT，Copyright © 2017 Linwei）。'
            '下载时仅访问所选发布源，不涉及任何阅读内容。',
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
