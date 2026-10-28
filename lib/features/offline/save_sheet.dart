import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/offline/snapshot_save.dart';
import '../../core/offline/snapshot_schema.dart';
import '../../core/providers.dart';
import '../../core/rate_budget.dart';
import '../cache/read_cache_settings_store.dart';
import '../../core/repository_ref.dart';
import '../../l10n/l10n.dart';
import '../../shared/theme.dart';
import '../../shared/workspace_ui.dart';
import 'offline_consent_dialog.dart';
import 'offline_repositories.dart';
import 'offline_status.dart';

/// Consent given in this process before the account's index existed, so the
/// sheet does not ask twice while its first save is still queued.
final _pendingConsent = Expando<DateTime>();

/// The device's offline-cache switch is off (C2's setting).
bool offlineCacheSwitchedOff(BuildContext context) {
  try {
    final session = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(sessionProvider);
    return session.readCache.setting == ReadCacheSettingsState.disabled;
  } on Object {
    return false;
  }
}

/// The save entry for [project] (§6.2–§6.3): the explainer on the account's
/// first save, then the sheet. [folder] preselects "this folder".
Future<void> openOfflineSaveSheet(
  BuildContext context, {
  required OfflineRepositories repositories,
  required Account account,
  required Project project,
  RepositoryRef? ref,
  String folder = '',
  void Function(SnapshotRecord record)? onOpen,
  bool repair = false,
}) async {
  var consent = repositories.consentAt ?? _pendingConsent[repositories];
  final hasSnapshots = repositories.snapshots.isNotEmpty;
  if (consent == null && !hasSnapshots) {
    consent = await showOfflineConsent(
      context,
      username: account.user.username,
    );
    if (consent == null || !context.mounted) return;
    _pendingConsent[repositories] = consent;
  }
  final switchedOff = offlineCacheSwitchedOff(context);
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => OfflineSaveSheet(
      repositories: repositories,
      account: account,
      project: project,
      reference: ref,
      folder: folder,
      consentAt: consent ?? DateTime.now().toUtc(),
      cacheSwitchedOff: switchedOff,
      onOpen: onOpen,
      messenger: ScaffoldMessenger.maybeOf(context),
      repair: repair,
    ),
  );
}

/// The end of a save started from a sheet or the offline projects list,
/// told where the user is now (the starting surface may be gone): already
/// up to date, or why it failed. Asynchronous failures are never silent.
Future<void> reportSaveJob(
  SnapshotSaveJob job,
  ScaffoldMessengerState? messenger,
) async {
  await job.completion;
  if (messenger == null || !messenger.mounted) return;
  switch (job.phase) {
    case SnapshotJobPhase.alreadyCurrent:
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.saveSheetAlreadyCurrent)),
      );
    case SnapshotJobPhase.failed:
      final failure = SnapshotUiFailure(
        job.failure ?? SnapshotFailure.storageError,
      );
      messenger.showSnackBar(
        SnackBar(content: Text('${failure.title}: ${failure.detail}')),
      );
    default:
      break;
  }
}

/// What the sheet's primary action does.
enum _SaveAction { save, update, current, saving }

class OfflineSaveSheet extends StatefulWidget {
  const OfflineSaveSheet({
    super.key,
    required this.repositories,
    required this.account,
    required this.project,
    required this.consentAt,
    this.reference,
    this.folder = '',
    this.cacheSwitchedOff = false,
    this.onOpen,
    this.messenger,
    this.now,
    this.repair = false,
  });

  final OfflineRepositories repositories;
  final Account account;
  final Project project;
  final RepositoryRef? reference;
  final String folder;
  final DateTime consentAt;
  final bool cacheSwitchedOff;
  final void Function(SnapshotRecord record)? onOpen;
  final ScaffoldMessengerState? messenger;
  final DateTime Function()? now;

  /// Opened from a damaged offline version (重新保存): saving the same commit
  /// again is the repair, so "already up to date" never blocks it. The core
  /// re-reads the stored copy and rebuilds what it cannot read.
  final bool repair;

  @override
  State<OfflineSaveSheet> createState() => _OfflineSaveSheetState();
}

class _OfflineSaveSheetState extends State<OfflineSaveSheet> {
  late bool _folderScope = widget.folder.isNotEmpty;
  bool _starting = false;
  StreamSubscription<Object?>? _rates, _runs;
  bool _budgetRebuild = false;

  OfflineRepositories get _repos => widget.repositories;

  @override
  void initState() {
    super.initState();
    // The rate-limit and request-budget blockers come from the API's budgets,
    // which the adapter does not forward: follow them while the sheet is open.
    final api = _repos.api;
    if (api != null) {
      _rates = api.rateBudget.stream.listen((_) => _budgetChanged());
      _runs = api.runBudget.changes.listen((_) => _budgetChanged());
    }
  }

