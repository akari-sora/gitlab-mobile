import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../../core/brand.dart';
import '../../core/failure.dart';
import '../../core/models.dart';
import '../../core/offline/offline_repository_coordinator.dart';
import '../../core/offline/snapshot_schema.dart';
import '../../core/read_cache_disk_contract.dart';
import '../../core/repository_ref.dart';
import '../../l10n/l10n.dart';
import '../../shared/hub_ui.dart';
import '../../shared/network_boundary.dart';
import '../../shared/theme.dart';
import '../../shared/workspace_ui.dart';
import '../auth/session_controller.dart';
import '../security/app_lock.dart';
import '../shell/appearance.dart';
import '../shell/incoming_links.dart';
import '../shell/language.dart';
import 'offline_gate.dart';
import 'offline_projects_page.dart';
import 'offline_repositories.dart';
import 'offline_status.dart';
import 'snapshot_browser_page.dart';

/// How the session is left outside the signed-in shell (§6.7).
enum RetainedLeave {
  /// Another saved account, "use another account" or leaving offline mode.
  switchAccount,

  /// Signing in with a token or GitLab authorization on the sign-in screen;
  /// the retained account loses its data only if another account signs in.
  connect,

  /// Removing the retained account itself.
  remove,
}

Account? _knownAccount(SessionController session, String key) {
  for (final account in [
    ...session.accounts,
    ?session.offline?.account,
    ?session.resumingAccount,
  ]) {
    if (account.key == key) return account;
  }
  return null;
}

/// The §6.7 confirmation where the signed-in shell (and its live
/// [OfflineRepositories]) does not exist: the resume screen, the sign-in
/// screen and the offline shell. It counts [accountKey]'s offline projects
/// straight from storage without opening anything
/// ([ReadCacheDiskCoordinator.offlineSnapshotSummary]). It asks nothing when
/// there are none; when their number cannot be read it still asks.
Future<bool> confirmRetainedOfflineLoss(
  BuildContext context,
  SessionController session, {
  required String accountKey,
  required RetainedLeave kind,
}) async {
  final account = _knownAccount(session, accountKey);
  if (account == null) return true;
  final summary = await session.readCache.offlineSnapshotSummary(accountKey);
  if (!context.mounted) return false;
  if (summary != null && summary.count == 0) return true;
  final username = account.user.username;
  final String detail;
  if (summary == null) {
    detail = kind == RetainedLeave.connect
        ? l10n.offlineLossConnectUnknown(username)
        : l10n.offlineLossUnknown(username);
  } else {
    final size = snapshotSize(summary.bytes);
    detail = switch (kind) {
      RetainedLeave.switchAccount => l10n.offlineLossSwitch(
        username,
        summary.count,
        size,
      ),
      RetainedLeave.connect => l10n.offlineLossConnect(
        username,
        summary.count,
        size,
      ),
      RetainedLeave.remove => l10n.offlineLossRemove(
        username,
        summary.count,
        size,
      ),
    };
  }
  return confirmAction(
    context,
    l10n.offlineLossTitle,
    detail,
    confirmLabel: l10n.offlineLossProceed,
  );
}

/// The first line of the offline banner (§6.8): why GitLab gave no identity
/// verdict. [reason] is null before GitLab has answered at all (an early
/// entry from the resume screen).
String offlineBannerText(ApiFailure? reason, DateTime now) {
  switch (reason?.kind) {
    case null:
      return l10n.offlineBannerChecking;
    case FailureKind.server:
      return l10n.offlineBannerServer;
    case FailureKind.rateLimited:
      final retryAt = reason!.retryAt;
      if (retryAt == null || !retryAt.isAfter(now)) {
        return l10n.offlineBannerRateLimited;
      }
      final seconds = retryAt.difference(now).inSeconds;
      final minutes = (seconds + 59) ~/ 60;
      return l10n.offlineBannerRateLimitedMinutes(minutes);
    case FailureKind.redirectBlocked || FailureKind.invalidResponse:
      return l10n.offlineBannerSignIn;
    case _:
      return l10n.offlineBannerNetwork;
  }
}

