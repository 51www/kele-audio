import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../core/services/tts/tts_engine.dart';
import '../../../core/services/tts/tts_engine_edge.dart';
import '../../../core/services/tts/tts_engine_http.dart';
import '../../../core/services/tts/tts_engine_system.dart';
import '../../../core/services/tts/tts_settings_store.dart';

/// 设置页「本地书 · 听书」分组（M9.4）。
class TtsSettingsSection extends StatefulWidget {
  const TtsSettingsSection({super.key});

  @override
  State<TtsSettingsSection> createState() => _TtsSettingsSectionState();
}

class _TtsSettingsSectionState extends State<TtsSettingsSection> {
  List<TtsVoice> _systemVoices = const [];
  bool _loadingVoices = false;
  bool _busy = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _loadSystemVoices();
  }

  Future<void> _loadSystemVoices() async {
    setState(() => _loadingVoices = true);
    final engine = TtsSystemEngine();
    try {
      final voices = await engine.listVoices();
      if (!mounted) return;
      setState(() => _systemVoices = voices);
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '系统音色读取失败：$e');
    } finally {
      await engine.dispose();
      if (mounted) setState(() => _loadingVoices = false);
    }
  }

  Future<void> _runBusy(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _status = _cleanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _cleanError(Object error) {
    final raw = error.toString();
    if (raw.startsWith('TtsException')) {
      final index = raw.indexOf('):');
      if (index > 0) return raw.substring(index + 3).trim();
    }
    return raw;
  }

  TtsParams _params(TtsSettingsStore settings, {String? voice}) => TtsParams(
    voice: voice ?? settings.activeVoice,
    rate: settings.rate,
    pitch: settings.pitch,
  );

  Future<void> _audition(
    TtsEngine engine,
    TtsSettingsStore settings, {
    String? voice,
  }) async {
    await _runBusy(() async {
      await engine.start(_params(settings, voice: voice));
      await engine.speak('你好，我是可乐听书，正在为你朗读本地书。');
      if (mounted) setState(() => _status = '试听完成');
    });
    await engine.dispose();
  }

  Future<void> _testEdge(TtsSettingsStore settings) async {
    final engine = TtsEdgeEngine();
    await _runBusy(() async {
      try {
        await engine.start(_params(settings, voice: settings.edgeVoice));
        await engine.testConnection();
        if (mounted) setState(() => _status = 'Edge 连通性正常');
      } catch (e) {
        // 自检失败给出兜底路径：切系统朗读或改用自定义 HTTP 模板。
        if (mounted) {
          setState(
            () => _status =
                'Edge 连通性失败：${_cleanError(e)}；可改用系统朗读或配置自定义 HTTP 模板',
          );
        }
      }
    });
    await engine.dispose();
  }

  Future<void> _testHttp(TtsSettingsStore settings) async {
    final engine = TtsHttpEngine(templateProvider: () => settings.httpTemplate);
    await _runBusy(() async {
      await engine.testConnection();
      if (mounted) setState(() => _status = 'HTTP 模板可访问');
    });
    await engine.dispose();
  }

  Future<void> _auditionHttp(TtsSettingsStore settings) async {
    final engine = TtsHttpEngine(templateProvider: () => settings.httpTemplate);
    await _audition(engine, settings);
  }

  Future<void> _editTemplate(
    TtsSettingsStore settings, [
    TtsHttpTemplate? template,
  ]) async {
    final name = TextEditingController(text: template?.name ?? '');
    final url = TextEditingController(text: template?.url ?? '');
    final headers = TextEditingController(
      text: template == null
          ? ''
          : template.headers.entries
              .map((e) => '${e.key}: ${e.value}')
              .join('\n'),
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(template == null ? '新增 HTTP 模板' : '编辑 HTTP 模板'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: '模板名称'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: url,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '音频 URL 模板',
                  hintText: 'https://example.com/tts?text={text}&voice={voice}',
                  helperText: '占位符：{text} / {voice} / {rate}',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: headers,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '请求头（每行 Key: Value，可留空）',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    if (!mounted) return;
    final map = {
      for (final line in headers.text.split('\n'))
        if (line.contains(':'))
          line.substring(0, line.indexOf(':')).trim():
              line.substring(line.indexOf(':') + 1).trim(),
    };
    final next = TtsHttpTemplate(
      id: template?.id ??
          'tpl_${DateTime.now().millisecondsSinceEpoch}',
      name: name.text.trim().isEmpty ? '未命名模板' : name.text.trim(),
      url: url.text.trim(),
      headers: map,
    );
    await settings.upsertTemplate(next);
  }

  Future<void> _deleteTemplate(
    TtsSettingsStore settings,
    TtsHttpTemplate template,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除模板'),
        content: Text('确定删除「${template.name}」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) await settings.removeTemplate(template.id);
  }

  Future<void> _editMimoKey(TtsSettingsStore settings) async {
    final controller = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('MiMo 朗读 API Key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              settings.hasMimoApiKey
                  ? '当前：${settings.maskedMimoKey}（粘贴新 Key 可覆盖）'
                  : '当前未配置 Key',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'API Key',
                hintText: '粘贴 MiMo API Key',
                helperText: '仅保存在本机，不上传；日志中不会回显完整 Key',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    final key = controller.text.trim();
    if (key.isEmpty) {
      if (mounted) setState(() => _status = 'Key 为空，未保存');
      return;
    }
    await settings.setMimoApiKey(key);
    if (mounted) setState(() => _status = 'MiMo Key 已保存');
  }

  Future<void> _clearMimoKey(TtsSettingsStore settings) async {
    await settings.clearMimoApiKey();
    if (mounted) setState(() => _status = '已清除本机 MiMo Key');
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final settings = context.watch<TtsSettingsStore>();
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('朗读引擎', style: tokens.captionStyle),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final kind in TtsEngineKind.values)
              ChoiceChip(
                label: Text(kind.label),
                selected: settings.engine == kind,
                showCheckmark: false,
                onSelected: (_) => settings.setEngine(kind),
              ),
          ],
        ),
        const SizedBox(height: 14),
        if (settings.engine == TtsEngineKind.system) ...[
          _VoiceDropdown(
            label: '系统音色',
            value: settings.systemVoice,
            hint: '跟随系统默认音色',
            voices: _systemVoices,
            loading: _loadingVoices,
            onChanged: settings.setSystemVoice,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: _busy
                    ? null
                    : () => _audition(TtsSystemEngine(), settings),
                icon: const Icon(Icons.volume_up_outlined, size: 18),
                label: const Text('试听'),
              ),
              const SizedBox(width: 10),
              if (_loadingVoices)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ],
        if (settings.engine == TtsEngineKind.edge) ...[
          Text('Edge 中文音色', style: tokens.captionStyle),
          const SizedBox(height: 6),
          for (final voice in edgeZhVoices)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(
                settings.edgeVoice == voice.id
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                color: settings.edgeVoice == voice.id
                    ? scheme.primary
                    : scheme.outline,
              ),
              title: Text(voice.name, style: tokens.bodyStyle),
              subtitle: Text(voice.id, style: tokens.captionStyle),
              onTap: () => settings.setEdgeVoice(voice.id),
              trailing: IconButton(
                tooltip: '试听该音色',
                onPressed: _busy
                    ? null
                    : () => _audition(
                          TtsEdgeEngine(),
                          settings,
                          voice: voice.id,
                        ),
                icon: const Icon(Icons.play_circle_outline_rounded),
              ),
            ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: _busy ? null : () => _testEdge(settings),
                icon: const Icon(Icons.wifi_tethering_rounded, size: 18),
                label: const Text('连通性自检'),
              ),
              FilledButton.tonalIcon(
                onPressed: _busy
                    ? null
                    : () => _audition(TtsEdgeEngine(), settings),
                icon: const Icon(Icons.volume_up_outlined, size: 18),
                label: const Text('试听当前音色'),
              ),
            ],
          ),
        ],
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('MiMo 朗读 API Key', style: tokens.bodyStyle),
          subtitle: Text(
            settings.hasMimoApiKey
                ? '已配置 ${settings.maskedMimoKey}'
                : '未配置，MiMo 朗读不可用',
            style: tokens.captionStyle,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: () => _editMimoKey(settings),
                child: Text(settings.hasMimoApiKey ? '更换' : '粘贴'),
              ),
              if (settings.hasMimoApiKey)
                TextButton(
                  onPressed: () => _clearMimoKey(settings),
                  child: const Text('清除'),
                ),
            ],
          ),
        ),
        Text(
          '音色在听书播放页「朗读引擎」弹窗里选择，切换后从下一片生效。'
          'Key 也可在构建时用 --dart-define=MIMO_API_KEY=... 注入；'
          '接口没有 speed 参数，语速用播放器倍速近似。',
          style: tokens.captionStyle.copyWith(fontSize: 11),
        ),
        if (settings.engine == TtsEngineKind.http) ...[
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: settings.httpTemplate?.id,
                  decoration: const InputDecoration(labelText: '使用模板'),
                  items: [
                    for (final t in settings.templates)
                      DropdownMenuItem(value: t.id, child: Text(t.name)),
                  ],
                  onChanged: (id) => settings.setHttpTemplate(id),
                ),
              ),
              IconButton(
                tooltip: '新增模板',
                onPressed: () => _editTemplate(settings),
                icon: const Icon(Icons.add_circle_outline_rounded),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final t in settings.templates)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t.name, style: tokens.bodyStyle),
              subtitle: Text(
                t.url.isEmpty ? '未填写 URL' : t.url,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tokens.captionStyle,
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '试听',
                    onPressed: _busy ? null : () => _auditionHttp(settings),
                    icon: const Icon(Icons.play_circle_outline_rounded),
                  ),
                  IconButton(
                    tooltip: '编辑',
                    onPressed: () => _editTemplate(settings, t),
                    icon: const Icon(Icons.edit_outlined),
                  ),
                  IconButton(
                    tooltip: '删除',
                    onPressed: () => _deleteTemplate(settings, t),
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: _busy ? null : () => _testHttp(settings),
                icon: const Icon(Icons.wifi_tethering_rounded, size: 18),
                label: const Text('连通性自检'),
              ),
              FilledButton.tonalIcon(
                onPressed: _busy ? null : () => _auditionHttp(settings),
                icon: const Icon(Icons.volume_up_outlined, size: 18),
                label: const Text('试听'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '模板返回音频流（mp3/wav）即可；请求头用于鉴权。',
            style: tokens.captionStyle,
          ),
        ],
        const SizedBox(height: 14),
        Text(
          '语速 ${settings.rate.toStringAsFixed(2)}x · '
          '音调 ${settings.pitch.toStringAsFixed(2)}',
          style: tokens.captionStyle,
        ),
        Slider(
          value: settings.rate,
          min: 0.5,
          max: 3.0,
          divisions: 10,
          label: '${settings.rate.toStringAsFixed(2)}x',
          onChanged: settings.setRate,
        ),
        Slider(
          value: settings.pitch,
          min: 0.5,
          max: 2.0,
          divisions: 6,
          label: settings.pitch.toStringAsFixed(2),
          onChanged: settings.setPitch,
        ),
        Text(
          '0.5~3.0 统一语义：1.00x 为正常语速；Edge 映射为合成语速百分比，'
          'HTTP 以 {rate} 传百分比数值（0 表示原速）。'
          '系统引擎：0.50x≈半速、最高按 1.80x 生效，实际受系统语音引擎影响。',
          style: tokens.captionStyle.copyWith(fontSize: 11),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('进入书籍默认继续听书'),
          subtitle: const Text('关闭后默认静读，点右上角耳机再开始朗读'),
          value: settings.defaultListen,
          onChanged: settings.setDefaultListen,
        ),
        if (_busy) ...[
          const SizedBox(height: 8),
          const LinearProgressIndicator(minHeight: 2),
        ],
        if (_status != null) ...[
          const SizedBox(height: 8),
          Text(
            _status!,
            style: tokens.captionStyle.copyWith(
              color: _status!.contains('失败') || _status!.contains('超时')
                  ? scheme.error
                  : scheme.primary,
            ),
          ),
        ],
      ],
    );
  }
}

class _VoiceDropdown extends StatelessWidget {
  const _VoiceDropdown({
    required this.label,
    required this.value,
    required this.hint,
    required this.voices,
    required this.loading,
    required this.onChanged,
  });

  final String label;
  final String value;
  final String hint;
  final List<TtsVoice> voices;
  final bool loading;
  final Future<void> Function(String) onChanged;

  @override
  Widget build(BuildContext context) {
    final known = voices.any((v) => v.id == value);
    return DropdownButtonFormField<String>(
      initialValue: known ? value : null,
      decoration: InputDecoration(
        labelText: label,
        hintText: loading ? '读取中…' : hint,
      ),
      items: [
        for (final v in voices)
          DropdownMenuItem(
            value: v.id,
            child: Text(
              v.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}
