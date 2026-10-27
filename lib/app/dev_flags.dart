/// 开发调试内容的显示开关。
class DevFlags {
  DevFlags._();

  /// 是否渲染开发调试面板：
  /// - 书架「本地数据层自检」（建表 + DAO 读写 Demo）；
  /// - 我的「工程自检 · M1 骨架」（接口配置 / 数据库状态）。
  ///
  /// 默认关闭（日常运行与 release 包都不显示）。
  /// 需要临时查看：`flutter run --dart-define=SHOW_DEV_PANELS=true`；
  /// `widget_test` 为保留 M1 准出冒烟链路会把它置为 true。
  static bool showPanels = const bool.fromEnvironment('SHOW_DEV_PANELS');
}
