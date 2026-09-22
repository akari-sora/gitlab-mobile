import 'package:flutter/material.dart';

/// 4 階自適應視窗尺寸類別
enum AdaptiveWindowSize {
  compact,
  medium,
  expanded,
  large;

  static AdaptiveWindowSize fromWidth(double width) {
    if (width < AdaptiveBreakpoints.mediumMin) return AdaptiveWindowSize.compact;
    if (width < AdaptiveBreakpoints.expandedMin) return AdaptiveWindowSize.medium;
    if (width < AdaptiveBreakpoints.largeMin) return AdaptiveWindowSize.expanded;
    return AdaptiveWindowSize.large;
  }

  bool get isCompact => this == AdaptiveWindowSize.compact;
  bool get isMedium => this == AdaptiveWindowSize.medium;
  bool get isExpanded => this == AdaptiveWindowSize.expanded;
  bool get isLarge => this == AdaptiveWindowSize.large;
}

/// 自適應斷點常數與工具類別
final class AdaptiveBreakpoints {
  const AdaptiveBreakpoints._();

  static const double compactMax = 599.999;
  static const double medium = 600.0;
  static const double mediumMin = 600.0;
  static const double expanded = 840.0;
  static const double expandedMin = 840.0;
  static const double large = 1200.0;
  static const double largeMin = 1200.0;

  // 典型元件尺寸常數
  static const double navigationRailWidth = 80.0;
  static const double defaultMasterWidth = 380.0;
  static const double minMasterWidth = 320.0;
  static const double maxMasterWidth = 420.0;
  static const double maxSingleContentWidth = 720.0;
  static const double maxDetailWidth = 960.0;

  static AdaptiveWindowSize of(double width) => AdaptiveWindowSize.fromWidth(width);
  static AdaptiveWindowSize windowSize(double width) => AdaptiveWindowSize.fromWidth(width);
  static bool isCompact(double width) => width < mediumMin;
  static bool isMedium(double width) => width >= mediumMin && width < expandedMin;
  static bool isExpanded(double width) => width >= expandedMin && width < largeMin;
  static bool isLarge(double width) => width >= largeMin;

  /// 外殼導航模式判定：< 600 底部 NavigationBar，>= 600 側邊 NavigationRail
  static bool showNavigationRail(double width) => width >= mediumMin;

  /// 內容雙欄模式判定：>= 840 啟用 List-Detail 雙欄
  static bool showDualPane(double width) => width >= expandedMin;
  static bool isTwoPane(double width) => showDualPane(width);
}

/// 基於 LayoutBuilder 的局部容器寬度感知組件
class AdaptiveBuilder extends StatelessWidget {
  const AdaptiveBuilder({
    super.key,
    required this.builder,
  });

  final Widget Function(
    BuildContext context,
    AdaptiveWindowSize windowSize,
    BoxConstraints constraints,
  ) builder;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final windowSize = AdaptiveWindowSize.fromWidth(constraints.maxWidth);
        return builder(context, windowSize, constraints);
      },
    );
  }
}
