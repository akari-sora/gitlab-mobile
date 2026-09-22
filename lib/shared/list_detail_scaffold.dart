import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'adaptive_breakpoints.dart';

/// 狀態驅動的清單/詳情控制器
class ListDetailController<T> extends ChangeNotifier {
  ListDetailController({
    T? initial,
    bool Function(T a, T b)? equals,
    GlobalKey? detailKey,
    GlobalKey? listKey,
  })  : _selected = initial,
        _equals = equals,
        detailKey = detailKey ?? GlobalKey(debugLabel: 'ListDetailPane_$T'),
        listKey = listKey ?? GlobalKey(debugLabel: 'ListPane_$T');

  final bool Function(T a, T b)? _equals;
  /// 供 ListDetailScaffold 在跨斷點遷移時保留 Element 樹與內部 State
  final GlobalKey detailKey;
  final GlobalKey listKey;
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

/// 登記於 [DetailBackDispatcher] 的返回處理項目
class DetailBackEntry {
  DetailBackEntry({
    required this.depth,
    required this.canHandle,
    required this.onBack,
  });

  int depth;
  final bool Function() canHandle;
  final VoidCallback onBack;
}

/// 集中協調單欄與巢狀清單詳情返回動作的責任鏈調度器
class DetailBackDispatcher extends ChangeNotifier {
  final List<DetailBackEntry> _entries = [];
  bool _disposed = false;
  bool _lastCanHandleBack = false;

  bool get canHandleBack => _entries.any((e) => e.canHandle());

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void register(DetailBackEntry entry) {
    _entries.add(entry);
    _checkChanged();
  }

  void unregister(DetailBackEntry entry) {
    _entries.remove(entry);
    _checkChanged();
  }

  void notifyChanged() {
    _checkChanged();
  }

  void _checkChanged() {
    if (_disposed) return;
    final current = canHandleBack;
    if (current != _lastCanHandleBack) {
      _lastCanHandleBack = current;
      if (WidgetsBinding.instance.schedulerPhase == SchedulerPhase.idle) {
        notifyListeners();
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_disposed) {
            notifyListeners();
          }
        });
      }
    }
  }

  /// 依深度由深至淺（最內層最優先）尋找可處理返回的處理項目並執行
  bool handleBack() {
    final candidates = _entries.where((e) => e.canHandle()).toList();
    if (candidates.isEmpty) return false;
    candidates.sort((a, b) => b.depth.compareTo(a.depth));
    candidates.first.onBack();
    _checkChanged();
    return true;
  }
}

/// 透過 InheritedWidget 提供當前 Subtree 的調度器與深度資訊
class DetailBackScope extends InheritedWidget {
  const DetailBackScope({
    super.key,
    required this.dispatcher,
    required this.depth,
    required super.child,
  });

  final DetailBackDispatcher dispatcher;
  final int depth;

  static DetailBackScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<DetailBackScope>();
  }

  @override
  bool updateShouldNotify(DetailBackScope oldWidget) =>
      dispatcher != oldWidget.dispatcher || depth != oldWidget.depth;
}

/// 標記當前 Tab 或 Subtree 是否處於活躍狀態（非活躍時不響應系統返回）
class TabActiveScope extends InheritedWidget {
  const TabActiveScope({
    super.key,
    required this.isActive,
    required super.child,
  });

  final bool isActive;

  static bool of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<TabActiveScope>();
    return scope?.isActive ?? true;
  }

  @override
  bool updateShouldNotify(TabActiveScope oldWidget) => isActive != oldWidget.isActive;
}

/// 自適應清單詳情雙欄腳手架
class ListDetailScaffold<T> extends StatefulWidget {
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
    this.listKey,
    this.active,
    this.collapseMaster,
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
  final GlobalKey? listKey;
  final bool? active;
  final bool Function(T? selected)? collapseMaster;

  @override
  State<ListDetailScaffold<T>> createState() => _ListDetailScaffoldState<T>();
}

class _ListDetailScaffoldState<T> extends State<ListDetailScaffold<T>> {
  DetailBackDispatcher? _localDispatcher;
  DetailBackDispatcher? _registeredDispatcher;
  DetailBackEntry? _entry;
  int _depth = 1;
  bool _isTwoPane = false;
  bool _isActive = true;

  bool _lastShouldCollapse = false;

