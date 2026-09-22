import 'package:flutter/material.dart';
import 'adaptive_breakpoints.dart';

/// 狀態驅動的清單/詳情控制器
class ListDetailController<T> extends ChangeNotifier {
  ListDetailController({
    T? initial,
    bool Function(T a, T b)? equals,
    GlobalKey? detailKey,
  })  : _selected = initial,
        _equals = equals,
        detailKey = detailKey ?? GlobalKey(debugLabel: 'ListDetailPane_$T');

  final bool Function(T a, T b)? _equals;
  /// 供 ListDetailScaffold 在跨斷點遷移時保留 Element 樹與內部 State
  final GlobalKey detailKey;
  T? _selected;

  T? get selected => _selected;
  bool get hasSelection => _selected != null;

  bool isSelected(T? item) {
    if (_selected == null || item == null) return false;
    if (_equals != null) return _equals(_selected as T, item);
    return _selected == item;
  }

  void select(T? item) {
    if (!isSelected(item) || _selected != item) {
      _selected = item;
      notifyListeners();
    }
  }

  void clear() {
    if (_selected != null) {
      _selected = null;
      notifyListeners();
    }
  }
}

/// 自適應清單詳情雙欄腳手架
class ListDetailScaffold<T> extends StatelessWidget {
  const ListDetailScaffold({
    super.key,
    required this.controller,
    required this.listBuilder,
    required this.detailBuilder,
    required this.emptyBuilder,
    this.listWidth = AdaptiveBreakpoints.defaultMasterWidth,
    this.breakpoint,
    this.largeBreakpoint,
    this.maxDetailWidth = AdaptiveBreakpoints.maxDetailWidth,
    this.detailKey,
  });

  final ListDetailController<T> controller;
  final Widget Function(BuildContext context, bool isTwoPane, T? selected) listBuilder;
  final Widget Function(BuildContext context, T item, bool isTwoPane, VoidCallback onBack) detailBuilder;
  final Widget Function(BuildContext context) emptyBuilder;
  final double listWidth;
  final double? breakpoint;
  final double? largeBreakpoint;
  final double maxDetailWidth;
  final GlobalKey? detailKey;

  @override
  Widget build(BuildContext context) {
    final effectiveDetailKey = detailKey ?? controller.detailKey;
    final hasRail = AdaptiveScope.hasRailOf(context);
    final effectiveBreakpoint = breakpoint ??
        (hasRail
            ? AdaptiveBreakpoints.expandedMinWithRail
            : AdaptiveBreakpoints.expandedMin);
    final effectiveLargeBreakpoint = largeBreakpoint ??
        (hasRail
            ? AdaptiveBreakpoints.largeMinWithRail
            : AdaptiveBreakpoints.largeMin);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isTwoPane = constraints.maxWidth >= effectiveBreakpoint;
        final isLarge = constraints.maxWidth >= effectiveLargeBreakpoint;

        return ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final selected = controller.selected;

            // 建立具有穩定 GlobalKey 的 detail 節點，供 Compact 與 Two-Pane 跨斷點平滑遷移
            final Widget? stableDetail = selected != null
                ? KeyedSubtree(
                    key: effectiveDetailKey,
                    child: detailBuilder(
                      context,
                      selected,
                      isTwoPane,
                      controller.clear,
                    ),
                  )
                : null;

            if (!isTwoPane) {
              // Compact 模式 (< 840 dp)：單欄切換
              if (selected == null) {
                return listBuilder(context, false, null);
              }
              return PopScope<Object?>(
                canPop: false,
                onPopInvokedWithResult: (didPop, _) {
                  if (!didPop) controller.clear();
                },
                child: KeyedSubtree(
                  key: const ValueKey('adaptive-compact-detail'),
                  child: stableDetail!,
                ),
              );
            }

            // Expanded / Two-Pane 模式 (>= 840 dp)：雙欄呈現
            final Widget rawDetailPane;
            if (selected != null) {
              rawDetailPane = KeyedSubtree(
                key: const ValueKey('adaptive-detail-pane'),
                child: stableDetail!,
              );
            } else {
              rawDetailPane = KeyedSubtree(
                key: const ValueKey('adaptive-empty-pane'),
                child: emptyBuilder(context),
              );
            }

            // 詳情區域重設 AdaptiveScope，確保巢狀 Scaffold 不受外層 Rail 影響
            final detailPane = AdaptiveScope(
              hasRail: false,
              child: rawDetailPane,
            );

            final constrainedDetail = isLarge
                ? Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      key: const ValueKey('detail-content-container'),
                      constraints: BoxConstraints(maxWidth: maxDetailWidth),
                      child: detailPane,
                    ),
                  )
                : detailPane;

            // 覆寫左側清單區域的 MediaQuery size，確保內部 feedGutter 永遠使用固定 16 dp 邊距
            final listMediaQuery = MediaQuery.of(context).copyWith(
              size: Size(listWidth, constraints.maxHeight),
            );

            return Row(
              key: const ValueKey('adaptive-two-pane-row'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  key: const ValueKey('list-pane'),
                  width: listWidth,
                  child: MediaQuery(
                    data: listMediaQuery,
                    child: listBuilder(context, true, selected),
                  ),
                ),
                VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                Expanded(
                  key: const ValueKey('detail-pane-expanded'),
                  child: ClipRect(
                    child: constrainedDetail,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
