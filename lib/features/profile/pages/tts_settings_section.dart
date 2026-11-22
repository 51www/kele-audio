import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../core/services/tts/doubao_cookie_pool.dart';
import '../../../core/services/tts/tts_engine.dart';
import '../../../core/services/tts/tts_engine_doubao.dart';
import '../../../core/services/tts/tts_engine_edge.dart';
import '../../../core/services/tts/tts_engine_system.dart';
import '../../../core/services/tts/tts_session.dart';
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
  late final TextEditingController _cookieController;
  final FocusNode _cookieFocus = FocusNode();
  bool _cookieObscured = true;

  @override
  void initState() {
    super.initState();
    _cookieController = TextEditingController(
      text: context.read<TtsSettingsStore>().doubaoCookie,
    );
    context.read<TtsSettingsStore>().addListener(_onSettingsChanged);
    _loadSystemVoices();
  }

  /// 备份还原会在本页直接改写 settings.doubaoCookie；输入框不在编辑中时
  /// 同步过来，避免界面显示旧 Cookie、实际却用新 Cookie 的错位。
  void _onSettingsChanged() {
    if (!mounted || _cookieFocus.hasFocus) return;
    final latest = context.read<TtsSettingsStore>().doubaoCookie;
    if (_cookieController.text != latest) {
      _cookieController.text = latest;
    }
  }

  @override
  void dispose() {
    context.read<TtsSettingsStore>().removeListener(_onSettingsChanged);
    _cookieController.dispose();
    _cookieFocus.dispose();
    super.dispose();
  }

  Future<void> _loadSystemVoices() async {
    setState(() => _loadingVoices = true);
    try {
      // 只读探测，不创建/停止额外的引擎实例，避免打断正在进行的朗读。
      final voices = await TtsSystemEngine.availableVoices();
      if (!mounted) return;
      setState(() => _systemVoices = voices);
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '系统音色读取失败：$e');
    } finally {
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

  /// 设置页改了音色/语速/音调后，若听书会话正在播放，立即把新参数推给它
  /// 并从当前句续读——否则正在朗读的引擎仍用旧参数，表现为「切换不生效」。
  /// 会话未激活时 reloadParams 内部直接返回，无副作用。
  void _reloadActiveSession() {
    context.read<TtsSession>().reloadParams();
  }

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
        // 自检失败给出兜底路径：切系统朗读。
        if (mounted) {
          setState(() => _status = 'Edge 连通性失败：${_cleanError(e)}；可改用系统朗读');
        }
      }
    });
    await engine.dispose();
  }

  TtsDoubaoEngine _doubaoEngine(TtsSettingsStore settings) =>
      TtsDoubaoEngine(cookieProvider: () => settings.doubaoCookie);

  Future<void> _testDoubao(TtsSettingsStore settings) async {
    final cookie = _cookieController.text.trim();
    await settings.setDoubaoCookie(cookie);
    if (cookie.isEmpty) {
      setState(() => _status = '请先粘贴豆包 Cookie 再自检');
      return;
    }
    final engine = _doubaoEngine(settings);
    await _runBusy(() async {
      try {
        await engine.start(_params(settings, voice: settings.doubaoVoice));
        await engine.testConnection();
        if (mounted) setState(() => _status = '豆包连通性正常');
      } catch (e) {
        if (mounted) {
          setState(() => _status = '豆包连通性失败：${_cleanError(e)}；'
              '请确认 Cookie 有效且未过期，或改用 Edge 朗读');
        }
      }
    });
    await engine.dispose();
  }

  Future<void> _auditionDoubao(
    TtsSettingsStore settings, {
    String? voice,
  }) async {
    final cookie = _cookieController.text.trim();
    await settings.setDoubaoCookie(cookie);
    if (cookie.isEmpty) {
      setState(() => _status = '请先粘贴豆包 Cookie 再试听');
      return;
    }
    await _audition(_doubaoEngine(settings), settings, voice: voice);
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
                onSelected: (_) async {
                  await settings.setEngine(kind);
                  _reloadActiveSession();
                },
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
            onChanged: (v) async {
              await settings.setSystemVoice(v);
              _reloadActiveSession();
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed:
                    _busy ? null : () => _audition(TtsSystemEngine(), settings),
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
              onTap: () async {
                await settings.setEdgeVoice(voice.id);
                _reloadActiveSession();
              },
              trailing: IconButton(
                tooltip: '试听该音色',
                onPressed: _busy
                    ? null
                    : () =>
                        _audition(TtsEdgeEngine(), settings, voice: voice.id),
                icon: const Icon(Icons.play_circle_outline_rounded),
              ),
            ),
          const SizedBox(height: 10),
          Text('听书预设', style: tokens.captionStyle),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final preset in edgeVoicePresets)
                Tooltip(
                  message: preset.description,
                  child: ChoiceChip(
                    label: Text(preset.name, style: tokens.captionStyle),
                    selected: preset.matches(
                      voice: settings.edgeVoice,
                      rate: settings.rate,
                      pitch: settings.pitch,
                    ),
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onSelected: (_) => settings.applyVoicePreset(preset),
                  ),
                ),
            ],
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
                onPressed:
                    _busy ? null : () => _audition(TtsEdgeEngine(), settings),
                icon: const Icon(Icons.volume_up_outlined, size: 18),
                label: const Text('试听当前音色'),
              ),
            ],
          ),
        ],
        if (settings.engine == TtsEngineKind.doubao) ...[
          Text('豆包登录 Cookie', style: tokens.captionStyle),
          const SizedBox(height: 6),
          Text(
            '登录豆包网页版后，按 F12 → Network → 刷新页面，'
            '在任意请求的 Request Headers 中复制完整 Cookie 值粘贴到下方。'
            '可每行粘贴一个不同账号的 Cookie，系统会轮流使用、'
            '被拦截的自动冷却跳过，显著降低风控概率（多个小号效果最好）。'
            'Cookie 仅保存在本机，有效期约 30 天，过期请重新获取。',
            style: tokens.captionStyle.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _cookieController,
            focusNode: _cookieFocus,
            obscureText: _cookieObscured,
            // Flutter 断言要求：遮盖时只能单行。显示时可多行，方便粘贴多个 Cookie。
            maxLines: _cookieObscured ? 1 : 6,
            minLines: 1,
            onChanged: (value) {
              settings.setDoubaoCookie(value);
              setState(() {}); // 刷新下方已配置 Cookie 数量
            },
            decoration: InputDecoration(
              labelText: 'Cookie（每行一个，sessionid; sid_guard; uid_tt 等）',
              hintText: '多个 Cookie 请点右侧眼睛展开后逐行粘贴，'
                  '或用 | 分隔在同一行',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: _cookieObscured ? '显示 Cookie' : '隐藏 Cookie',
                icon: Icon(
                  _cookieObscured
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                onPressed: () =>
                    setState(() => _cookieObscured = !_cookieObscured),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '已配置 ${DoubaoTtsCookiePool.parse(settings.doubaoCookie).length} 个 Cookie'
            '${DoubaoTtsCookiePool.parse(settings.doubaoCookie).length > 1 ? '（自动轮换）' : ''}。'
            '朗读采用多句合并以减少请求；豆包为实验性引擎，接口/风控可能变化，'
            '不稳定时请切回 Edge 或系统朗读。',
            style: tokens.captionStyle.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          Text('豆包音色', style: tokens.captionStyle),
          const SizedBox(height: 6),
          for (final voice in doubaoZhVoices)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(
                settings.doubaoVoice == voice.id
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                color: settings.doubaoVoice == voice.id
                    ? scheme.primary
                    : scheme.outline,
              ),
              title: Text(voice.name, style: tokens.bodyStyle),
              subtitle: Text(voice.id, style: tokens.captionStyle),
              onTap: () async {
                await settings.setDoubaoVoice(voice.id);
                _reloadActiveSession();
              },
              trailing: IconButton(
                tooltip: '试听该音色',
                onPressed: _busy
                    ? null
                    : () => _auditionDoubao(settings, voice: voice.id),
                icon: const Icon(Icons.play_circle_outline_rounded),
              ),
            ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: _busy ? null : () => _testDoubao(settings),
                icon: const Icon(Icons.wifi_tethering_rounded, size: 18),
                label: const Text('连通性自检'),
              ),
              FilledButton.tonalIcon(
                onPressed: _busy
                    ? null
                    : () => _auditionDoubao(settings),
                icon: const Icon(Icons.volume_up_outlined, size: 18),
                label: const Text('试听当前音色'),
              ),
            ],
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
          divisions: 25,
          label: '${settings.rate.toStringAsFixed(2)}x',
          onChanged: (value) =>
              settings.setRate(TtsSettingsStore.quantizeParam(value)),
          onChangeEnd: (_) => _reloadActiveSession(),
        ),
        Slider(
          value: settings.pitch,
          min: 0.5,
          max: 2.0,
          divisions: 15,
          label: settings.pitch.toStringAsFixed(2),
          onChanged: (value) =>
              settings.setPitch(TtsSettingsStore.quantizeParam(value)),
          onChangeEnd: (_) => _reloadActiveSession(),
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
            child: Text(v.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}
