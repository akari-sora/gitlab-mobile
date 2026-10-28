import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../core/models.dart';
import '../../core/offline/offline_repository_coordinator.dart';
import '../../core/offline/snapshot_save.dart';
import '../../core/offline/snapshot_schema.dart';
import '../../core/repository_reader.dart';
import '../../l10n/l10n.dart';
import '../../shared/artifact_storage.dart' show formatByteCount;
import '../../shared/theme.dart';
import '../../shared/workspace_ui.dart';
import 'offline_repositories.dart';

/// The signed-in account's offline repositories, for every screen and pushed
/// route of one authenticated generation. Absent (null) where offline saving
/// does not exist, such as tests that do not provide it.
class OfflineScope extends InheritedNotifier<OfflineRepositories> {
  const OfflineScope({
    super.key,
    required OfflineRepositories repositories,
    required this.account,
    required super.child,
  }) : super(notifier: repositories);

  /// The account the snapshots belong to (its `@username` is shown in texts).
  final Account account;

  static OfflineScope? _scope(BuildContext context, bool listen) => listen
      ? context.dependOnInheritedWidgetOfExactType<OfflineScope>()
      : context.getInheritedWidgetOfExactType<OfflineScope>();

  static OfflineRepositories? maybeOf(
    BuildContext context, {
    bool listen = true,
  }) => _scope(context, listen)?.notifier;

  static Account? accountOf(BuildContext context) =>
      _scope(context, false)?.account;
}

/// Complete snapshots of [projectId], newest first.
List<SnapshotRecord> completeSnapshotsOf(
  OfflineRepositories repositories,
  int projectId,
) {
  final list = [
    for (final s in repositories.snapshots)
      if (s.projectId == projectId && s.status == SnapshotStatus.complete) s,
  ]..sort((a, b) => (b.savedAt ?? b.createdAt).compareTo(a.savedAt ?? a.createdAt));
  return list;
}

/// Every snapshot of the account, including unfinished ones, by project.
List<SnapshotRecord> snapshotsOfProject(
  OfflineRepositories repositories,
  int projectId,
) => [
  for (final s in repositories.snapshots)
    if (s.projectId == projectId) s,
];

/// The job that is saving or queued for [projectId], if any.
SnapshotSaveJob? jobOfProject(OfflineRepositories repositories, int projectId) {
  final active = repositories.activeJob;
  if (active != null && active.request.projectId == projectId) return active;
  for (final job in repositories.queuedJobs) {
    if (job.request.projectId == projectId) return job;
  }
  return null;
}

/// The job that belongs to [record] (resumed or updating it), if any.
SnapshotSaveJob? jobOfRecord(
  OfflineRepositories repositories,
  SnapshotRecord record,
) {
  for (final job in [?repositories.activeJob, ...repositories.queuedJobs]) {
    if (job.id == record.id || job.snapshot?.id == record.id) return job;
  }
  return null;
}

int notSavedCount(SnapshotRecord record) =>
    record.notSaved.values.fold(0, (sum, value) => sum + value);

/// A whole-number percent for the progress of [job], 0 before downloading.
int jobPercent(SnapshotSaveJob job) {
  final progress = job.progress;
  if (progress == null || progress.totalBlobPaths <= 0) {
    return job.phase == SnapshotJobPhase.finalizing ? 100 : 0;
  }
  return (progress.processedPaths * 100 ~/ progress.totalBlobPaths).clamp(0, 100);
}