  /// Reading a budget during build can publish synchronously; rebuild once,
  /// after the current frame's work.
  void _budgetChanged() {
    if (_budgetRebuild) return;
    _budgetRebuild = true;
    scheduleMicrotask(() {
      _budgetRebuild = false;
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_rates?.cancel());
    unawaited(_runs?.cancel());
    super.dispose();
  }

  String get _subPath => _folderScope ? widget.folder : '';

  SnapshotRefKind get _refKind =>
      widget.reference?.kind == RepositoryRefKind.tag
      ? SnapshotRefKind.tag
      : SnapshotRefKind.branch;

  String get _refName {
    final ref = widget.reference;
    if (ref != null && ref.kind != RepositoryRefKind.commit && ref.name.isNotEmpty) {
      return ref.name;
    }
    return widget.project.defaultBranch ?? '';
  }

  String get _knownSha {
    final ref = widget.reference;
    return ref != null && ref.kind != RepositoryRefKind.commit ? ref.sha : '';
  }

  /// The saved copy of this project, ref and scope, if any.
  SnapshotRecord? get _existing {
    for (final record in snapshotsOfProject(_repos, widget.project.id)) {
      if (record.refKind == _refKind &&
          record.refName == _refName &&
          record.subPath == _subPath) {
        return record;
      }
    }
    return null;
  }

  SnapshotSaveJob? get _job {
    final job = jobOfProject(_repos, widget.project.id);
    if (job == null) return null;
    return job.request.refName == _refName && job.request.subPath == _subPath
        ? job
        : null;
  }

  _SaveAction get _action {
    if (_job != null) return _SaveAction.saving;
    final existing = _existing;
    if (existing == null || existing.status != SnapshotStatus.complete) {
      return _SaveAction.save;
    }
    if (widget.repair) return _SaveAction.update;
    final sha = _knownSha.isNotEmpty ? _knownSha : existing.headSha;
    if (sha != null && sha.isNotEmpty && sha == existing.sha) {
      return _SaveAction.current;
    }
    return _SaveAction.update;
  }

  /// Why the primary action is disabled now, or null.
  String? get _blocker {
    if (widget.cacheSwitchedOff) return l10n.snapshotFailureCacheDisabled;
    final account = offlineAccountBlocker(_repos);
    if (account != null) return account;
    final api = _repos.api;
    if (api == null || !_repos.canSave) return l10n.snapshotFailureSessionEnded;
    if (_refName.isEmpty) return l10n.snapshotFailureResolveFailed;
    final rate = api.rateBudget;
    if (!rate.mayStart(RateRequestClass.global) ||
        !rate.mayStart(RateRequestClass.archive)) {
      final retryAt =
          rate.retryAtFor(RateRequestClass.global) ??
          rate.retryAtFor(RateRequestClass.archive);
      final minutes = minutesUntil(retryAt, now: widget.now?.call());
      return minutes == null
          ? l10n.snapshotFailureRateLimited
          : l10n.saveBlockedRateLimitedEta(minutes);
    }
    if (api.runBudget.activeLeases >= 3 ||
        rate.snapshot().level == RateLevel.critical) {
      return l10n.snapshotStatusWaitingBudget;
    }
    if (_repos.queuedJobs.length >= 5) return l10n.snapshotQueueFull;
    if (_action == _SaveAction.save &&
        _repos.snapshots.length >= snapshotCountLimit) {
      return l10n.saveBlockedCount;
    }
    if (_repos.usedBytes >= snapshotAccountLimit) {
      return l10n.snapshotFailureStorageFull;
    }
    return null;
  }

  Future<void> _start() async {
    if (_starting || _blocker != null) return;
    final existing = _existing;
    final update = _action == _SaveAction.update;
    final resume =
        existing != null &&
        (existing.status == SnapshotStatus.paused ||
            existing.status == SnapshotStatus.failed);
    final request = SnapshotSaveRequest(
      projectId: widget.project.id,
      projectPath: widget.project.path,
      projectName: widget.project.name,
      defaultBranch: widget.project.defaultBranch ?? _refName,
      refKind: _refKind,
      refName: _refName,
      consentAt: widget.consentAt,
      subPath: _subPath,
      replaces: update ? existing?.id : null,
    );
    setState(() => _starting = true);
    final messenger = widget.messenger;
    try {
      final job = _repos.save(request, resume: resume ? existing : null);
      messenger?.showSnackBar(SnackBar(content: Text(l10n.saveSheetStarted)));
      if (mounted) Navigator.of(context).pop();
      unawaited(reportSaveJob(job, messenger));
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _starting = false);
      showSnapshotFailure(context, error);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _repos,
    builder: (context, _) => _sheet(context),
  );

  Widget _sheet(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final blocker = _blocker;
    final action = _action;
    final existing = _existing;
    final job = _job;
    final sha = _knownSha;
    final used = _repos.usedBytes;
    final media = MediaQuery.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: media.size.height * 0.9),
        child: SingleChildScrollView(
          key: const ValueKey('offline-save-sheet'),
          padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + media.viewInsets.bottom),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.offlineSaveAction,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                isolated(widget.project.name),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(color: muted),
              ),
              const SizedBox(height: 16),
              _label(context, l10n.saveSheetVersion),
              _versionRow(context, sha),
              if (existing != null || job != null) ...[
                const SizedBox(height: 8),
                _existingBlock(context, existing, job),
              ],
              const SizedBox(height: 16),
              _label(context, l10n.saveSheetScope),
              _scopeOption(context, folder: false),
              if (widget.folder.isNotEmpty) _scopeOption(context, folder: true),
              const SizedBox(height: 8),
              _infoLine(context, Icons.description_outlined, l10n.saveSheetContents),
              _infoLine(
                context,
                Icons.person_outline,
                l10n.saveSheetAccountNote(widget.account.user.username),
                trailing: TextButton(
                  key: const ValueKey('offline-save-details'),
                  onPressed: () => unawaited(
                    showOfflineConsent(
                      context,
                      username: widget.account.user.username,
                      forSave: false,
                    ),
                  ),
                  child: Text(l10n.saveSheetDetails),
                ),
              ),
              const SizedBox(height: 12),
              _capacity(context, used),
              if (blocker != null && action != _SaveAction.saving) ...[
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: Row(
                    key: const ValueKey('offline-save-blocker'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.block, size: 18, color: theme.colorScheme.error),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          blocker,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              _primary(context, action, blocker, existing),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  Widget _versionRow(BuildContext context, String sha) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(
          _refKind == SnapshotRefKind.tag ? Icons.label_outline : Icons.alt_route,
          size: 18,
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            isolated(_refName),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyLarge,
          ),
        ),
        if (sha.isNotEmpty) ...[
          const SizedBox(width: 6),
          Text(
            '@ ${RepositoryRef.shortSha(sha)}',
            textDirection: TextDirection.ltr,
            style: codeTextStyle(
              context,
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  Widget _existingBlock(
    BuildContext context,
    SnapshotRecord? existing,
    SnapshotSaveJob? job,
  ) {
    final theme = Theme.of(context);
    final status = existing != null
        ? recordStatus(existing, job ?? jobOfRecord(_repos, existing))
        : jobStatus(job!);
    final phase = snapshotPhaseText(status);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SnapshotStatusChip(status),
            if (existing?.savedAt case final saved?)
              Text(
                l10n.offlineRowSavedAt(relativeTime(saved)),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        if (status.kind == SnapshotStatusKind.saving) ...[
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: status.percent == 0 ? null : status.percent / 100,
            minHeight: 3,
          ),
        ],
        if (phase != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(phase, style: theme.textTheme.bodySmall),
          ),
      ],
    );
  }

  Widget _scopeOption(BuildContext context, {required bool folder}) {
    final selected = _folderScope == folder;
    return MergeSemantics(
      child: ListTile(
        key: ValueKey(folder ? 'offline-scope-folder' : 'offline-scope-all'),
        contentPadding: EdgeInsets.zero,
        dense: false,
        onTap: () => setState(() => _folderScope = folder),
        leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: selected ? Theme.of(context).colorScheme.primary : null,
        ),
        title: Text(
          folder ? l10n.saveSheetThisFolder : l10n.saveSheetWholeRepository,
        ),
        subtitle: folder
            ? Text(
                isolated(widget.folder),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              )
            : null,
        selected: selected,
      ),
    );
  }

  Widget _infoLine(
    BuildContext context,
    IconData icon,
    String text, {
    Widget? trailing,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: theme.textTheme.bodyMedium),
                ?trailing,
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _capacity(BuildContext context, int used) {
    final theme = Theme.of(context);
    final ratio = (used / snapshotAccountLimit).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.saveSheetCapacity(snapshotSize(used), snapshotLimitText),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 4,
            semanticsLabel: l10n.saveSheetCapacity(
              snapshotSize(used),
              snapshotLimitText,
            ),
          ),
        ),
      ],
    );
  }

  Widget _primary(
    BuildContext context,
    _SaveAction action,
    String? blocker,
    SnapshotRecord? existing,
  ) {
    final open = existing != null &&
            existing.status == SnapshotStatus.complete &&
            widget.onOpen != null
        ? OutlinedButton.icon(
            key: const ValueKey('offline-save-open'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () {
              Navigator.of(context).pop();
              widget.onOpen!(existing);
            },
            icon: const Icon(Icons.offline_pin_outlined),
            label: Text(l10n.saveSheetOpen),
          )
        : null;
    final Widget? main = switch (action) {
      _SaveAction.saving => null,
      _SaveAction.current => Text(
        l10n.saveSheetAlreadyCurrent,
        key: const ValueKey('offline-save-current'),
        textAlign: TextAlign.center,
      ),
      _SaveAction.save || _SaveAction.update => FilledButton.icon(
        key: const ValueKey('offline-save-start'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        onPressed: blocker != null || _starting ? null : () => unawaited(_start()),
        icon: Icon(
          action == _SaveAction.update
              ? Icons.update
              : Icons.download_for_offline_outlined,
        ),
        label: Text(
          action != _SaveAction.update
              ? l10n.saveSheetStart
              : widget.repair
              ? l10n.snapshotResave
              : l10n.saveSheetUpdate,
        ),
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?main,
        if (main != null && open != null) const SizedBox(height: 8),
        ?open,
      ],
    );
  }
}


/// What the repository toolbar button shows (§6.2).
enum OfflineRefButtonState { none, saving, saved, newer }

/// The toolbar button on the Files tab's ref row: save offline, saving n%,
/// saved (with the unsaved count) or a newer commit. Absent without an
/// offline scope, so screens without offline support are unchanged.
class OfflineRefButton extends StatelessWidget {
  const OfflineRefButton({
    super.key,
    required this.account,
    required this.project,
    required this.reference,
    this.folder = '',
    this.onOpen,
  });

  final Account account;
  final Project project;
  final RepositoryRef reference;
  final String folder;
  final void Function(SnapshotRecord record)? onOpen;

  @override
  Widget build(BuildContext context) {
    final repositories = OfflineScope.maybeOf(context);
    if (repositories == null) return const SizedBox.shrink();
    final kind = reference.kind == RepositoryRefKind.tag
        ? SnapshotRefKind.tag
        : SnapshotRefKind.branch;
    final job = jobOfProject(repositories, project.id);
    SnapshotRecord? saved;
    for (final record in completeSnapshotsOf(repositories, project.id)) {
      if (record.refKind == kind &&
          record.refName == reference.name &&
          (record.subPath.isEmpty ||
              folder == record.subPath ||
              folder.startsWith('${record.subPath}/'))) {
        saved ??= record;
      }
    }
    final (state, percent) = job != null
        ? (OfflineRefButtonState.saving, jobPercent(job))
        : saved == null
        ? (OfflineRefButtonState.none, 0)
        : reference.sha.isNotEmpty && reference.sha != saved.sha
        ? (OfflineRefButtonState.newer, 0)
        : (OfflineRefButtonState.saved, 0);
    final missing = saved == null ? 0 : notSavedCount(saved);
    final theme = Theme.of(context);
    final (tooltip, semantics) = switch (state) {
      OfflineRefButtonState.none => (l10n.offlineSaveAction, l10n.offlineSaveAction),
      OfflineRefButtonState.saving => (
        l10n.snapshotStatusSaving(percent),
        l10n.snapshotStatusSaving(percent ~/ 25 * 25),
      ),
      OfflineRefButtonState.saved => (
        l10n.offlineSavedChip,
        missing > 0 ? l10n.offlineSavedChipPartial(missing) : l10n.offlineSavedChip,
      ),
      OfflineRefButtonState.newer => (l10n.snapshotStatusNewer, l10n.snapshotStatusNewer),
    };
    final Widget icon = switch (state) {
      OfflineRefButtonState.none => const Icon(Icons.download_for_offline_outlined, size: 20),
      OfflineRefButtonState.saving => SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          value: percent == 0 ? null : percent / 100,
          strokeWidth: 2.5,
        ),
      ),
      OfflineRefButtonState.saved => Badge(
        isLabelVisible: missing > 0,
        label: Text('$missing'),
        child: Icon(
          Icons.offline_pin,
          size: 20,
          color: WorkshopColors.of(context).success,
        ),
      ),
      OfflineRefButtonState.newer => Badge(
        backgroundColor: theme.colorScheme.primary,
        smallSize: 8,
        child: const Icon(Icons.offline_pin_outlined, size: 20),
      ),
    };
    return Semantics(
      liveRegion: state == OfflineRefButtonState.saving,
      label: semantics,
      button: true,
      excludeSemantics: true,
      child: IconButton(
        key: ValueKey('repository-offline-button-${state.name}'),
        tooltip: tooltip,
        onPressed: () => unawaited(
          openOfflineSaveSheet(
            context,
            repositories: repositories,
            account: account,
            project: project,
            ref: reference,
            folder: folder,
            onOpen: onOpen,
          ),
        ),
        icon: icon,
      ),
    );
  }
}
