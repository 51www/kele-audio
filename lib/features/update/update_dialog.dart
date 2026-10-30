import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';
import 'update_models.dart';
import 'update_platform.dart';
import 'update_service.dart';

/// 更新弹窗：三阶段（说明 → 下载 → 完成），永不强制，任何阶段可退出（提示词 2「交互」）。
class UpdateDialog extends StatefulWidget {
  const UpdateDialog({super.key, required this.service});
  final UpdateService service;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _needsPermissionHint = false;

  UpdateService get _s => widget.service;

  Future<void> _onInstall() async {
    final InstallResult r = await _s.install();
    if (!mounted) return;
    if (r == InstallResult.installing) {
      Navigator.of(context).pop();
    } else {
      // 已拉起系统设置授权页，提示用户返回后再次点击。
      setState(() => _needsPermissionHint = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppTokens tokens = AppTokens.of(context);

    return AnimatedBuilder(
      animation: _s,
      builder: (BuildContext context, _) {
        final bool downloading = _s.downloading;
        final bool done = _s.downloadedPath != null;

        final String title;
        if (downloading) {
          title = '正在下载更新';
        } else if (done) {
          title = '下载完成';
        } else {
          title = '发现新版本 v${_s.release?.tagName ?? ''}';
        }

        return AlertDialog(
          title: Text(title, style: tokens.titleStyle),
          content: SizedBox(
            width: double.maxFinite,
            child: _content(theme, tokens, downloading, done),
          ),
          actions: _actions(context, downloading, done),
        );
      },
    );
  }

  Widget _content(
    ThemeData theme,
    AppTokens tokens,
    bool downloading,
    bool done,
  ) {
    if (downloading) {
      final double ratio = _s.total > 0 ? _s.received / _s.total : 0;
      final String pct = _s.total > 0 ? '${(ratio * 100).toStringAsFixed(0)}%' : '';
      final String source = _hostOf(_s.currentSource);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          LinearProgressIndicator(value: _s.total > 0 ? ratio : null),
          const SizedBox(height: 10),
          Text(
            _s.total > 0
                ? '$pct  ${UpdateService.formatSize(_s.received)} / ${UpdateService.formatSize(_s.total)}'
                : UpdateService.formatSize(_s.received),
            style: tokens.captionStyle,
          ),
          if (source.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text('当前下载源：$source', style: tokens.captionStyle),
          ],
        ],
      );
    }

    if (done) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('已下载到本地，点击「立即安装」完成覆盖升级。',
              style: tokens.bodyStyle),
          if (_needsPermissionHint) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              '请先在系统设置中允许「安装未知应用」，返回后再次点击立即安装。',
              style: tokens.captionStyle.copyWith(color: theme.colorScheme.primary),
            ),
          ],
          if (_s.installError != null) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              _s.installError!,
              style: tokens.captionStyle.copyWith(color: theme.colorScheme.error),
            ),
          ],
        ],
      );
    }

    // 说明阶段
    final GhRelease? rel = _s.release;
    final GhAsset? asset = _s.selectedAsset;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (rel?.body != null && rel!.body!.isNotEmpty) ...<Widget>[
            Text(rel.body!, style: tokens.bodyStyle.copyWith(height: 1.6)),
            const SizedBox(height: 12),
          ],
          if (asset != null)
            Text(
              '产物：${asset.name}'
              '${asset.size > 0 ? '（${UpdateService.formatSize(asset.size)}）' : ''}',
              style: tokens.captionStyle,
            ),
        ],
      ),
    );
  }

  List<Widget> _actions(
    BuildContext context,
    bool downloading,
    bool done,
  ) {
    if (downloading) {
      return <Widget>[
        TextButton(
          onPressed: _s.cancelDownload,
          child: const Text('取消'),
        ),
      ];
    }
    if (done) {
      return <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        ElevatedButton(
          onPressed: _onInstall,
          child: const Text('立即安装'),
        ),
      ];
    }
    return <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('稍后'),
      ),
      ElevatedButton(
        onPressed: _s.startDownload,
        child: const Text('立即更新'),
      ),
    ];
  }

  String _hostOf(String? url) {
    if (url == null || url.isEmpty) return '';
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return url;
    }
  }
}