/// The text for a save failure: a complete sentence, also used as a reason.
String snapshotFailureText(SnapshotFailure failure) => switch (failure) {
  SnapshotFailure.tooManyEntries => l10n.snapshotFailureTooManyEntries,
  SnapshotFailure.treeTooLarge => l10n.snapshotFailureTreeTooLarge,
  SnapshotFailure.indexTooLarge => l10n.snapshotFailureIndexTooLarge,
  SnapshotFailure.archiveTooLarge => l10n.snapshotFailureArchiveTooLarge,
  SnapshotFailure.storageFull => l10n.snapshotFailureStorageFull,
  SnapshotFailure.deviceFull => l10n.snapshotFailureDeviceFull,
  SnapshotFailure.storageError => l10n.snapshotFailureStorageError,
  SnapshotFailure.keyUnavailable => l10n.snapshotFailureKeyUnavailable,
  SnapshotFailure.offlineCacheDisabled => l10n.snapshotFailureCacheDisabled,
  SnapshotFailure.invalidTree => l10n.snapshotFailureInvalidTree,
  SnapshotFailure.corruptArchive => l10n.snapshotFailureCorruptArchive,
  SnapshotFailure.shaMismatch => l10n.snapshotFailureShaMismatch,
  SnapshotFailure.resolveFailed => l10n.snapshotFailureResolveFailed,
  SnapshotFailure.serverForbidsStorage => l10n.snapshotFailureServerForbids,
  SnapshotFailure.accessLost => l10n.snapshotFailureAccessLost,
  SnapshotFailure.versionGone => l10n.snapshotFailureVersionGone,
  SnapshotFailure.rateLimited => l10n.snapshotFailureRateLimited,
  SnapshotFailure.network => l10n.snapshotFailureNetwork,
  SnapshotFailure.sessionEnded => l10n.snapshotFailureSessionEnded,
};

/// A save or delete failure for [showFailure]; it never carries paths or
/// contents, only the typed reason.
final class SnapshotUiFailure implements UserFacingFailure {
  const SnapshotUiFailure(this.failure, {this.titleText});
  final SnapshotFailure failure;
  final String? titleText;
  @override
  String get title => titleText ?? l10n.snapshotSaveFailedTitle;
  @override
  String get detail => snapshotFailureText(failure);
}

/// The typed failure behind [error], for snapshot operations.
SnapshotFailure snapshotFailureOf(Object error) => switch (error) {
  SnapshotOperationException(:final failure) => failure,
  ApiFailure(kind: FailureKind.network || FailureKind.server) =>
    SnapshotFailure.network,
  ApiFailure(kind: FailureKind.rateLimited) => SnapshotFailure.rateLimited,
  ApiFailure(kind: FailureKind.forbidden || FailureKind.invisible) =>
    SnapshotFailure.accessLost,
  ApiFailure(kind: FailureKind.cancelled) => SnapshotFailure.sessionEnded,
  _ => SnapshotFailure.storageError,
};

/// Why an entry has no offline content, as a short label.
String notSavedReason(RepositoryEntryState state) => switch (state) {
  RepositoryEntryState.available => '',
  RepositoryEntryState.pending => l10n.snapshotNotSavedPending,
  RepositoryEntryState.tooLarge => l10n.snapshotNotSavedTooLarge,
  RepositoryEntryState.binary => l10n.snapshotNotSavedBinary,
  RepositoryEntryState.missing => l10n.snapshotNotSavedMissing,
  RepositoryEntryState.mismatch => l10n.snapshotNotSavedMismatch,
  RepositoryEntryState.symlink ||
  RepositoryEntryState.submodule => l10n.snapshotNotSavedLink,
  RepositoryEntryState.unsupportedType => l10n.snapshotNotSavedUnsupported,
};

/// A calendar date in the device's zone, for "saved on".
String snapshotDate(DateTime value) {
  final date = value.toLocal();
  return '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}';
}

/// "12 MB" style size.
String snapshotSize(int bytes) => formatByteCount(bytes);

String get snapshotLimitText => formatByteCount(snapshotAccountLimit);

/// What a row shows about one snapshot (§6.4). Every value is icon plus text.
enum SnapshotStatusKind {
  saved,
  savedPartial,
  saving,
  queued,
  waitingBudget,
  waitingRateLimit,
  paused,
  interrupted,
  failed,
  newer,
  branchGone,
  tagGone,
  commitGone,
}

final class SnapshotRowStatus {
  const SnapshotRowStatus(
    this.kind, {
    this.percent = 0,
    this.notSaved = 0,
    this.failure,
    this.retryAt,
    this.phase,
    this.receivedBytes = 0,
    this.page = 0,
  });
  final SnapshotStatusKind kind;
  final int percent, notSaved, receivedBytes, page;
  final SnapshotFailure? failure;
  final DateTime? retryAt;
  final SnapshotJobPhase? phase;