/// The offline read-only shell (§5.5, §5.8, §6.8). It exists only while
/// [SessionController.offline] is set and `main` keys it by that generation,
/// so leaving the mode drops every page it opened.
///
/// There is no account API client. The only content is the account's saved
/// snapshots, read through an [OfflineRepositories] without a client, below a
/// [NetworkBoundary] in [NetworkBoundaryMode.offlineSnapshot] and under the
/// same [AppLockController] as the signed-in app ([OfflineLockGate]). Links
/// from other apps stay queued in [incoming] for the next signed-in shell.
class OfflineApp extends StatefulWidget {
  const OfflineApp({
    super.key,
    required this.session,
    required this.appearance,
    required this.lock,
    this.language,
    this.incoming,
    this.coordinator,
  });

  final SessionController session;
  final AppearanceController appearance;

  /// The device app lock, the same controller the signed-in app uses.
  final AppLockController lock;

  /// The app's language; null uses the current one (tests).
  final LanguageController? language;

  /// Links handed over by other apps. Only read here, never taken.
  final IncomingLinks? incoming;

  /// The snapshot owner; null uses the one the session's read cache holds.
  final OfflineRepositoryCoordinator? coordinator;

  @override
  State<OfflineApp> createState() => _OfflineAppState();
}

class _OfflineAppState extends State<OfflineApp> {
  final _navigator = GlobalKey<NavigatorState>();
  final _messenger = GlobalKey<ScaffoldMessengerState>();

  /// The offline session this generation was built for.
  OfflineSession? _offline;
  OfflineRepositories? _repositories;
  bool _restoredAnnounced = false;

  /// The saved project being browsed, so "switch to online" opens its files.
  int? _browsing;

  SessionController get _session => widget.session;
  bool get _current =>
      mounted && _offline != null && identical(_session.offline, _offline);

  @override
  void initState() {
    super.initState();
    final offline = _offline = _session.offline;
    final coordinator =
        widget.coordinator ??
        _session.readCache.offlineRepository ??
        OfflineRepositoryCoordinator.instance;
    if (offline != null && coordinator.configured) {
      _repositories = OfflineRepositories(
        binding: DiskBinding(
          accountKey: offline.account.key,
          generation: offline.generation,
        ),
        coordinator: coordinator,
      );
    }
    _restoredAnnounced = offline?.connectionRestored ?? false;
    _session.addListener(_sessionChanged);
  }

  @override
  void dispose() {
    _session.removeListener(_sessionChanged);
    _repositories?.dispose();
    _repositories = null;
    super.dispose();
  }

