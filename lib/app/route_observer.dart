import 'package:flutter/widgets.dart';

/// 全局路由观察者：页面用 [RouteAware] 感知「被其它页面覆盖 / 重新露出」。
///
/// 挂在 `MaterialApp.router` 的 navigator 上，覆盖 push 的二级页、听书播放页
/// 以及弹层（目录 / 排版 / 睡眠定时）等所有 [ModalRoute]，页面不必逐个判断
/// 是被哪个具体页面盖住。阅读页据此暂停/恢复阅读计时。
final RouteObserver<ModalRoute<dynamic>> appRouteObserver =
    RouteObserver<ModalRoute<dynamic>>();