  bool get busy => const {
    SnapshotStatusKind.saving,
    SnapshotStatusKind.queued,
    SnapshotStatusKind.waitingBudget,
    SnapshotStatusKind.waitingRateLimit,
  }.contains(kind);

  bool get resumable => const {
    SnapshotStatusKind.paused,
    SnapshotStatusKind.interrupted,
    SnapshotStatusKind.failed,
  }.contains(kind);

  bool get complete => const {
    SnapshotStatusKind.saved,
    SnapshotStatusKind.savedPartial,
    SnapshotStatusKind.newer,
    SnapshotStatusKind.branchGone,
    SnapshotStatusKind.tagGone,
    SnapshotStatusKind.commitGone,
  }.contains(kind);
}

/// The status of a running or queued [job].
SnapshotRowStatus jobStatus(SnapshotSaveJob job) => switch (job.phase) {
  SnapshotJobPhase.queued => const SnapshotRowStatus(SnapshotStatusKind.queued),
  SnapshotJobPhase.waitingBudget => const SnapshotRowStatus(
    SnapshotStatusKind.waitingBudget,
  ),
  SnapshotJobPhase.waitingRateLimit => SnapshotRowStatus(
    SnapshotStatusKind.waitingRateLimit,
    retryAt: job.retryAt,
  ),
  SnapshotJobPhase.paused => const SnapshotRowStatus(SnapshotStatusKind.paused),
  SnapshotJobPhase.failed => SnapshotRowStatus(
    SnapshotStatusKind.failed,
    failure: job.failure ?? SnapshotFailure.storageError,
  ),
  _ => SnapshotRowStatus(
    SnapshotStatusKind.saving,
    percent: jobPercent(job),
    phase: job.phase,
    receivedBytes: job.progress?.receivedBytes ?? 0,
    page: job.page,
  ),
};

/// The status of [record], with its live [job] when one exists.
SnapshotRowStatus recordStatus(SnapshotRecord record, SnapshotSaveJob? job) {
  if (job != null &&
      !const {
        SnapshotJobPhase.complete,
        SnapshotJobPhase.cancelled,
        SnapshotJobPhase.alreadyCurrent,
      }.contains(job.phase)) {
    final status = jobStatus(job);
    // A job that ended keeps the record's own persisted state.
    if (status.kind != SnapshotStatusKind.paused &&
        status.kind != SnapshotStatusKind.failed) {
      return status;
    }
  }
  switch (record.status) {
    case SnapshotStatus.saving:
      // Saving with no job running means the save stopped (§4.6 recovery).
      return const SnapshotRowStatus(SnapshotStatusKind.interrupted);
    case SnapshotStatus.paused:
      return SnapshotRowStatus(
        record.interrupted
            ? SnapshotStatusKind.interrupted
            : SnapshotStatusKind.paused,
      );
    case SnapshotStatus.failed:
      return SnapshotRowStatus(
        SnapshotStatusKind.failed,
        failure: record.failure ?? SnapshotFailure.storageError,
      );
    case SnapshotStatus.complete:
    case SnapshotStatus.superseded:
      break;
  }
  final missing = notSavedCount(record);
  switch (record.probe) {
    case SnapshotProbe.commitGone:
      return SnapshotRowStatus(SnapshotStatusKind.commitGone, notSaved: missing);
    case SnapshotProbe.refGone:
      return SnapshotRowStatus(
        record.refKind == SnapshotRefKind.tag
            ? SnapshotStatusKind.tagGone
            : SnapshotStatusKind.branchGone,
        notSaved: missing,
      );
    case SnapshotProbe.ok:
    case null:
      break;
  }
  final head = record.headSha;
  if (head != null && head.isNotEmpty && head != record.sha) {
    return SnapshotRowStatus(SnapshotStatusKind.newer, notSaved: missing);
  }
  return missing > 0
      ? SnapshotRowStatus(SnapshotStatusKind.savedPartial, notSaved: missing)
      : const SnapshotRowStatus(SnapshotStatusKind.saved);
}

/// Minutes until [retryAt], only when it is known (never a guess).
int? minutesUntil(DateTime? retryAt, {DateTime? now}) {
  if (retryAt == null) return null;
  final left = retryAt.difference(now ?? DateTime.now());
  if (left.isNegative) return null;
  return (left.inSeconds / 60).ceil().clamp(1, 24 * 60);
}

