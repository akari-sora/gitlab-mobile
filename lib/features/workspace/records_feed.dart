import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/workspace_ui.dart';
import 'record_controller.dart';

class RecordsFeed extends StatefulWidget {
  const RecordsFeed({super.key, required this.identity, required this.load, required this.itemBuilder,
    this.empty = '目前沒有項目', this.emptyDetail, this.account, this.resourceLabel, this.onSwitchAccount,
    this.underShell = false});
  final String identity;
  final RecordLoader load;
  final Widget Function(BuildContext, Json) itemBuilder;
  final String empty;
  final String? emptyDetail, resourceLabel;
  final Account? account;
  final VoidCallback? onSwitchAccount;
  final bool underShell;
  @override
  State<RecordsFeed> createState() => RecordsFeedState();
}
class RecordsFeedState extends State<RecordsFeed> {
  late final RecordController controller;
  @override
  void initState() { super.initState(); controller = RecordController(widget.load); unawaited(controller.refresh()); }
  @override
  void didUpdateWidget(covariant RecordsFeed oldWidget) {
    super.didUpdateWidget(oldWidget); controller.loader = widget.load;
    if (oldWidget.identity != widget.identity) { controller.items = []; unawaited(controller.refresh()); }
  }
  Future<void> refresh() => controller.refresh();
  @override
  void dispose() { controller.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: controller, builder: (context, _) =>
    RefreshIndicator(onRefresh: controller.refresh, child: ListView(
      key: PageStorageKey(widget.identity), physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + (widget.underShell ? 80 : 12) + MediaQuery.paddingOf(context).bottom), children: [
        if (controller.loading && controller.items.isEmpty) const ListSkeleton(),
        if (!controller.loading && controller.items.isEmpty && controller.error == null) EmptyState(widget.empty, detail: widget.emptyDetail),
        if (controller.loading && controller.items.isNotEmpty)
          const Padding(padding: EdgeInsets.only(bottom: 12), child: LinearProgressIndicator(minHeight: 2)),
        for (final item in controller.items) Padding(padding: const EdgeInsets.only(bottom: 10), child: widget.itemBuilder(context, item)),
        if (controller.error != null) FailureNotice(controller.error!, account: widget.account,
          resourceLabel: widget.resourceLabel, onSwitchAccount: widget.onSwitchAccount,
          onRetry: () { unawaited(controller.retry()); }),
        if (controller.next != null) TextButton.icon(onPressed: controller.loadingMore || controller.loading ? null : () { unawaited(controller.more()); },
          icon: const Icon(Icons.expand_more), label: Text(controller.loadingMore ? '載入中…' : '載入更多')),
      ],
    )),
  );
}