  void _sessionChanged() {
    final offline = _offline;
    if (!_current || offline == null) return;
    if (!offline.connectionRestored) {
      _restoredAnnounced = false;
      return;
    }
    if (_restoredAnnounced) return;
    _restoredAnnounced = true;
    // The banner says it too, but only on the first page; this reaches the
    // page being read.
    _messenger.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const ValueKey('offline-restored-snack'),
          content: Text(l10n.offlineBannerRestored),
          duration: const Duration(seconds: 8),
          action: SnackBarAction(
            label: l10n.offlineSwitchOnline,
            onPressed: () => unawaited(_goOnline()),
          ),
        ),
      );
  }

  /// "Retry connection" and "switch to online" both ask GitLab again and go
  /// online only when it confirms this account (§5.6).
  Future<void> _goOnline() async {
    final offline = _offline;
    if (!_current || offline == null) return;
    await _session.probeOffline(switchOnline: true, projectId: _browsing);
    if (!_current || offline.connectionRestored) return;
    _messenger.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(l10n.offlineStillOffline)));
  }

  Future<void> _open(SnapshotRecord record, BuildContext context) async {
    final repositories = _repositories;
    final offline = _offline;
    if (repositories == null || offline == null) return;
    _browsing = record.projectId;
    try {
      await openSnapshot(
        context,
        repositories: repositories,
        record: record,
        account: offline.account,
      );
    } finally {
      if (_browsing == record.projectId) _browsing = null;
    }
  }

  void _manage(BuildContext context) {
    final repositories = _repositories;
    final offline = _offline;
    if (repositories == null || offline == null) return;
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => OfflineProjectsPage(
            repositories: repositories,
            account: offline.account,
          ),
        ),
      ),
    );
  }

  /// Every way out of the account, from any page: the offline-projects loss
  /// first (§6.7); nothing else runs here, there is no AI.
  Future<void> _leave(
    LeaveIntent intent,
    Future<void> Function() action,
  ) async {
    final offline = _offline;
    final context = _navigator.currentContext;
    if (!_current || offline == null || context == null) return;
    final confirmed = await confirmRetainedOfflineLoss(
      context,
      _session,
      accountKey: offline.account.key,
      kind: intent.kind == LeaveKind.remove
          ? RetainedLeave.remove
          : RetainedLeave.switchAccount,
    );
    if (!confirmed || !_current) return;
    await action();
  }

  @override
  Widget build(BuildContext context) {
    final offline = _offline;
    if (offline == null) return const SizedBox.shrink();
    final repositories = _repositories;
    Widget app = ListenableBuilder(
      listenable: widget.appearance,
      builder: (context, _) => DynamicColorBuilder(
        builder: (light, dark) {
          final useDynamic = widget.appearance.useDynamicColor;
          return MaterialApp(
            navigatorKey: _navigator,
            scaffoldMessengerKey: _messenger,
            title: appName,
            debugShowCheckedModeBanner: false,
            // Above the navigator, so every page opened here is covered.
            builder: (context, child) => OfflineLockGate(
              lock: widget.lock,
              child: applySystemBars(context, child),
            ),
            theme: appTheme(
              Brightness.light,
              dynamicScheme: useDynamic ? flutterScheme(light) : null,
            ),
            darkTheme: appTheme(
              Brightness.dark,
              dynamicScheme: useDynamic ? flutterScheme(dark) : null,
            ),
            themeMode: widget.appearance.mode,
            locale: widget.language?.locale ?? localeOf(l10n.language),
            supportedLocales: appLocales,
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: _OfflineHome(
              session: _session,
              offline: offline,
              repositories: repositories,
              incoming: widget.incoming,
              goOnline: _goOnline,
              open: _open,
              manage: _manage,
              useAnotherAccount: () => unawaited(
                _leave(
                  const LeaveIntent(LeaveKind.switchAccount),
                  _session.endSession,
                ),
              ),
            ),
          );
        },
      ),
    );
    if (repositories != null) {
      app = OfflineScope(
        repositories: repositories,
        account: offline.account,
        child: app,
      );
    }
    return SessionLeaveScope(
      leave: _leave,
      child: NetworkBoundary(
        mode: NetworkBoundaryMode.offlineSnapshot,
        child: app,
      ),
    );
  }
}

/// The app lock over the offline shell (§5.9): the signed-in app's
/// [AppLockGate], plus a cover for [AppLockController.offlineCovering]. Until
/// the lock's setting has been read successfully nothing below is shown,
/// reachable by touch or read out; a failed read offers a retry. The covers
/// are screen masks: what was already decrypted stays in memory below them.
class OfflineLockGate extends StatelessWidget {
  const OfflineLockGate({super.key, required this.lock, required this.child});

  final AppLockController lock;
  final Widget child;

  @override
  Widget build(BuildContext context) => AppLockGate(
    controller: lock,
    child: ListenableBuilder(
      listenable: lock,
      child: child,
      builder: (context, child) {
        final covered = lock.offlineCovering;
        return Stack(
          fit: StackFit.expand,
          children: [
            ExcludeSemantics(
              excluding: covered,
              child: IgnorePointer(ignoring: covered, child: child),
            ),
            if (lock.loaded && lock.loadFailed)
              _LockUnreadable(onRetry: () => unawaited(lock.reload())),
          ],
        );
      },
    ),
  );
}