/// The label of [status], icon included.
(IconData, String) snapshotStatusLabel(SnapshotRowStatus status) =>
    switch (status.kind) {
      SnapshotStatusKind.saved => (
        Icons.offline_pin_outlined,
        l10n.snapshotStatusSaved,
      ),
      SnapshotStatusKind.savedPartial => (
        Icons.offline_pin_outlined,
        l10n.snapshotStatusSavedPartial(status.notSaved),
      ),
      SnapshotStatusKind.saving => (
        Icons.downloading_outlined,
        l10n.snapshotStatusSaving(status.percent),
      ),
      SnapshotStatusKind.queued => (
        Icons.schedule,
        l10n.snapshotStatusQueued,
      ),
      SnapshotStatusKind.waitingBudget => (
        Icons.hourglass_empty,
        l10n.snapshotStatusWaitingBudget,
      ),
      SnapshotStatusKind.waitingRateLimit => (
        Icons.speed,
        l10n.snapshotStatusWaitingRateLimit,
      ),
      SnapshotStatusKind.paused => (
        Icons.pause_circle_outline,
        l10n.snapshotStatusPaused,
      ),
      SnapshotStatusKind.interrupted => (
        Icons.sync_problem,
        l10n.snapshotStatusInterrupted,
      ),
      SnapshotStatusKind.failed => (
        Icons.error_outline,
        l10n.snapshotStatusFailed(
          snapshotFailureText(status.failure ?? SnapshotFailure.storageError),
        ),
      ),
      SnapshotStatusKind.newer => (
        Icons.update,
        l10n.snapshotStatusNewer,
      ),
      SnapshotStatusKind.branchGone => (
        Icons.link_off,
        l10n.snapshotStatusBranchGone,
      ),
      SnapshotStatusKind.tagGone => (
        Icons.link_off,
        l10n.snapshotStatusTagGone,
      ),
      SnapshotStatusKind.commitGone => (
        Icons.link_off,
        l10n.snapshotStatusCommitGone,
      ),
    };

/// The step a running save is on, for the line under its progress bar.
String? snapshotPhaseText(SnapshotRowStatus status) {
  if (status.kind == SnapshotStatusKind.waitingRateLimit) {
    final minutes = minutesUntil(status.retryAt);
    return minutes == null ? null : l10n.snapshotRateLimitEta(minutes);
  }
  if (status.kind != SnapshotStatusKind.saving) return null;
  return switch (status.phase) {
    SnapshotJobPhase.resolving => l10n.snapshotPhaseResolving,
    SnapshotJobPhase.listing => l10n.snapshotPhaseListing(
      status.page < 1 ? 1 : status.page,
    ),
    SnapshotJobPhase.downloading => l10n.snapshotPhaseDownloading(
      formatByteCount(status.receivedBytes),
    ),
    SnapshotJobPhase.finalizing => l10n.snapshotPhaseFinalizing,
    _ => null,
  };
}

/// A compact status pill: icon plus label, tinted like [StatusBadge]. The tint
/// is never the only signal.
class SnapshotStatusChip extends StatelessWidget {
  const SnapshotStatusChip(this.status, {super.key});
  final SnapshotRowStatus status;

