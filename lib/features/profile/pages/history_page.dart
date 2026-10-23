import 'package:flutter/material.dart';

import 'stub_page.dart';

/// 历史收听页（PRD §5.6.2）—— M5 实装。
class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) => const StageStubPage(
        title: '历史收听',
        stage: 'M5',
        summary: '按今天 / 昨天 / 日期分组的收听记录，点任意一条接着听。',
        points: [
          '分组列表：封面、标题、最后章节与进度、时间',
          '单条删除、清空全部历史',
          '点击续播（复用 M2 播放核心）',
          '分页加载，MiniPlayer 常驻不丢',
        ],
        note: '数据源：core/data 的 play_history 表（M1 已建表）。',
      );
}
