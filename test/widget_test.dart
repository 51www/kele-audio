import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kele_audio/app/app.dart';
import 'package:kele_audio/app/di.dart';

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

  testWidgets('M1 准出冒烟：三 Tab 壳 + 主题切换 + 二级页返回', (tester) async {
    SharedPreferences.setMockInitialValues({});

    final services = await AppServices.bootstrap(isWeb: false);
    addTearDown(services.player.dispose); // M2：测试结束释放 watchdog Timer/观察者
    await tester.pumpWidget(KeleApp(services: services));
    await tester.pumpAndSettle();

    // ── Tab 1 发现：接口自检卡片 + 卡片流 ────────────────────────────
    expect(find.text('可乐听书'), findsOneWidget);
    expect(find.text('接口自检 · core/api'), findsOneWidget);
    expect(find.text('按类型找内容'), findsOneWidget);
    expect(find.text('未在播放'), findsOneWidget); // MiniPlayer 占位

    // 分类切换（状态保留在页面里）——M2 顶部新增播放样本卡，chips 需先滚入视口
    await scrollTo(tester, find.text('相声曲艺'));
    await tester.tap(find.text('相声曲艺'));
    await tester.pumpAndSettle();
    expect(find.text('单田芳评书合集 · 白眉大侠'), findsOneWidget);

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

    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(services.theme.mode, ThemeMode.dark);

    await tester.tap(find.text('浅色'));
    await tester.pumpAndSettle();
    expect(services.theme.mode, ThemeMode.light);

    // ── 二级页：可达 + 返回 + MiniPlayer 不丢 ────────────────────────
    await scrollTo(tester, find.text('关于 / 版本'));
    await tester.tap(find.text('关于 / 版本'));
    await tester.pumpAndSettle();
    expect(find.text('免责声明'), findsOneWidget);

    await scrollTo(tester, find.textContaining('阿B听书'));
    expect(find.textContaining('阿B听书'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('工程自检 · M1 骨架'), findsOneWidget);
    expect(find.text('未在播放'), findsOneWidget);
  });
}