  @override
  void initState() {
    super.initState();
    _isActive = widget.active ?? true;
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _isActive = widget.active ?? TabActiveScope.of(context);
    final parentScope = DetailBackScope.maybeOf(context);
    final dispatcher = parentScope?.dispatcher ?? (_localDispatcher ??= DetailBackDispatcher());
    _depth = (parentScope?.depth ?? 0) + 1;

    if (_registeredDispatcher != dispatcher) {
      if (_entry != null && _registeredDispatcher != null) {
        _registeredDispatcher!.unregister(_entry!);
      }
      _registeredDispatcher = dispatcher;
      _entry = DetailBackEntry(
        depth: _depth,
        canHandle: _canHandleBack,
        onBack: _onBack,
      );
      dispatcher.register(_entry!);
    } else {
      _entry?.depth = _depth;
      _registeredDispatcher?.notifyChanged();
    }
  }

  @override
  void didUpdateWidget(covariant ListDetailScaffold<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
    if (oldWidget.active != widget.active) {
      _isActive = widget.active ?? _isActive;
    }
    _registeredDispatcher?.notifyChanged();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    if (_entry != null && _registeredDispatcher != null) {
      _registeredDispatcher!.unregister(_entry!);
    }
    _localDispatcher?.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    _registeredDispatcher?.notifyChanged();
  }

  bool _canHandleBack() {
    if (!mounted) return false;
    final shouldCollapse = widget.collapseMaster?.call(widget.controller.selected) ?? false;
    if (_isTwoPane && !shouldCollapse) return false;
    if (!widget.controller.hasSelection) return false;
    return widget.active ?? _isActive;
  }

