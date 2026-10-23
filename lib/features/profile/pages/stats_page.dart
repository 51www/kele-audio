import 'package:flutter/material.dart';

import 'stub_page.dart';

/// 听书统计页（PRD §5.6.1）—— M8 实装。
class StatsPage extends StatelessWidget {
  const StatsPage({super.key});

  @override
  Widget build(BuildContext context) => const StageStubPage(
        title: '听书统计',
        stage: 'M8',
        summary: '本地播放日志聚合出的收听账本，不上传任何服务器。',
        points: [
          '今日 / 本周 / 本月收听时长',
          '累计收听时长、累计听完专辑数',
          '最常听的分类 Top3 与专辑 Top5',
        ],
        note: '数据源：core/data 的 play_log 表（M1 已建表、DAO 已埋口）。',
      );
}