class _LockUnreadable extends StatelessWidget {
  const _LockUnreadable({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ColoredBox(
      key: const ValueKey('offline-lock-unreadable'),
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: scheme.errorContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Icon(
                    Icons.lock_outline,
                    size: 32,
                    color: scheme.onErrorContainer,
                  ),
                ),
                const SizedBox(height: 20),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    l10n.offlineLockUnreadableTitle,
                    style: theme.textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.offlineLockUnreadableDetail,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  key: const ValueKey('offline-lock-retry'),
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.retryAction),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _MenuAction { manage, useAnotherAccount }

/// The offline shell's only page of its own (§6.8): the banner, the account,
/// the saved projects. No bottom navigation, search or AI.
class _OfflineHome extends StatelessWidget {
  const _OfflineHome({
    required this.session,
    required this.offline,
    required this.repositories,
    required this.incoming,
    required this.goOnline,
    required this.open,
    required this.manage,
    required this.useAnotherAccount,
  });

  final SessionController session;
  final OfflineSession offline;
  final OfflineRepositories? repositories;
  final IncomingLinks? incoming;
  final Future<void> Function() goOnline;
  final Future<void> Function(SnapshotRecord, BuildContext) open;
  final void Function(BuildContext) manage;
  final VoidCallback useAnotherAccount;

  @override
  Widget build(BuildContext context) {
    final repositories = this.repositories;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.offlineShellTitle),
        actions: [
          PopupMenuButton<_MenuAction>(
            key: const ValueKey('offline-shell-menu'),
            tooltip: l10n.moreActions,
            onSelected: (action) => switch (action) {
              _MenuAction.manage => manage(context),
              _MenuAction.useAnotherAccount => useAnotherAccount(),
            },
            itemBuilder: (_) => [
              if (repositories != null)
                PopupMenuItem(
                  value: _MenuAction.manage,
                  child: Text(l10n.offlineManageProjects),
                ),
              PopupMenuItem(
                value: _MenuAction.useAnotherAccount,
                child: Text(l10n.useAnotherAccount),
              ),
            ],
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([session, ?repositories, ?incoming]),
        builder: (context, _) => ListView(
          key: const ValueKey('offline-shell-list'),
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            OfflineBanner(
              reason: offline.reason,
              restored: offline.connectionRestored,
              probing: session.offlineProbing,
              now: DateTime.now(),
              onPressed: () => unawaited(goOnline()),
            ),
            if (incoming?.pending != null) const _PendingLink(),
            _AccountTile(
              account: offline.account,
              validatedAt: offline.lastValidatedAt,
            ),
            ..._projects(context, repositories),
          ],
        ),
      ),
    );
  }

  List<Widget> _projects(
    BuildContext context,
    OfflineRepositories? repositories,
  ) {
    if (repositories == null) {
      return [
        OfflineNotice(
          key: const ValueKey('offline-shell-unavailable'),
          icon: Icons.error_outline,
          error: true,
          title: l10n.snapshotFailureStorageError,
        ),
      ];
    }
    final saved = [
      for (final record in repositories.snapshots)
        if (record.status == SnapshotStatus.complete) record,
    ];
    final failure = repositories.failure;
    final blocked = !offlineReadable(repositories.state) || failure != null;
    return [
      if (repositories.loading && saved.isEmpty)
        const LinearProgressIndicator(minHeight: 2),
      if (blocked && !repositories.loading)
        OfflineNotice(
          key: const ValueKey('offline-shell-blocked'),
          icon: Icons.error_outline,
          error: true,
          title: failure == null
              ? offlineAccountBlocker(repositories) ??
                    l10n.snapshotFailureStorageError
              : snapshotFailureText(failure),
          actions: [
            TextButton.icon(
              onPressed: () => unawaited(repositories.refresh()),
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(l10n.refreshAction),
            ),
          ],
        ),
      if (saved.isEmpty && !repositories.loading && !blocked)
        EmptyState(
          l10n.offlineNothingToBrowse,
          key: const ValueKey('offline-shell-empty'),
          detail: l10n.offlineNothingToBrowseDetail,
          icon: Icons.download_for_offline_outlined,
        ),
      if (saved.isNotEmpty)
        HubSection(
          title: l10n.offlineSavedProjectsTitle,
          children: [
            for (var i = 0; i < saved.length; i++) ...[
              if (i > 0) const Divider(height: 1, indent: 62),
              _SavedProjectTile(
                record: saved[i],
                onTap: () => unawaited(open(saved[i], context)),
              ),
            ],
          ],
        ),
      HubSection(
        children: [
          HubRow(
            key: const ValueKey('offline-shell-manage'),
            leading: const IconTile(
              Icons.download_for_offline_outlined,
              color: HubColors.green,
            ),
            title: l10n.offlineManageProjects,
            value: l10n.offlineProjectsSummary(
              repositories.snapshots.length,
              snapshotSize(repositories.usedBytes),
            ),
            chevron: true,
            onTap: () => manage(context),
          ),
        ],
      ),
    ];
  }
}

