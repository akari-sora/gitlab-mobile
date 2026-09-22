import 'package:flutter/material.dart';
import 'adaptive_breakpoints.dart';

/// 狀態驅動的清單/詳情控制器
class ListDetailController<T> extends ChangeNotifier {
  ListDetailController({
    T? initial,
    bool Function(T a, T b)? equals,
  })  : _selected = initial,
        _equals = equals;

  final bool Function(T a, T b)? _equals;
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
    this.breakpoint = AdaptiveBreakpoints.expandedMin,
    this.largeBreakpoint = AdaptiveBreakpoints.largeMin,
    this.maxDetailWidth = AdaptiveBreakpoints.maxDetailWidth,
  });

  final ListDetailController<T> controller;
  final Widget Function(BuildContext context, bool isTwoPane, T? selected) listBuilder;
  final Widget Function(BuildContext context, T item, bool isTwoPane, VoidCallback onBack) detailBuilder;
  final Widget Function(BuildContext context) emptyBuilder;
  final double listWidth;
  final double breakpoint;
  final double largeBreakpoint;
  final double maxDetailWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isTwoPane = constraints.maxWidth >= breakpoint;
        final isLarge = constraints.maxWidth >= largeBreakpoint;

        return ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final selected = controller.selected;

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
                  child: detailBuilder(
                    context,
                    selected,
                    false,
                    controller.clear,
                  ),
                ),
              );
            }

            // Expanded / Two-Pane 模式 (>= 840 dp)：雙欄呈現
            final Widget detailPane;
            if (selected != null) {
              detailPane = KeyedSubtree(
                key: const ValueKey('adaptive-detail-pane'),
                child: detailBuilder(context, selected, true, controller.clear),
              );
            } else {
              detailPane = KeyedSubtree(
                key: const ValueKey('adaptive-empty-pane'),
                child: emptyBuilder(context),
              );
            }

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
