import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../app/widgets/common.dart';
import '../../../core/data/daos.dart';
import '../../../core/domain/records.dart';
import '../../../core/services/offline/offline_cache_service.dart';

/// 离线缓存管理页（M8 / PRD §5.6.3）。
///
/// 结构：头部（总占用 + 开关）→ 按专辑分组的任务列表
/// （状态徽标 / 进度、单集删除、整本删除、暂停 / 继续）→ 全部清理。
class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final cache = context.watch<OfflineCacheService>();
    final tasks = cache.tasks();

    // 按专辑分组，组内按加入顺序
    final byAlbum = <String, List<DownloadTask>>{};
    for (final t in tasks) {
      byAlbum.putIfAbsent(t.albumId, () => []).add(t);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('离线缓存')),
      body: Column(
        children: [
          _buildSummary(context, tokens, scheme, cache, tasks.length),
          Expanded(
            child: tasks.isEmpty
                ? const EmptyState(
                    icon: Icons.download_for_offline_outlined,
                    title: '还没有缓存内容',
                    message: '到专辑详情页点「整本缓存」，断网也能听。',
                  )
                : ListView.builder(
                    padding: EdgeInsets.only(
                      left: tokens.spaceMd,
                      right: tokens.spaceMd,
                      bottom: tokens.spaceLg,
                    ),
                    itemCount: byAlbum.length,
                    itemBuilder: (context, i) {
                      final albumId = byAlbum.keys.elementAt(i);
                      return _AlbumSection(
                        albumId: albumId,
                        tasks: byAlbum[albumId]!,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummary(
    BuildContext context,
    AppTokens tokens,
    ColorScheme scheme,
    OfflineCacheService cache,
    int taskCount,
  ) {
    final mb = cache.totalBytes / 1024 / 1024;
    final sizeText = mb >= 1024
        ? '${(mb / 1024).toStringAsFixed(2)} GB'
        : '${mb.toStringAsFixed(1)} MB';
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spaceMd,
        tokens.spaceSm,
        tokens.spaceMd,
        tokens.spaceSm,
      ),
      child: KeleCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '总占用 $sizeText · $taskCount 项',
                    style: tokens.sectionStyle,
                  ),
                ),
                if (taskCount > 0)
                  TextButton(
                    onPressed: () => _confirmClear(context, cache),
                    child: const Text('全部清理'),
                  ),
              ],
            ),
            Text('存储位置：${cache.store.locationLabel}', style: tokens.captionStyle),
            SizedBox(height: tokens.spaceSm),
            _switchRow(
              context,
              tokens,
              icon: Icons.wifi_rounded,
              label: '仅 Wi-Fi 下载',
              value: true, // Web 预览恒允许；原生端由 SettingsStore 控制
              onChanged: null,
            ),
            _switchRow(
              context,
              tokens,
              icon: Icons.offline_bolt_rounded,
              label: '仅播放已缓存文件',
              value: cache.onlyCached,
              onChanged: (v) => cache.setOnlyCached(v),
            ),
          ],
        ),
      ),
    );
  }

  Widget _switchRow(
    BuildContext context,
    AppTokens tokens, {
    required IconData icon,
    required String label,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 18, color: scheme.primary),
        const SizedBox(width: 8),
        Expanded(child: Text(label, style: tokens.bodyStyle)),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }

  Future<void> _confirmClear(BuildContext context, OfflineCacheService cache) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清理全部缓存？'),
        content: const Text('将删除全部已缓存音频与任务记录，不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              cache.clearAll();
            },
            child: const Text('清理'),
          ),
        ],
      ),
    );
  }
}

/// 一个专辑的任务分组。
class _AlbumSection extends StatelessWidget {
  const _AlbumSection({required this.albumId, required this.tasks});

  final String albumId;
  final List<DownloadTask> tasks;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final cache = context.watch<OfflineCacheService>();
    final daos = context.read<Daos>();
    final album = daos.albums.get(albumId);
    final title = album?.title ?? albumId;

    final done = tasks.where((t) => t.status == DownloadStatus.done).length;
    final bytes = tasks.fold<int>(0, (s, t) => s + t.sizeBytes);
    final mb = bytes / 1024 / 1024;
    final paused = cache.isPaused(albumId);

    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spaceSm),
      child: KeleCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => context.push('/album/$albumId'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tokens.bodyStyle.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '已完成 $done/${tasks.length}'
                          '${bytes > 0 ? ' · ${mb >= 1024 ? '${(mb / 1024).toStringAsFixed(2)} GB' : '${mb.toStringAsFixed(1)} MB'}' : ''}'
                          '${paused && done < tasks.length ? ' · 已暂停' : ''}',
                          style: tokens.captionStyle,
                        ),
                      ],
                    ),
                  ),
                  if (done < tasks.length)
                    IconButton(
                      tooltip: paused ? '继续下载' : '暂停下载',
                      onPressed: () => paused
                          ? cache.resumeAlbum(albumId)
                          : cache.pauseAlbum(albumId),
                      icon: Icon(
                        paused
                            ? Icons.play_arrow_rounded
                            : Icons.pause_rounded,
                      ),
                    ),
                  IconButton(
                    tooltip: '删除整本',
                    onPressed: () => cache.deleteAlbum(albumId),
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: tokens.hairlineColor),
          for (final t in tasks) _ChapterTile(task: t),
        ],
      ),
      ),
    );
  }
}

class _ChapterTile extends StatelessWidget {
  const _ChapterTile({required this.task});

  final DownloadTask task;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final cache = context.read<OfflineCacheService>();
    final chapter = context.read<Daos>().chapters.get(task.chapterId);
    final title = chapter?.title ?? task.chapterId;

    final (label, color) = switch (task.status) {
      DownloadStatus.done => ('完成', scheme.secondary),
      DownloadStatus.running => ('下载中', scheme.primary),
      DownloadStatus.failed => ('失败', scheme.error),
      DownloadStatus.queued => ('排队', tokens.onHairline),
    };
    // 失败时鼠标悬停/长按可看原因
    final failureTip =
        task.status == DownloadStatus.failed && task.error.isNotEmpty
            ? task.error
            : null;
    final sizeText = task.sizeBytes > 0
        ? ' · ${(task.sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB'
        : '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tokens.captionStyle,
            ),
          ),
          Tooltip(
            message: failureTip ?? '',
            triggerMode: TooltipTriggerMode.longPress,
            child: Text(
              '$label$sizeText',
              style: tokens.numStyle.copyWith(color: color),
            ),
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 36,
            height: 36,
            child: IconButton(
              tooltip: '删除',
              padding: EdgeInsets.zero,
              iconSize: 18,
              onPressed: () => cache.deleteChapter(task.chapterId),
              icon: Icon(
                Icons.close_rounded,
                color: tokens.onHairline,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