/// The offline banner (§6.8): why the app is offline and the way back. Three
/// states: offline with "retry connection", checking (spinner, disabled) and
/// restored with "switch to online". Below 360 dp the button moves under the
/// text (§6.10).
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({
    super.key,
    required this.reason,
    required this.restored,
    required this.probing,
    required this.now,
    required this.onPressed,
  });

  final ApiFailure? reason;
  final bool restored;
  final bool probing;
  final DateTime now;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final background = restored
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;
    final foreground = restored ? scheme.onPrimaryContainer : scheme.onSurface;
    final title = restored
        ? l10n.offlineBannerRestored
        : offlineBannerText(reason, now);
    final label = restored
        ? l10n.offlineSwitchOnline
        : l10n.offlineRetryConnection;
    final button = FilledButton.tonalIcon(
      key: const ValueKey('offline-banner-action'),
      onPressed: probing ? null : onPressed,
      icon: probing
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              restored ? Icons.cloud_done_outlined : Icons.refresh,
              size: 18,
            ),
      label: Text(label),
    );
    final text = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(
            restored ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
            size: 22,
            color: restored ? foreground : scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Semantics(
            liveRegion: true,
            label: probing
                ? '$title · ${l10n.offlineCheckingConnection}'
                : title,
            child: ExcludeSemantics(
              child: Text(
                title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ],
    );
    return Material(
      key: ValueKey(
        restored
            ? 'offline-banner-restored'
            : probing
            ? 'offline-banner-probing'
            : 'offline-banner-offline',
      ),
      color: background,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 360;
          return Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 12, 12),
            child: narrow
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      text,
                      const SizedBox(height: 8),
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: button,
                      ),
                    ],
                  )
                : Row(
                    children: [
                      Expanded(child: text),
                      const SizedBox(width: 12),
                      button,
                    ],
                  ),
          );
        },
      ),
    );
  }
}

class _PendingLink extends StatelessWidget {
  const _PendingLink();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      key: const ValueKey('offline-pending-link'),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.link, size: 18, color: muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.offlinePendingLink,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
        ],
      ),
    );
  }
}

/// "@user · host · last verified N days ago" (§6.8), each GitLab value
/// isolated on its own.
class _AccountTile extends StatelessWidget {
  const _AccountTile({required this.account, required this.validatedAt});
  final Account account;
  final DateTime validatedAt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final username = isolated('@${account.user.username}');
    final host = isolated(account.instance.base.host);
    final validated = l10n.offlineLastValidated(relativeTime(validatedAt));
    return Padding(
      key: const ValueKey('offline-shell-account'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: MergeSemantics(
        child: Row(
          children: [
            Monogram(account.user.name, size: 36, circle: true),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    username,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '$host · $validated',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SavedProjectTile extends StatelessWidget {
  const _SavedProjectTile({required this.record, required this.onTap});
  final SnapshotRecord record;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final small = theme.textTheme.bodySmall?.copyWith(color: muted);
    return MergeSemantics(
      child: InkWell(
        key: ValueKey('offline-shell-row-${record.id}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 10, 12, 10),
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
                    Text(
                      isolated(record.projectName),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontSize: 17,
                        height: 1.3,
                      ),
                    ),
                    Text(
                      isolated(record.projectPath),
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
                          record.refKind == SnapshotRefKind.tag
                              ? Icons.label_outline
                              : Icons.alt_route,
                          size: 14,
                          color: muted,
                        ),
                        Text(isolated(record.refName), style: small),
                        Text(
                          '@ ${RepositoryRef.shortSha(record.sha)}',
                          textDirection: TextDirection.ltr,
                          style: codeTextStyle(
                            context,
                            fontSize: 12,
                            color: muted,
                          ),
                        ),
                        if (record.subPath.isNotEmpty)
                          Text(
                            l10n.offlineRowFolder(isolated(record.subPath)),
                            style: small,
                          ),
                      ],
                    ),
                    if (record.savedAt case final saved?)
                      Text(
                        l10n.offlineRowSavedAt(relativeTime(saved)),
                        style: small,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 20, color: muted),
            ],
          ),
        ),
      ),
    );
  }
}
