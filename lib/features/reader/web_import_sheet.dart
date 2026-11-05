import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';
import '../../core/services/reader/reader_import_service.dart';

/// 粘贴链接导入网页文章。
///
/// 失败态区分「链接格式 / 网络失败 / 需要登录受限 / 非文章页 / 内容类型不支持」，
/// 成功后把书籍与完整性提示返回给书架。
Future<WebImportOutcome?> showWebImportSheet(
  BuildContext context, {
  required ReaderImportService service,
}) {
  return showModalBottomSheet<WebImportOutcome>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _WebImportSheet(service: service),
  );
}

class _WebImportSheet extends StatefulWidget {
  const _WebImportSheet({required this.service});

  final ReaderImportService service;

  @override
  State<_WebImportSheet> createState() => _WebImportSheetState();
}

class _WebImportSheetState extends State<_WebImportSheet> {
  final TextEditingController _url = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final outcome = await widget.service.importWebUrl(_url.text);
      if (!mounted) return;
      Navigator.of(context).pop(outcome);
    } on ReaderImportException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spaceMd,
        tokens.spaceSm,
        tokens.spaceMd,
        tokens.spaceMd + bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('导入网页文章', style: tokens.titleStyle),
          const SizedBox(height: 6),
          Text(
            '粘贴任意网页文章链接（新闻、博客、技术文章等），自动提取正文并生成离线快照。',
            style: tokens.captionStyle,
          ),
          SizedBox(height: tokens.spaceMd),
          TextField(
            controller: _url,
            enabled: !_busy,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
              labelText: '文章链接',
              hintText: 'https://example.com/article/…',
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.error_outline_rounded,
                  size: 16,
                  color: scheme.error,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _error!,
                    style: tokens.captionStyle.copyWith(color: scheme.error),
                  ),
                ),
              ],
            ),
          ],
          SizedBox(height: tokens.spaceMd),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonal(
              onPressed: _busy ? null : _submit,
              child: Text(_busy ? '抓取中…（网络失败会自动重试一次）' : '抓取并加入书架'),
            ),
          ),
        ],
      ),
    );
  }
}
