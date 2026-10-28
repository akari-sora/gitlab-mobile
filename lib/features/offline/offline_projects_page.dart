import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/offline/offline_repository_coordinator.dart';
import '../../core/offline/snapshot_save.dart';
import '../../core/offline/snapshot_schema.dart';
import '../../core/repository_ref.dart';
import '../../l10n/l10n.dart';
import '../../shared/hub_ui.dart';
import '../../shared/theme.dart';
import '../../shared/workspace_ui.dart';
import '../workspace/project_page.dart';
import 'offline_repositories.dart';
import 'offline_status.dart';
import 'snapshot_browser_page.dart';

/// 我的 › 儲存與快取 › 離線專案: one row that opens [OfflineProjectsPage].
class OfflineProjectsEntry extends StatelessWidget {
  const OfflineProjectsEntry({super.key, required this.account});
  final Account account;

  @override
  Widget build(BuildContext context) {
    final repositories = OfflineScope.maybeOf(context);
    if (repositories == null) return const SizedBox.shrink();
    return HubRow(
      key: const ValueKey('offline-projects-row'),
      leading: const IconTile(Icons.download_for_offline_outlined, color: HubColors.green),
      title: l10n.offlineProjectsTitle,
      value: l10n.offlineProjectsSummary(
        repositories.snapshots.length,
        snapshotSize(repositories.usedBytes),
      ),
      chevron: true,
      onTap: () => unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => OfflineProjectsPage(
              repositories: repositories,
              account: account,
            ),
          ),
        ),
      ),
    );
  }
}

/// One row of the list: a saved record, or a new save still in the queue.
final class _Row {
  const _Row({this.record, this.job});
  final SnapshotRecord? record;
  final SnapshotSaveJob? job;

  String get projectName => record?.projectName ?? job!.request.projectName;
  String get projectPath => record?.projectPath ?? job!.request.projectPath;
  String get refName => record?.refName ?? job!.request.refName;
  SnapshotRefKind get refKind => record?.refKind ?? job!.request.refKind;
  String get subPath => record?.subPath ?? job!.request.subPath;
  int get projectId => record?.projectId ?? job!.request.projectId;

  SnapshotRowStatus get status =>
      record != null ? recordStatus(record!, job) : jobStatus(job!);
}

enum _RowAction { update, pause, resume, cancel, delete, openOnline }

/// Every offline project of the signed-in account (§6.4).
class OfflineProjectsPage extends StatefulWidget {
  const OfflineProjectsPage({
    super.key,
    required this.repositories,
    required this.account,
  });

  final OfflineRepositories repositories;
  final Account account;

  @override
  State<OfflineProjectsPage> createState() => _OfflineProjectsPageState();
}

class _OfflineProjectsPageState extends State<OfflineProjectsPage> {
  bool _noticeDismissed = false;
  bool _busy = false;

  OfflineRepositories get _repos => widget.repositories;