  @override
  Widget build(BuildContext context) {
    final (icon, label) = snapshotStatusLabel(status);
    final scheme = Theme.of(context).colorScheme;
    final workshop = WorkshopColors.of(context);
    final (background, foreground) = switch (status.kind) {
      SnapshotStatusKind.saved => (
        workshop.successContainer,
        workshop.onSuccessContainer,
      ),
      SnapshotStatusKind.saving => (
        workshop.runningContainer,
        workshop.onRunningContainer,
      ),
      SnapshotStatusKind.savedPartial ||
      SnapshotStatusKind.queued ||
      SnapshotStatusKind.waitingBudget ||
      SnapshotStatusKind.waitingRateLimit ||
      SnapshotStatusKind.paused ||
      SnapshotStatusKind.interrupted => (
        workshop.pendingContainer,
        workshop.onPendingContainer,
      ),
      SnapshotStatusKind.failed ||
      SnapshotStatusKind.branchGone ||
      SnapshotStatusKind.tagGone ||
      SnapshotStatusKind.commitGone => (
        scheme.errorContainer,
        scheme.onErrorContainer,
      ),
      SnapshotStatusKind.newer => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
    };
    return MergeSemantics(
      child: Container(
        key: ValueKey('snapshot-status-${status.kind.name}'),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(7),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: ExcludeSemantics(
                child: Icon(icon, size: 13, color: foreground),
              ),
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                maxLines: status.kind == SnapshotStatusKind.failed ? 3 : 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: foreground),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// An inline notice in the shared failure style (icon, title, detail,
/// actions) for a snapshot condition that is not a GitLab response.
class OfflineNotice extends StatelessWidget {
  const OfflineNotice({
    super.key,
    required this.icon,
    required this.title,
    this.detail,
    this.actions = const [],
    this.error = false,
  });
  final IconData icon;
  final String title;
  final String? detail;
  final List<Widget> actions;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = error ? theme.colorScheme.error : theme.colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 20, color: color),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(title, style: theme.textTheme.titleSmall),
                  ),
                ],
              ),
              if (detail != null && detail!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(detail!),
              ],
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 4),
                Wrap(spacing: 8, children: actions),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Whether the account's offline storage can show anything at all.
bool offlineReadable(OfflineRepositoryState state) => const {
  OfflineRepositoryState.ready,
  OfflineRepositoryState.offlineReadOnly,
}.contains(state);

/// The account-wide condition that blocks saving, or null when none does.
/// Returns the reason text shown next to the disabled button.
String? offlineAccountBlocker(OfflineRepositories repositories) {
  final failure = repositories.failure;
  switch (repositories.state) {
    case OfflineRepositoryState.ready:
      break;
    case OfflineRepositoryState.unavailable:
      return l10n.snapshotFailureKeyUnavailable;
    case OfflineRepositoryState.needsNewerApp:
      return l10n.saveBlockedNewerApp;
    case OfflineRepositoryState.cleaning:
      return l10n.saveBlockedCleaning;
    case OfflineRepositoryState.closed:
    case OfflineRepositoryState.offlineReadOnly:
      return l10n.offlineCacheStatusWaiting;
  }
  if (failure == SnapshotFailure.keyUnavailable) {
    return l10n.snapshotFailureKeyUnavailable;
  }
  if (failure == SnapshotFailure.offlineCacheDisabled) {
    return l10n.snapshotFailureCacheDisabled;
  }
  return null;
}

/// The shared failure surface for snapshot operations.
void showSnapshotFailure(BuildContext context, Object error) =>
    showFailure(context, SnapshotUiFailure(snapshotFailureOf(error)));

/// How many offline projects leaving the session would delete: saved ones
/// plus new saves still queued or running.
int offlineProjectsAtRisk(OfflineRepositories repositories) {
  final known = {for (final record in repositories.snapshots) record.id};
  var count = known.length;
  for (final job in [?repositories.activeJob, ...repositories.queuedJobs]) {
    if (!known.contains(job.id) && !known.contains(job.snapshot?.id)) count++;
  }
  return count;
}

/// The D1 confirmation before any way out of the session (§6.7). It comes
/// before the AI guard and before anything stops, clears or changes the
/// session; with no offline projects it asks nothing.
Future<bool> confirmOfflineLoss(
  BuildContext context, {
  required OfflineRepositories? repositories,
  required Account account,
  required LeaveKind kind,
}) async {
  if (repositories == null) return true;
  final count = offlineProjectsAtRisk(repositories);
  if (count == 0) return true;
  final size = snapshotSize(repositories.usedBytes);
  final username = account.user.username;
  final detail = switch (kind) {
    LeaveKind.switchAccount => l10n.offlineLossSwitch(username, count, size),
    LeaveKind.signOut => l10n.offlineLossSignOut(username, count, size),
    LeaveKind.remove => l10n.offlineLossRemove(username, count, size),
  };
  return confirmAction(
    context,
    l10n.offlineLossTitle,
    detail,
    confirmLabel: l10n.offlineLossProceed,
  );
}
