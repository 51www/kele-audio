import 'package:flutter/material.dart';

import 'stub_page.dart';

/// 离线缓存管理页（PRD §5.6.3）—— M8 实装。
class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key});

  @override
  Widget build(BuildContext context) => const StageStubPage(
        title: '离线缓存',
        stage: 'M8',
        summary: '整本缓存后，断网也能听；缓存与索引都放在应用私有目录。',
        points: [
          '缓存列表：专辑 / 单集、大小、排队 / 下载中 / 完成 / 失败',
          '暂停、继续、单集删除、整本删除、全部清理',
          '仅 Wi-Fi 下载开关与总占用空间',
          '仅播放已缓存文件，离线可正常收听',
        ],
        note: '数据源：core/data 的 download 表（M1 已建表）；'
            '实现整体移植 abts 的 cache_store。',
      );
}
