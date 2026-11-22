import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/app_tokens.dart';
import '../../core/services/dictionary/dictionary_service.dart';

Future<void> showDictionaryLookupSheet(
  BuildContext context, {
  required String text,
  required DictionaryService service,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(sheetContext).size.height * 0.76,
        ),
        child: _LookupBody(text: text, service: service),
      ),
    ),
  );
}

class _LookupBody extends StatefulWidget {
  const _LookupBody({required this.text, required this.service});

  final String text;
  final DictionaryService service;

  @override
  State<_LookupBody> createState() => _LookupBodyState();
}

class _LookupBodyState extends State<_LookupBody> {
  DictionaryLookupResult? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    _lookup();
  }

  Future<void> _lookup() async {
    try {
      final result = await widget.service.lookup(widget.text);
      if (mounted) setState(() => _result = result);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final result = _result;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spaceLg,
        0,
        tokens.spaceLg,
        tokens.spaceLg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('查词', style: tokens.sectionStyle),
          SizedBox(height: tokens.spaceSm),
          Text(
            '「${widget.text}」',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: tokens.bodyStyle,
          ),
          SizedBox(height: tokens.spaceMd),
          Flexible(
            child: _error != null
                ? Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))
                : result == null
                    ? const Center(child: CircularProgressIndicator(strokeWidth: 2.4))
                    : result.found
                        ? ListView.separated(
                            shrinkWrap: true,
                            itemCount: result.entries.length,
                            separatorBuilder: (_, _) => const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final entry = result.entries[index];
                              return ListTile(
                                title: Text(
                                  entry.word,
                                  style: tokens.sectionStyle,
                                ),
                                subtitle: Text(
                                  [
                                    if (entry.phonetic.isNotEmpty) entry.phonetic,
                                    if (entry.pos.isNotEmpty) entry.pos,
                                    entry.translation,
                                  ].join('\n'),
                                  style: tokens.bodyStyle,
                                ),
                                trailing: IconButton(
                                  tooltip: '复制释义',
                                  icon: const Icon(Icons.copy_all_outlined),
                                  onPressed: () => Clipboard.setData(
                                    ClipboardData(
                                      text: '${entry.word}\n${entry.translation}',
                                    ),
                                  ),
                                ),
                              );
                            },
                          )
                        : Text(
                            '词库未收录。当前词库仅支持单词/短语释义，不提供整句翻译。',
                            style: tokens.bodyStyle,
                          ),
          ),
          if (result != null && result.isPhrase && result.found) ...[
            SizedBox(height: tokens.spaceSm),
            Text(
              '词库仅提供逐词释义，不是整句翻译。',
              style: tokens.captionStyle,
            ),
          ],
        ],
      ),
    );
  }
}