  void _onBack() {
    widget.controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final parentScope = DetailBackScope.maybeOf(context);
    final effectiveDetailKey = widget.detailKey ?? widget.controller.detailKey;
    final effectiveListKey = widget.listKey ?? widget.controller.listKey;
    final hasRail = AdaptiveScope.hasRailOf(context);
    final effectiveBreakpoint = widget.breakpoint ??
        (hasRail
            ? AdaptiveBreakpoints.expandedMinWithRail
            : AdaptiveBreakpoints.expandedMin);
    final effectiveLargeBreakpoint = widget.largeBreakpoint ??
        (hasRail
            ? AdaptiveBreakpoints.largeMinWithRail
            : AdaptiveBreakpoints.largeMin);

    return LayoutBuilder(
      builder: (context, constraints) {
        final newIsTwoPane = constraints.maxWidth >= effectiveBreakpoint;
        if (_isTwoPane != newIsTwoPane) {
          _isTwoPane = newIsTwoPane;
          _registeredDispatcher?.notifyChanged();
        }
        final isLarge = constraints.maxWidth >= effectiveLargeBreakpoint;

        return ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) {
            final selected = widget.controller.selected;
            final shouldCollapse = _isTwoPane && (widget.collapseMaster?.call(selected) ?? false);
            if (_lastShouldCollapse != shouldCollapse) {
              _lastShouldCollapse = shouldCollapse;
              _registeredDispatcher?.notifyChanged();
            }

            final compactMediaQuery = MediaQuery.of(context).copyWith(
              size: Size(constraints.maxWidth, constraints.maxHeight),
            );

            final listMediaQuery = MediaQuery.of(context).copyWith(
              size: Size(widget.listWidth, constraints.maxHeight),
              padding: MediaQuery.of(context).padding.copyWith(right: 0.0),
            );

            final availableDetailWidth = (constraints.maxWidth - widget.listWidth - 1.0).clamp(0.0, double.infinity);
            final detailWidth = isLarge && availableDetailWidth > widget.maxDetailWidth
                ? widget.maxDetailWidth
                : availableDetailWidth;
            final detailMediaQuery = MediaQuery.of(context).copyWith(
              size: Size(detailWidth, constraints.maxHeight),
              padding: MediaQuery.of(context).padding.copyWith(left: 0.0),
            );

            // 建立具有穩定 GlobalKey 的 detail 節點，透過 Builder 注入接收到局部 MediaQuery 的子 context
            // 並將 DetailBackScope 包覆在 detail 周圍，深度為 _depth，讓內層 scaffold 繼承並將深度累加
            final Widget? stableDetail = selected != null
                ? KeyedSubtree(
                    key: effectiveDetailKey,
                    child: DetailBackScope(
                      dispatcher: _registeredDispatcher!,
                      depth: _depth,
                      child: Builder(
                        builder: (paneContext) => widget.detailBuilder(
                          paneContext,
                          selected,
                          _isTwoPane,
                          widget.controller.clear,
                        ),
                      ),
                    ),
                  )
                : null;

            Widget content;
            if (!_isTwoPane) {
              // Compact 模式 (< 840 dp)：單欄切換
              // 透過 Stack + Offstage 保留清單 subtree，避免 RecordsFeedState 與 RecordController 銷毀
              content = Stack(
                fit: StackFit.expand,
                children: [
                  Offstage(
                    offstage: selected != null,
                    child: ExcludeFocus(
                      excluding: selected != null,
                      child: ExcludeSemantics(
                        excluding: selected != null,
                        child: TickerMode(
                          enabled: selected == null,
                          child: MediaQuery(
                            data: compactMediaQuery,
                            child: KeyedSubtree(
                              key: effectiveListKey,
                              child: Builder(
                                builder: (paneContext) => widget.listBuilder(
                                  paneContext,
                                  false,
                                  selected,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (selected != null)
                    Positioned.fill(
                      child: KeyedSubtree(
                        key: const ValueKey('adaptive-compact-detail'),
                        child: MediaQuery(
                          data: compactMediaQuery,
                          child: stableDetail!,
                        ),
                      ),
                    ),
                ],
              );
            } else if (shouldCollapse) {
              // Expanded 雙欄模式但 Master 摺疊（例如進入 Issues/MR 時，將空間完整交給內層雙欄）：
              // Detail pane 佔據全部寬度，保留 hasRail 旗標以便內層 scaffold 判斷斷點
              // Master list 透過 Offstage 保留在 subtree 中，確保 RecordsFeedState 與滾動位置不丟失
              final Widget rawDetailPane;
              if (selected != null) {
                rawDetailPane = KeyedSubtree(
                  key: const ValueKey('adaptive-detail-pane'),
                  child: stableDetail!,
                );
              } else {
                rawDetailPane = KeyedSubtree(
                  key: const ValueKey('adaptive-empty-pane'),
                  child: Builder(
                    builder: (paneContext) => widget.emptyBuilder(paneContext),
                  ),
                );
              }

              final detailPane = AdaptiveScope(
                hasRail: hasRail,
                child: MediaQuery(
                  data: compactMediaQuery,
                  child: rawDetailPane,
                ),
              );

              content = Stack(
                fit: StackFit.expand,
                children: [
                  Offstage(
                    offstage: true,
                    child: ExcludeFocus(
                      excluding: true,
                      child: ExcludeSemantics(
                        excluding: true,
                        child: TickerMode(
                          enabled: false,
                          child: MediaQuery(
                            data: listMediaQuery,
                            child: KeyedSubtree(
                              key: effectiveListKey,
                              child: Builder(
                                builder: (paneContext) => widget.listBuilder(
                                  paneContext,
                                  true,
                                  selected,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: KeyedSubtree(
                      key: const ValueKey('adaptive-collapsed-master-detail'),
                      child: detailPane,
                    ),
                  ),
                ],
              );
            } else {
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
                  child: Builder(
                    builder: (paneContext) => widget.emptyBuilder(paneContext),
                  ),
                );
              }

              final detailPane = AdaptiveScope(
                hasRail: false,
                child: MediaQuery(
                  data: detailMediaQuery,
                  child: rawDetailPane,
                ),
              );

              final constrainedDetail = isLarge
                  ? Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        key: const ValueKey('detail-content-container'),
                        constraints: BoxConstraints(maxWidth: widget.maxDetailWidth),
                        child: detailPane,
                      ),
                    )
                  : detailPane;

              content = Row(
                key: const ValueKey('adaptive-two-pane-row'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    key: const ValueKey('list-pane'),
                    width: widget.listWidth,
                    child: MediaQuery(
                      data: listMediaQuery,
                      child: KeyedSubtree(
                        key: effectiveListKey,
                        child: Builder(
                          builder: (paneContext) => widget.listBuilder(
                            paneContext,
                            true,
                            selected,
                          ),
                        ),
                      ),
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
            }

            // 若本層自己建立了 _localDispatcher（外層無 Shell，如單獨測試 ProjectsPage）
            // 則由本層提供 DetailBackScope 與唯一的 PopScope
            if (parentScope == null && _localDispatcher != null) {
              return DetailBackScope(
                dispatcher: _localDispatcher!,
                depth: _depth,
                child: ListenableBuilder(
                  listenable: _localDispatcher!,
                  builder: (context, _) {
                    return PopScope<Object?>(
                      canPop: !_localDispatcher!.canHandleBack,
                      onPopInvokedWithResult: (didPop, _) {
                        if (!didPop) {
                          _localDispatcher!.handleBack();
                        }
                      },
                      child: content,
                    );
                  },
                ),
              );
            }

            return content;
          },
        );
      },
    );
  }
}
