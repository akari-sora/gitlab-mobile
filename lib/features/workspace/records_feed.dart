import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/scroll_chrome.dart';
import '../../shared/workspace_ui.dart';
import 'record_controller.dart';

class RecordsFeed extends StatefulWidget {
  const RecordsFeed({super.key, required this.identity, required this.load, required this.itemBuilder,
    this.empty = '目前沒有項目', this.emptyDetail, this.filteredEmpty, this.account, this.resourceLabel, this.onSwitchAccount,
    this.underShell = false, this.visible, this.header, this.footer, this.leading, this.topSlivers,
    this.grouped = false, this.itemSpacing = 8, this.emptyIcon = Icons.inbox_outlined, this.storageId,
    this.arrange, this.sectionOf, this.emptyArt});
  final String identity;

  /// Reorders the loaded rows before display, e.g. jobs into stage order.
  final List<Json> Function(List<Json> items)? arrange;

  /// Rows sharing a section label render under one heading.
  final String Function(Json item)? sectionOf;

  /// Keys the scroll view (and its remembered offset) when [identity] varies
  /// with input that lives inside the scroll view, such as a search field in
  /// [leading] or [topSlivers]: re-keying would rebuild the field mid-typing.
  final String? storageId;
  final RecordLoader load;
  final Widget Function(BuildContext, Json) itemBuilder;
  final String empty;
  final String? emptyDetail, filteredEmpty, resourceLabel;
  final IconData emptyIcon;

  /// Illustration for the truly empty state (not the filtered-empty one).
  final Widget? emptyArt;
  final Account? account;
  final VoidCallback? onSwitchAccount;
  final bool underShell;
  final bool Function(Json item)? visible;

  /// Pinned above the scroll view.
  final Widget Function(BuildContext context, RecordController controller)? header;

  /// First item of the scroll view; scrolls away with the list (search fields,
  /// filter chips, summaries).
  final Widget Function(BuildContext context, RecordController controller)? leading;

  /// Slivers placed before [leading], such as a floating app bar.
  final List<Widget> Function(BuildContext context, RecordController controller)? topSlivers;
  final Widget Function(BuildContext context, RecordController controller)? footer;