  @override
  void initState() {
    super.initState();
    // Opening the list online checks the saved branches (§3.14); it is a
    // no-op without a live client.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && snapshotOnline(context, _repos)) unawaited(_repos.probe());
    });
  }

  List<_Row> _rows() {
    final jobs = [?_repos.activeJob, ..._repos.queuedJobs];
    final rows = <_Row>[
      for (final record in _repos.snapshots)
        _Row(record: record, job: jobOfRecord(_repos, record)),
    ];
    final known = {for (final record in _repos.snapshots) record.id};
    for (final job in jobs) {
      if (!known.contains(job.id) && !known.contains(job.snapshot?.id)) {
        rows.add(_Row(job: job));
      }
    }
    return rows;
  }

  Future<void> _act(_Row row, _RowAction action) async {
    final record = row.record;
    final job = row.job;
    try {
      switch (action) {
        case _RowAction.update:
          if (record == null) return;
          _repos.save(_request(record, replaces: record.id));
          _say(l10n.saveSheetStarted);
        case _RowAction.resume:
          if (record == null) return;
          _repos.save(_request(record), resume: record);
          _say(l10n.saveSheetStarted);
        case _RowAction.pause:
          if (job != null) _repos.pause(job);
        case _RowAction.cancel:
          if (!await confirmAction(
            context,
            l10n.offlineCancelTitle,
            l10n.offlineCancelDetail,
          )) {
            return;
          }
          if (job != null) {
            await _repos.cancel(job);
          } else if (record != null) {
            await _repos.remove(record.id);
          }
        case _RowAction.delete:
          if (record == null) return;
          if (!mounted ||
              !await confirmAction(
                context,
                l10n.offlineDeleteTitle,
                l10n.offlineDeleteDetail(
                  isolated(record.projectName),
                  snapshotSize(record.storedBytes),
                ),
              )) {
            return;
          }
          await _repos.remove(record.id);
          _say(l10n.offlineDeleted);
        case _RowAction.openOnline:
          final api = _repos.api;
          if (api == null || !mounted) return;
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ProjectPage(
                account: widget.account,
                api: api,
                project: record != null
                    ? snapshotProject(record)
                    : Project(
                        id: row.projectId,
                        name: row.projectName,
                        path: row.projectPath,
                      ),
              ),
            ),
          );
      }
    } on Object catch (error) {
      if (!mounted) return;
      // §3.13: if the index cannot be rewritten after the tree went, the
      // way out is the namespace clear.
      if (action == _RowAction.delete &&
          snapshotFailureOf(error) == SnapshotFailure.storageError) {
        showFailure(
          context,
          SnapshotUiFailure(SnapshotFailure.storageError,
              titleText: l10n.offlineDeleteUseAll),
        );
      } else {
        showSnapshotFailure(context, error);
      }
    }
  }

  SnapshotSaveRequest _request(SnapshotRecord record, {String? replaces}) =>
      SnapshotSaveRequest(
        projectId: record.projectId,
        projectPath: record.projectPath,
        projectName: record.projectName,
        defaultBranch: record.defaultBranch,
        refKind: record.refKind,
        refName: record.refName,
        consentAt: _repos.consentAt ?? DateTime.now().toUtc(),
        subPath: record.subPath,
        replaces: replaces,
      );

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _deleteAll() async {
    final count = _repos.snapshots.length;
    final confirmed = await confirmAction(
      context,
      l10n.offlineDeleteAllTitle,
      l10n.offlineDeleteAllDetail(count, snapshotSize(_repos.usedBytes)),
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      await _repos.clearAll();
      _say(l10n.offlineDeletedAll);
    } on Object catch (error) {
      if (mounted) showSnapshotFailure(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _repos,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: Text(l10n.offlineProjectsTitle)),
      body: _body(context),
    ),
  );

  Widget _body(BuildContext context) {
    final theme = Theme.of(context);
    final rows = _rows();
    final notice = _repos.removedNotice;
    final blocker = switch (_repos.state) {
      OfflineRepositoryState.unavailable => l10n.snapshotFailureKeyUnavailable,
      OfflineRepositoryState.needsNewerApp => l10n.saveBlockedNewerApp,
      OfflineRepositoryState.cleaning => l10n.saveBlockedCleaning,
      _ => switch (_repos.failure) {
        SnapshotFailure.keyUnavailable => l10n.snapshotFailureKeyUnavailable,
        null => null,
        final failure => snapshotFailureText(failure),
      },
    };
    final online = snapshotOnline(context, _repos);
    return ListView(
      key: const ValueKey('offline-projects-list'),
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        if (_busy || _repos.loading) const LinearProgressIndicator(minHeight: 2),
        HubSection(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                l10n.offlineProjectsHeader(
                  _repos.snapshots.length,
                  snapshotSize(_repos.usedBytes),
                  snapshotLimitText,
                ),
                key: const ValueKey('offline-projects-header'),
                style: theme.textTheme.titleMedium,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: (_repos.usedBytes / snapshotAccountLimit).clamp(0.0, 1.0),
                  minHeight: 4,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                l10n.offlineProjectsAccountNote,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        if (notice != null && !_noticeDismissed)
          OfflineNotice(
            key: const ValueKey('offline-removed-notice'),
            icon: Icons.info_outline,
            title: l10n.offlineRemovedNotice(notice.count),
            actions: [
              TextButton(
                onPressed: () => setState(() => _noticeDismissed = true),
                child: Text(l10n.offlineConsentClose),
              ),
            ],
          ),
        if (blocker != null)
          OfflineNotice(
            key: const ValueKey('offline-projects-blocker'),
            icon: Icons.error_outline,
            error: true,
            title: blocker,
            actions: [
              TextButton.icon(
                onPressed: () => unawaited(_repos.refresh()),
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(l10n.refreshAction),
              ),
            ],
          ),
        if (rows.isEmpty && !_repos.loading && blocker == null)
          EmptyState(
            l10n.offlineEmptyTitle,
            detail: l10n.offlineEmptyDetail,
            icon: Icons.download_for_offline_outlined,
          ),
        if (rows.isNotEmpty)
          HubSection(
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) const Divider(height: 1, indent: 16),
                _SnapshotRowTile(
                  row: rows[i],
                  online: online,
                  onOpen: rows[i].record != null &&
                          rows[i].status.complete
                      ? () => unawaited(
                          openSnapshot(
                            context,
                            repositories: _repos,
                            record: rows[i].record!,
                            account: widget.account,
                          ),
                        )
                      : null,
                  onAction: (action) => unawaited(_act(rows[i], action)),
                ),
              ],
            ],
          ),
        if (_repos.snapshots.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                key: const ValueKey('offline-delete-all'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                  minimumSize: const Size(48, 48),
                ),
                onPressed: _busy ? null : () => unawaited(_deleteAll()),
                icon: const Icon(Icons.delete_sweep_outlined),
                label: Text(l10n.offlineDeleteAllAction),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.lock_outline,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.offlineAppLockHint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SnapshotRowTile extends StatelessWidget {
  const _SnapshotRowTile({
    required this.row,
    required this.online,
    required this.onAction,
    this.onOpen,
  });

  final _Row row;
  final bool online;
  final VoidCallback? onOpen;
  final ValueChanged<_RowAction> onAction;

  List<_RowAction> _actions(SnapshotRowStatus status) => [
    if (online && status.complete) _RowAction.update,
    if (status.busy && row.job != null) _RowAction.pause,
    if (online && status.resumable && row.record != null) _RowAction.resume,
    if (status.busy || status.resumable) _RowAction.cancel,
    if (row.record != null && !status.busy) _RowAction.delete,
    if (online) _RowAction.openOnline,
  ];

  String _label(_RowAction action) => switch (action) {
    _RowAction.update => l10n.offlineActionUpdate,
    _RowAction.pause => l10n.offlineActionPause,
    _RowAction.resume => l10n.offlineActionResume,
    _RowAction.cancel => l10n.offlineActionCancel,
    _RowAction.delete => l10n.offlineActionDelete,
    _RowAction.openOnline => l10n.offlineActionOpenOnline,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final status = row.status;
    final record = row.record;
    final actions = _actions(status);
    final phase = snapshotPhaseText(status);
    final small = theme.textTheme.bodySmall?.copyWith(color: muted);
    final meta = [
      if (record?.savedAt case final saved?)
        l10n.offlineRowSavedAt(relativeTime(saved)),
      if (record != null && record.storedBytes > 0)
        snapshotSize(record.storedBytes),
    ].join(' · ');
    final chip = SnapshotStatusChip(status);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Below 360 dp the status moves under the title (§6.10).
        final narrow = constraints.maxWidth < 360;
        final title = Text(
          isolated(row.projectName),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyLarge?.copyWith(fontSize: 17, height: 1.3),
        );
        return InkWell(
          key: ValueKey('offline-row-${record?.id ?? row.job!.id}'),
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 10, 4, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: NeutralTile(Icons.offline_pin_outlined),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (narrow) title else Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: title),
                          const SizedBox(width: 8),
                          Flexible(child: chip),
                        ],
                      ),
                      Text(
                        isolated(row.projectPath),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: small,
                      ),
                      const SizedBox(height: 2),
                      Wrap(
                        spacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Icon(
                            row.refKind == SnapshotRefKind.tag
                                ? Icons.label_outline
                                : Icons.alt_route,
                            size: 14,
                            color: muted,
                          ),
                          Text(isolated(row.refName), style: small),
                          if (record != null)
                            Text(
                              '@ ${RepositoryRef.shortSha(record.sha)}',
                              textDirection: TextDirection.ltr,
                              style: codeTextStyle(context, fontSize: 12, color: muted),
                            ),
                          if (row.subPath.isNotEmpty)
                            Text(
                              l10n.offlineRowFolder(isolated(row.subPath)),
                              style: small,
                            ),
                        ],
                      ),
                      if (meta.isNotEmpty) Text(meta, style: small),
                      if (narrow) ...[
                        const SizedBox(height: 6),
                        chip,
                      ],
                      if (status.kind == SnapshotStatusKind.saving) ...[
                        const SizedBox(height: 6),
                        Semantics(
                          // Announced once per quarter, not on every step.
                          liveRegion: true,
                          label: l10n.snapshotStatusSaving(status.percent ~/ 25 * 25),
                          child: ExcludeSemantics(
                            child: LinearProgressIndicator(
                              value: status.percent == 0
                                  ? null
                                  : status.percent / 100,
                              minHeight: 3,
                            ),
                          ),
                        ),
                      ],
                      if (phase != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(phase, style: small),
                        ),
                    ],
                  ),
                ),
                if (actions.isNotEmpty)
                  PopupMenuButton<_RowAction>(
                    key: ValueKey('offline-row-menu-${record?.id ?? row.job!.id}'),
                    tooltip: l10n.moreActions,
                    onSelected: onAction,
                    itemBuilder: (_) => [
                      for (final action in actions)
                        PopupMenuItem(value: action, child: Text(_label(action))),
                    ],
                  )
                else
                  const SizedBox(width: 12),
              ],
            ),
          ),
        );
      },
    );
  }
}

