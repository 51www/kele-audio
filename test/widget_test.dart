import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kele_audio/app/app.dart';
import 'package:kele_audio/app/theme/app_palette.dart';
import 'package:kele_audio/app/dev_flags.dart';
import 'package:kele_audio/app/di.dart';
import 'package:kele_audio/features/player/mini_player.dart';

/// M1 准出冒烟测试：三 Tab 状态保留、主题切换、路由、二级页返回。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 每个 Tab 的页面都是 ListView：内容在视口外时先上滑让它进构建窗口，
  /// 找到后再 ensureVisible 把它滚进可视区（否则 tap 会打空）。
  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    for (var i = 0; i < 8 && !tester.any(target); i++) {
      await tester.drag(find.byType(ListView).first, const Offset(0, -420));
      await tester.pump(const Duration(milliseconds: 120));
    }
    await tester.pumpAndSettle();
    if (tester.any(target)) {
      await tester.ensureVisible(target.first);
      await tester.pumpAndSettle();
    }
  }

  /// 发现页网络请求被 450ms 节流 / 风控退避的定时器卡着，
  /// `pumpAndSettle` 会在「无帧可画」时提前退出 —— 这里手动推进假时钟。
  Future<void> pumpThroughLoad(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }
    await tester.pumpAndSettle();
  }

  testWidgets('M1 准出冒烟：三 Tab 壳 + 主题切换 + 二级页返回', (tester) async {
    SharedPreferences.setMockInitialValues({});
    DevFlags.showPanels = true; // App 内默认隐藏开发调试面板，测试里打开保冒烟链路

    final services = await AppServices.bootstrap(isWeb: false);
    addTearDown(services.player.dispose); // M2：测试结束释放 watchdog Timer/观察者
    await tester.pumpWidget(KeleApp(services: services));
    await tester.pumpAndSettle();
    await pumpThroughLoad(tester);

    // ── Tab 1 发现：分类 chips + 加载态/错误态（flutter_test 无网络） ──
    expect(find.text('可乐听书'), findsOneWidget);
    expect(find.text('按类型找内容'), findsOneWidget);
    expect(find.byType(MiniPlayer), findsNothing); // 无播放内容 → 不显示播放条

    // M3：分类 chips 来自内容配置（assets/api/content_config.json）
    for (final label in ['推荐', '有声书', '相声曲艺', '讲书', '音乐']) {
      expect(find.text(label), findsOneWidget);
    }

    // flutter_test 环境 HTTP 被挡 → 发现页应展示错误态 + 重试（不白屏）
    expect(find.text('加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    // 分类切换：另一个 feed 独立加载（IndexedStack 保留访问过的分类）
    await tester.tap(find.text('相声曲艺'));
    await pumpThroughLoad(tester);
    expect(find.text('加载失败'), findsOneWidget); // 当前可见的分类
    // 访问过的两个分类都保活（含隐藏的推荐 feed）
    expect(find.text('加载失败', skipOffstage: false).evaluate().length, 2);

    // ── Tab 2 书架：空态 + 建表/DAO 读写 Demo ───────────────────────
    await tester.tap(find.text('书架'));
    await tester.pumpAndSettle();
    expect(find.text('书架还是空的'), findsOneWidget);

    await scrollTo(tester, find.text('本地数据层 · core/data'));
    expect(find.text('本地数据层 · core/data'), findsOneWidget);

    await tester.tap(find.text('运行建表 + DAO 读写 Demo'));
    await tester.pumpAndSettle();
    expect(find.textContaining('DAO 读写 Demo 通过'), findsOneWidget);
    expect(find.textContaining('schema v1'), findsWidgets);

    // ── Tab 3 我的：主题切换立即生效 ─────────────────────────────────
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.text('工程自检 · M1 骨架'));
    expect(find.text('工程自检 · M1 骨架'), findsOneWidget);

    await tester.tap(find.text('暗夜金橙'));
    await tester.pumpAndSettle();
    expect(services.theme.preset, AppThemePreset.darkGold);

    await tester.tap(find.text('暖纸书卷'));
    await tester.pumpAndSettle();
    expect(services.theme.preset, AppThemePreset.warmPaper);

    // ── 二级页：可达 + 返回 + 播放条显隐稳定 ────────────────────────
    await scrollTo(tester, find.text('关于 / 版本'));
    await tester.tap(find.text('关于 / 版本'));
    await tester.pumpAndSettle();
    expect(find.text('免责声明'), findsOneWidget);

    await scrollTo(tester, find.text('版本与反馈'));
    expect(find.text('版本与反馈'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('工程自检 · M1 骨架'), findsOneWidget);
    expect(find.byType(MiniPlayer), findsNothing); // 无播放内容 → 仍不显示
  });
}