  /// Renders rows contiguously inside one rounded surface with hairline
  /// dividers instead of one card per item.
  final bool grouped;
  final double itemSpacing;
  @override
  State<RecordsFeed> createState() => RecordsFeedState();
}
class RecordsFeedState extends State<RecordsFeed> {
  late final RecordController controller;
  final _scroll = ScrollController();
  List<Json>? _derivedItems;
  bool Function(Json item)? _derivedVisible;
  List<Json> Function(List<Json> items)? _derivedArrange;
  String Function(Json item)? _derivedSectionOf;
  String? _derivedIdentity;
  List<Json> _shown = const [];
  List<String>? _sections;
  List<bool>? _derivedSections;
  @override
  void initState() { super.initState(); controller = RecordController(widget.load); unawaited(controller.refresh()); }
  @override
  void didUpdateWidget(covariant RecordsFeed oldWidget) {
    super.didUpdateWidget(oldWidget); controller.loader = widget.load;
    if (oldWidget.identity != widget.identity) {
      controller.items = []; unawaited(controller.refresh());
      if (widget.storageId != null && widget.storageId == oldWidget.storageId && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.minScrollExtent);
      }
    }
  }
  Future<void> refresh() => controller.refresh();
  Future<void> reconcileLoadedWindow() => controller.reconcileLoadedWindow();
  void patchItem(Json item) => controller.patchItem(item);
  void removeItem(String id) => controller.removeItem(id);
  void prependItem(Json item) => controller.prependItem(item);

  /// Scrolls the feed back to its first row.
  Future<void> scrollToTop() async {
    if (!_scroll.hasClients) return;
    await _scroll.animateTo(0, duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
  }

  @override
  void dispose() { _scroll.dispose(); controller.dispose(); super.dispose(); }

  void _deriveRows() {
    if (identical(_derivedItems, controller.items) &&
        identical(_derivedVisible, widget.visible) && identical(_derivedArrange, widget.arrange) &&
        identical(_derivedSectionOf, widget.sectionOf) && _derivedIdentity == widget.identity) {
      return;
    }
    final visible = widget.visible;
    var shown = <Json>[
      for (final item in controller.items)
        if (visible == null || visible(item)) item,
    ];
    final arrange = widget.arrange;
    if (arrange != null) shown = arrange(shown);
    final sectionOf = widget.sectionOf;
    _shown = shown;
    _sections = sectionOf == null ? null : List<String>.filled(shown.length, '');
    _derivedSections = sectionOf == null ? null : List<bool>.filled(shown.length, false);
    _derivedItems = controller.items;
    _derivedVisible = visible;
    _derivedArrange = arrange;
    _derivedSectionOf = sectionOf;
    _derivedIdentity = widget.identity;
  }

  String _sectionAt(int index) {
    final sections = _sections!, derived = _derivedSections!;
    if (!derived[index]) {
      sections[index] = widget.sectionOf!(_shown[index]);
      derived[index] = true;
    }
    return sections[index];
  }

  Widget _groupedRow(BuildContext context, int index, int count, Widget child) {
    final scheme = Theme.of(context).colorScheme;
    final radius = const Radius.circular(12);
    final first = index == 0, last = index == count - 1;
    final material = Material(type: MaterialType.transparency, child: child);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (!first) Divider(height: 1, thickness: 1, indent: 16, color: scheme.outlineVariant.withValues(alpha: .6)),
      if (first || last) ClipRRect(
        borderRadius: BorderRadius.vertical(top: first ? radius : Radius.zero, bottom: last ? radius : Radius.zero),
        child: material,
      ) else material,
    ]);
  }

  Widget _groupedSurface(BuildContext context, int index, int count, Widget child) {
    final theme = Theme.of(context);
    final color = theme.dividerTheme.color ?? theme.colorScheme.outlineVariant;
    final side = BorderSide(color: color);
    final absent = BorderSide(color: color, width: 0, style: BorderStyle.none);
    final first = index == 0, last = index == count - 1;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.cardTheme.color ?? theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.vertical(
          top: first ? const Radius.circular(12) : Radius.zero,
          bottom: last ? const Radius.circular(12) : Radius.zero,
        ),
        border: Border(left: side, top: first ? side : absent,
          right: side, bottom: last ? side : absent),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: controller, builder: (context, _) {
    _deriveRows();
    final shown = _shown, sections = _sections;
    Widget withSection(BuildContext context, int index, Widget row) {
      if (sections == null) return row;
      final section = _sectionAt(index);
      if (index > 0 && _sectionAt(index - 1) == section) return row;
      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: EdgeInsets.fromLTRB(widget.grouped ? 14 : 4, index == 0 ? 10 : 16, 4, 6), child: Text(section,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary))),
        row,
      ]);
    }
    final gutter = feedGutter(context);
    final before = <Widget>[
      if (controller.loading && controller.items.isEmpty) const ListSkeleton(),
      if (!controller.loading && shown.isEmpty && controller.error == null && controller.next == null) EmptyState(
        controller.items.isEmpty ? widget.empty : (widget.filteredEmpty ?? widget.empty),
        icon: widget.emptyIcon,
        art: controller.items.isEmpty ? widget.emptyArt : null,
        detail: controller.items.isEmpty ? widget.emptyDetail : null),
      if (controller.loading && controller.items.isNotEmpty)
        const Padding(padding: EdgeInsets.only(bottom: 12), child: LinearProgressIndicator(minHeight: 2)),
    ];
    final after = <Widget>[
      if (widget.grouped && shown.isNotEmpty) const SizedBox(height: 12),
      if (controller.error != null) FailureNotice(controller.error!, account: widget.account,
        resourceLabel: widget.resourceLabel, onSwitchAccount: widget.onSwitchAccount,
        onRetry: () { unawaited(controller.retry()); }),
      if (controller.next != null) TextButton.icon(onPressed: controller.loadingMore || controller.loading ? null : () { unawaited(controller.more()); },
        icon: const Icon(Icons.expand_more), label: Text(controller.loadingMore ? '載入中…' : '載入更多')),
      if (widget.footer != null) widget.footer!(context, controller),
    ];
    final items = widget.grouped
        ? SliverList.builder(itemCount: shown.length,
            itemBuilder: (context, index) => _groupedSurface(context, index, shown.length,
              withSection(context, index,
                _groupedRow(context, index, shown.length, widget.itemBuilder(context, shown[index])))))
        : SliverList.builder(itemCount: shown.length,
            itemBuilder: (context, index) => withSection(context, index, Padding(
              padding: EdgeInsets.only(bottom: widget.itemSpacing), child: widget.itemBuilder(context, shown[index]))));
    final bottom = 16 + (widget.underShell ? 8 : 12) + MediaQuery.paddingOf(context).bottom;
    final list = RefreshIndicator(onRefresh: controller.refresh, child: ScrollToTopOnSignal(controller: _scroll, child: CustomScrollView(
      key: PageStorageKey(widget.storageId ?? widget.identity), controller: _scroll, physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        if (widget.topSlivers != null) ...widget.topSlivers!(context, controller),
        if (widget.leading != null) SliverToBoxAdapter(child: widget.leading!(context, controller)),
        SliverPadding(padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 0), sliver: SliverList.list(children: before)),
        SliverPadding(padding: EdgeInsets.symmetric(horizontal: gutter), sliver: items),
        SliverPadding(padding: EdgeInsets.fromLTRB(gutter, 0, gutter, bottom), sliver: SliverList.list(children: after)),
      ],
    )));
    final header = widget.header;
    if (header == null) { return list; }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      header(context, controller),
      Expanded(child: list),
    ]);
  });
}
