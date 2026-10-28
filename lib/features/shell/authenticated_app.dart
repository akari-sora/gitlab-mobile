import 'dart:async';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_localizations/flutter_localizations.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/offline/offline_repository_coordinator.dart';
import '../../core/read_cache_disk_contract.dart';
import '../../shared/adaptive_breakpoints.dart';
import '../../shared/hub_ui.dart';
import '../../shared/in_app_links.dart';
import '../../shared/list_detail_scaffold.dart';
import '../../shared/reveal_transition.dart';
import '../../shared/scroll_chrome.dart';
import '../../shared/theme.dart';
import '../../shared/workspace_ui.dart';
import '../auth/session_controller.dart';
import '../cache/read_cache_settings_page.dart';
import '../offline/offline_projects_page.dart';
import '../offline/offline_repositories.dart';
import '../offline/offline_status.dart';
import '../ai/ai_account_removal.dart';
import '../ai/ai_chat_page.dart' show openAiChatSession;
import '../ai/ai_background_execution.dart';
import '../ai/ai_recovery_notice.dart';
import '../ai/ai_write_journal.dart';
import '../ai/ai_chat_session.dart';
import '../ai/ai_run_notification_ui.dart';
import '../ai/ai_run_registry.dart';
import '../ai/ai_scope.dart';
import '../ai/ai_settings_page.dart';
import '../workspace/activity_page.dart';
import '../workspace/groups_page.dart';
import '../workspace/project_page.dart';
import '../workspace/projects_page.dart';
import '../workspace/inbox_page.dart';
import '../workspace/navigation.dart';
import '../workspace/search_page.dart';
import '../workspace/ci_page.dart';
import '../workspace/work_item_page.dart';
import 'app_shortcuts.dart';
import 'home_page.dart';
import 'appearance.dart';
import 'build_info.dart';
import 'incoming_links.dart';
import '../security/app_lock.dart';
import 'language.dart';
import '../update/update_controller.dart';
import '../update/update_section.dart';
import '../../core/brand.dart';
import '../../l10n/l10n.dart';

class AuthenticatedApp extends StatefulWidget {
  const AuthenticatedApp({
    super.key,
    required this.session,
    required this.appearance,
    required this.shortcuts,
    this.dynamicLight,
    this.dynamicDark,
    this.buildInfoLoader = loadBuildInfo,
    this.updates,
    this.incoming,
    this.lock,
    this.language,
    this.ai,
    this.aiSessionFactory,
    this.runNotifications,
    this.aiRunsChannel,
    this.offlineCoordinator,
    this.writeJournal,
  });
  final SessionController session;
  final AppearanceController appearance;

  /// The process owner of offline repository snapshots; tests inject one.
  /// Defaults to [OfflineRepositoryCoordinator.instance].
  final OfflineRepositoryCoordinator? offlineCoordinator;

  /// The app's language; null where the build does not switch it (tests).
  final LanguageController? language;

  /// The opt-in app lock; null where the build has none (tests).
  final AppLockController? lock;

  /// Links handed over by other apps; null where none can arrive.
  final IncomingLinks? incoming;

  /// The app's update flow; null (and nothing shown) when this build has no
  /// update channel.
  final AppUpdateController? updates;

  /// AI is absent while the compile-time gate is off and in existing tests.
  final AiControllers? ai;

  /// Overrides conversation construction in synthetic shell tests.
  final AiChatSessionFactory? aiSessionFactory;

  /// Tapped AI run notifications, held for the whole process; null where AI
  /// or its notifications are absent. Used only together with [ai].
  final AiRunNotificationGate? runNotifications;

  /// The native AI run channel, for synthetic shell tests; null uses the
  /// platform's.
  @visibleForTesting
  final MethodChannel? aiRunsChannel;

  /// The journal whose start-up recovery the shell reports; tests pass their
  /// own, the app uses [AiWriteJournal.instance].
  @visibleForTesting
  final AiWriteJournal? writeJournal;
  final LauncherShortcuts shortcuts;
  final ColorScheme? dynamicLight;
  final ColorScheme? dynamicDark;
  final BuildInfoLoader buildInfoLoader;
  @override
  State<AuthenticatedApp> createState() => _AuthenticatedAppState();
}

/// Fires when a route above the shell starts to pop, so navigation tucked away
/// by scrolling returns together with the shell.
class _PopObserver extends NavigatorObserver with ChangeNotifier {
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => notifyListeners();
}

class _AuthenticatedAppState extends State<AuthenticatedApp> {
  // The appearance lives outside this widget on purpose: the whole
  // authenticated tree is rebuilt on every account switch, and the choice is a
  // device preference that must survive both that and a restart.
  bool _dynamicProbeSettled = false;
  bool _probedScheme = false;
  final _pops = _PopObserver();
  late InAppLinkHandler _links;
  AccountAiRunRegistry? _aiRegistry;

  /// The live conversations of [_aiRegistry], for the stop and switch dialogs.
  AiAccountActivity? _aiActivity;

  /// The account's offline projects for this generation (C3b). The tree is
  /// rebuilt on every account switch, so one adapter belongs to one binding.
  OfflineRepositories? _offline;
  AppLifecycleListener? _lifecycle;

  /// The shell's [_MobileShellState._leave], reachable from pushed routes.
  final _leaveHandler = _LeaveHandler();

  OfflineRepositories? _createOffline() {
    final coordinator =
        widget.offlineCoordinator ?? OfflineRepositoryCoordinator.instance;
    final account = widget.session.active;
    final api = widget.session.api;
    if (!coordinator.configured || account == null || api == null) return null;
    return OfflineRepositories(
      binding: DiskBinding(
        accountKey: account.key,
        generation: widget.session.generation,
      ),
      coordinator: coordinator,
      api: api,
    );
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _offline?.dispose();
    _offline = null;
    widget.session.removeListener(_sessionOwnerChanged);
    _disposeAiRegistry();
    widget.language?.removeListener(_languageChanged);
    _pops.dispose();
    super.dispose();
  }

  // Text is read from l10n during build, so a new language rebuilds the whole
  // tree in place; routes, scroll positions and drafts are kept.
  void _languageChanged() {
    if (mounted) rebuildForLanguage(context);
  }

  /// Links tapped anywhere in this tree open for the account this tree was
  /// built for. Once the session moves on they go to the browser instead.
  InAppLinkHandler _bindLinks(SessionController session) {
    final account = session.active;
    final api = session.api;
    if (account == null || api == null) return (_, _) async => false;
    final generation = session.generation;
    return inAppLinkHandler(
      account,
      api,
      isCurrent: () =>
          mounted &&
          !api.isClosed &&
          session.generation == generation &&
          session.active?.key == account.key &&
          identical(session.api, api),
      ownerChanges: session,
      sessionGeneration: generation,
    );
  }

  @override
  void didUpdateWidget(covariant AuthenticatedApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(_sessionOwnerChanged);
      _disposeAiRegistry(oldWidget.runNotifications);
      _links = _bindLinks(widget.session);
      widget.session.addListener(_sessionOwnerChanged);
    }
    if (oldWidget.ai?.settings != widget.ai?.settings ||
        oldWidget.aiSessionFactory != widget.aiSessionFactory) {
      _disposeAiRegistry(oldWidget.runNotifications);
    } else if (oldWidget.runNotifications != widget.runNotifications) {
      if (_aiRegistry case final registry?) {
        oldWidget.runNotifications?.unbind(registry);
        widget.runNotifications?.bind(registry);
      }
    }
    if (oldWidget.language != widget.language) {
      oldWidget.language?.removeListener(_languageChanged);
      widget.language?.addListener(_languageChanged);
    }
  }

  @override
  void initState() {
    super.initState();
    _offline = _createOffline();
    if (_offline != null) {
      _lifecycle = AppLifecycleListener(
        onStateChange: (state) =>
            _offline?.setForeground(state == AppLifecycleState.resumed),
      );
    }
    _links = _bindLinks(widget.session);
    widget.session.addListener(_sessionOwnerChanged);
    widget.language?.addListener(_languageChanged);
    if (widget.dynamicLight != null || widget.dynamicDark != null) {
      _dynamicProbeSettled = true;
      _probedScheme = true;
    } else {
      unawaited(_probeDynamicColor());
    }
  }

  Future<void> _probeDynamicColor() async {
    var hasScheme = false;
    try {
      hasScheme = await DynamicColorPlugin.getCorePalette() != null;
    } catch (_) {}
    if (!hasScheme) {
      try {
        hasScheme = await DynamicColorPlugin.getAccentColor() != null;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _dynamicProbeSettled = true;
      _probedScheme = hasScheme;
    });
  }

  void _sessionOwnerChanged() {
    final registry = _aiRegistry;
    if (registry == null || registry.ownsCurrentSession) return;
    _disposeAiRegistry();
    if (mounted) setState(() {});
  }

  void _disposeAiRegistry([AiRunNotificationGate? notifications]) {
    if (_aiRegistry case final registry?) {
      (notifications ?? widget.runNotifications)?.unbind(registry);
    }
    _aiRegistry?.dispose();
    _aiRegistry = null;
    _aiActivity = null;
  }

  AccountAiRunRegistry _currentAiRegistry(AiControllers ai) {
    final existing = _aiRegistry;
    if (existing != null && existing.ownsCurrentSession) return existing;
    existing?.dispose();
    final activity = AiAccountActivity();
    final channel = widget.aiRunsChannel;
    late final AccountAiRunRegistry registry;
    registry = AccountAiRunRegistry(
      session: widget.session,
      settings: ai.settings,
      sessionFactory: activity.track(widget.aiSessionFactory),
      backgroundExecution: channel == null
          ? null
          : AiBackgroundExecution(
              accountKey: widget.session.active!.key,
              generation: widget.session.generation,
              ownerApi: widget.session.api!,
              isCurrent: () => registry.ownsCurrentSession,
              appInForeground: aiAppInForeground,
              channel: channel,
            ),
    );
    activity.attach(registry);
    _aiActivity = activity;
    // A tap that is waiting re-reads its conversation in this registry; the
    // shell takes it after this build.
    widget.runNotifications?.bind(registry);
    return _aiRegistry = registry;
  }

  /// Above the shell, under the navigator: a start-up recovery notice for
  /// the signed-in account opens as a dialog over Home.
  Widget _recoveryNotice(Widget shell) {
    final accountKey = widget.session.active?.key;
    if (accountKey == null) return shell;
    return AiRecoveryNotice(
      journal: widget.writeJournal ?? AiWriteJournal.instance,
      accountKey: accountKey,
      lock: widget.lock,
      child: shell,
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.appearance,
    builder: (context, _) => DynamicColorBuilder(
      builder: (light, dark) {
        final resolvedLight = widget.dynamicLight ?? flutterScheme(light);
        final resolvedDark = widget.dynamicDark ?? flutterScheme(dark);
        final available = resolvedLight != null || resolvedDark != null || _probedScheme;
        final enabled = available && widget.appearance.useDynamicColor;
        if (_dynamicProbeSettled &&
            !available &&
            widget.appearance.loaded &&
            widget.appearance.useDynamicColor) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(widget.appearance.clearUnsupportedDynamicColor());
          });
        }
        final app = MaterialApp(
          debugShowCheckedModeBanner: false,
          // Above the navigator, so every pushed route sees the link handler.
          builder: (context, child) => AppLockGate(
            controller: widget.lock,
            child: InAppLinks(
              handler: _links,
              child: applySystemBars(context, child),
            ),
          ),
          title: appName,
          theme: appTheme(
            Brightness.light,
            dynamicScheme: enabled ? resolvedLight : null,
          ),
          darkTheme: appTheme(
            Brightness.dark,
            dynamicScheme: enabled ? resolvedDark : null,
          ),
          themeMode: widget.appearance.mode,
          locale: widget.language?.locale ?? localeOf(sourceLanguage),
          supportedLocales: appLocales,
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          navigatorObservers: [_pops],
          home: _recoveryNotice(_MobileShell(
            session: widget.session,
            shortcuts: widget.shortcuts,
            pops: _pops,
            theme: widget.appearance.mode,
            changeTheme: (mode) => unawaited(widget.appearance.select(mode)),
            useDynamicColor: widget.appearance.useDynamicColor,
            dynamicColorAvailable: available,
            changeDynamicColor: (value) =>
                unawaited(widget.appearance.setUseDynamicColor(value)),
            buildInfoLoader: widget.buildInfoLoader,
            updates: widget.updates,
            incoming: widget.incoming,
            lock: widget.lock,
            language: widget.language,
            aiActivity: () => _aiActivity,
            runNotifications: widget.ai == null
                ? null
                : widget.runNotifications,
            leaveHandler: _leaveHandler,
          )),
        );
        return SessionLeaveScope(
          leave: _leaveHandler.leave,
          child: _offlineScope(_aiScoped(app)),
        );
      },
    ),
  );

  Widget _offlineScope(Widget child) {
    final offline = _offline;
    final account = widget.session.active;
    if (offline == null || account == null) return child;
    return OfflineScope(repositories: offline, account: account, child: child);
  }

  Widget _aiScoped(Widget app) {
    final ai = widget.ai;
    final accountKey = widget.session.active?.key;
    final api = widget.session.api;
    if (ai == null || accountKey == null || api == null) {
      _disposeAiRegistry();
      return app;
    }
    final registry = _currentAiRegistry(ai);
    final scoped = AiScope(
      controllers: ai,
      accountKey: accountKey,
      child: app,
    );
    return AiRunRegistryScope(
      registry: registry,
      child: switch (widget.runNotifications) {
        final gate? => AiRunNotificationScope(gate: gate, child: scoped),
        null => scoped,
      },
    );
  }
}

/// Holds the mounted shell's leave handler for [SessionLeaveScope], which sits
/// above the navigator where the shell's state is out of reach.
final class _LeaveHandler {
  Future<void> Function(LeaveIntent intent, Future<void> Function() action)?
  handler;

  Future<void> leave(LeaveIntent intent, Future<void> Function() action) {
    final current = handler;
    return current == null ? action() : current(intent, action);
  }
}

class _MobileShell extends StatefulWidget {
  const _MobileShell({
    required this.session,
    required this.shortcuts,
    required this.pops,
    required this.theme,
    required this.changeTheme,
    required this.useDynamicColor,
    required this.dynamicColorAvailable,
    required this.changeDynamicColor,
    required this.buildInfoLoader,
    this.updates,
    this.incoming,
    this.lock,
    this.language,
    this.aiActivity,
    this.runNotifications,
    this.leaveHandler,
  });
  final SessionController session;
  final LauncherShortcuts shortcuts;

  /// Receives [_MobileShellState._leave] for routes above the shell.
  final _LeaveHandler? leaveHandler;

  /// The current account's AI conversations; null (or returning null) when
  /// AI is absent.
  final AiAccountActivity? Function()? aiActivity;

  /// Tapped AI run notifications; null when AI is absent.
  final AiRunNotificationGate? runNotifications;
  final AppUpdateController? updates;
  final IncomingLinks? incoming;
  final AppLockController? lock;
  final LanguageController? language;
  final Listenable pops;
  final ThemeMode theme;
  final ValueChanged<ThemeMode> changeTheme;
  final bool useDynamicColor;
  final bool dynamicColorAvailable;
  final ValueChanged<bool> changeDynamicColor;
  final BuildInfoLoader buildInfoLoader;
  @override
  State<_MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<_MobileShell> {
  final _backDispatcher = DetailBackDispatcher();
  final _chrome = ScrollChromeController();
  final _scrollTop = List.generate(4, (_) => ValueNotifier<int>(0));
  final _meScroll = ScrollController();
  bool? _useRail;
  int _selected = _home;
  int _searchToken = 0;
  int _locatorToken = 0;
  int _createToken = 0;
  int _todoToken = 0;
  (int, String)? _incomingLink;

  /// The removal job this page started, from the hold until it ends (§8).
  AiRemovalJob? _removal;

  /// The account whose removal waits for writes in flight.
  String? _removalWaiting;

  /// Arms dispose: a page that goes away requests cancellation of its job.
  VoidCallback? _cancelOnDispose;

  /// A switch or sign-out waits for the AI guard (§12.1).
  bool _leaving = false;
  final Completer<void> _gone = Completer<void>();
  AiAccountDialogs? _ownDialogs;
  AiAccountDialogs get _dialogs => _ownDialogs ??= AiAccountDialogs(context);

  /// While any removal job holds its token, switching, removal and sign-out
  /// stay disabled in both entry points.
  bool get _accountLocked => AiAccountRemoval.anyRunning || _leaving;
  final Set<int> _visited = {_home};

  static const _home = 0, _inbox = 1, _explore = 2, _me = 3;
  /// Cancels this shell's read-cache notice subscription.
  void Function()? _cancelReadCacheNotices;

  /// The last cleanup notice shown as a snack bar, so repeats merge (§4.6).
  String? _shownReadCacheNotice;
  ApiFailure? _recentFailure;
  Account? _recentAccount;
  int? _recentProjectId;
  int? _recentGeneration;
  ResumeTarget? _resumeTarget;
  ApiFailure? _resumeFailure;
  Account? _resumeAccount;
  int? _resumeGeneration;
  Future<void> _leaveFromScope(
    LeaveIntent intent,
    Future<void> Function() action,
  ) => _leave(action, intent: intent);

  @override
  void initState() {
    super.initState();
    widget.leaveHandler?.handler = _leaveFromScope;
    widget.session.addListener(_onSession);
    widget.shortcuts.addListener(_onShortcut);
    widget.pops.addListener(_chrome.show);
    widget.pops.addListener(_syncReadCacheNoticeMerge);
    offlineCacheCleanupResolved.addListener(_syncReadCacheNoticeMerge);
    widget.updates?.addListener(_onUpdates);
    widget.incoming?.addListener(_onIncoming);
    widget.runNotifications?.addListener(_onRunNotification);
    AiAccountRemoval.changes.addListener(_onRemovalChanged);
    final account = widget.session.active;
    if (account != null) {
      unawaited(widget.shortcuts.publish(account.key));
    }
    _installReadCacheControls();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _showLeftRemovalResults();
        // A notice raised before this shell existed, e.g. during start-up.
        if (widget.session.active case final active?) {
          _presentReadCacheNotice(
            widget.session.readCache.notice(_readCacheBinding(active)),
          );
        }
        unawaited(_consumeResumeTarget());
        unawaited(_consumeShortcut());
        // A link may have arrived before sign-in or while the tree was rebuilt.
        unawaited(_consumeIncoming());
        // So may a tapped run notification, including the one that started
        // the app.
        unawaited(_consumeRunNotification());
        // The start-up check may have finished before this shell existed.
        if (widget.updates?.unannounced ?? false) _onUpdates();
      }
    });
  }

  @override
  void didUpdateWidget(covariant _MobileShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(_onSession);
      widget.session.addListener(_onSession);
      _installReadCacheControls();
    }
    if (oldWidget.pops != widget.pops) {
      oldWidget.pops.removeListener(_chrome.show);
      oldWidget.pops.removeListener(_syncReadCacheNoticeMerge);
      widget.pops.addListener(_chrome.show);
      widget.pops.addListener(_syncReadCacheNoticeMerge);
    }
    if (oldWidget.updates != widget.updates) {
      oldWidget.updates?.removeListener(_onUpdates);
      widget.updates?.addListener(_onUpdates);
    }
    if (oldWidget.incoming != widget.incoming) {
      oldWidget.incoming?.removeListener(_onIncoming);
      widget.incoming?.addListener(_onIncoming);
    }
    if (oldWidget.runNotifications != widget.runNotifications) {
      oldWidget.runNotifications?.removeListener(_onRunNotification);
      widget.runNotifications?.addListener(_onRunNotification);
    }
  }

  /// Keeps the 我的 badge current, and points out once an update the start-up
  /// check found.
  void _onUpdates() {
    if (!mounted) return;
    final updates = widget.updates!;
    if (updates.unannounced) {
      updates.markAnnounced();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l10n.newVersionAvailable),
          action: SnackBarAction(label: l10n.viewAction, onPressed: () => _goTo(_me)),
        ));
      });
    }
    setState(() {});
  }

  void _onSession() {
    if (mounted) {
      if (widget.session.active != null && widget.session.pendingResumeTarget != null) {
        unawaited(_consumeResumeTarget());
      }
      setState(() {});
    }
  }

  /// The settings entry, the central failure renderer, these notices and the
  /// typed diff/log screens all exist once this shell is built, so the
  /// coordinator's user-controls gate opens here (C2e). The gate is not
  /// identity evidence: start-up recovery and this session's verified
  /// activation still decide whether the disk opens.
  void _installReadCacheControls() {
    final session = widget.session;
    final cache = session.readCache;
    _cancelReadCacheNotices?.call();
    _cancelReadCacheNotices = cache.subscribe(_onReadCacheNotice);
    cache.installUserControls();
    final active = session.active;
    if (active != null && session.api != null) {
      // Recovery may have finished before this shell existed. Re-deliver the
      // session's own verified binding, as an app resume does; the coordinator
      // rejects it unless every other gate is open.
      unawaited(cache.activate(_readCacheBinding(active)));
    }
  }

  DiskBinding _readCacheBinding(Account account) =>
      DiskBinding(accountKey: account.key, generation: widget.session.generation);

  /// Runs inside the coordinator; only the snapshot for this account and
  /// generation may reach this shell, never an earlier generation's notice.
  void _onReadCacheNotice(ReadCacheNotice notice) {
    final account = widget.session.active;
    if (!mounted || account == null) return;
    final binding = _readCacheBinding(account);
    if (!identical(widget.session.readCache.notice(binding), notice)) return;
    // The notice can arrive while the app is idle: ask for the frame too.
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => _presentReadCacheNotice(notice))
      ..ensureVisualUpdate();
  }

  /// Repeats merge only while the shown notice is still pending. A completed
  /// clear from Settings or a notice retry signals at once
  /// (`offlineCacheCleanupResolved`), even while Settings is still open; a
  /// route pop re-checks too. The next independent failure of the same kind is
  /// then shown again.
  void _syncReadCacheNoticeMerge() {
    final account = widget.session.active;
    if (_shownReadCacheNotice == null || account == null) return;
    if (widget.session.readCache.notice(_readCacheBinding(account)) == null) {
      _shownReadCacheNotice = null;
    }
  }

  void _presentReadCacheNotice(ReadCacheNotice? notice) {
    final account = widget.session.active;
    if (!mounted || notice == null || account == null) return;
    final cache = widget.session.readCache;
    final binding = _readCacheBinding(account);
    if (!identical(cache.notice(binding), notice)) return;
    final state = notice.failure.cleanup!;
    // The failed operation, the removal flow, the sign-in screen and the
    // settings page present these themselves; the 我的 row keeps the status.
    if (state.operation == ReadCacheCleanupOperation.settingsClear) return;
    switch (state.disposition) {
      case ReadCacheCleanupDisposition.requestBlockedBeforeSend:
      case ReadCacheCleanupDisposition.accountRetained:
      case ReadCacheCleanupDisposition.signedOutCleanupPending:
        return;
      case ReadCacheCleanupDisposition.originalOutcomePreserved:
      case ReadCacheCleanupDisposition.legalNetworkValueReturned:
      case ReadCacheCleanupDisposition.diskClosed:
        break;
    }
    final key = '${state.operation.name}/${state.disposition.name}';
    if (key == _shownReadCacheNotice) return;
    _shownReadCacheNotice = key;
    showFailure(
      context,
      notice.failure,
      onRetryCleanup: () => unawaited(retryOfflineCacheCleanup(
        context,
        cache,
        binding,
        onDone: _syncReadCacheNoticeMerge,
      )),
    );
  }

  @override
  void dispose() {
    if (widget.leaveHandler?.handler == _leaveFromScope) {
      widget.leaveHandler?.handler = null;
    }
    _cancelReadCacheNotices?.call();
    _cancelReadCacheNotices = null;
    AiAccountRemoval.changes.removeListener(_onRemovalChanged);
    // Before the final confirmation this stops the job; after it, the job
    // runs to its end without a page.
    _cancelOnDispose?.call();
    _cancelOnDispose = null;
    _ownDialogs?.close();
    if (!_gone.isCompleted) _gone.complete();
    widget.pops.removeListener(_chrome.show);
    widget.pops.removeListener(_syncReadCacheNoticeMerge);
    offlineCacheCleanupResolved.removeListener(_syncReadCacheNoticeMerge);
    _backDispatcher.dispose();
    _chrome.dispose();
    _meScroll.dispose();
    for (final signal in _scrollTop) {
      signal.dispose();
    }
    widget.session.removeListener(_onSession);
    widget.shortcuts.removeListener(_onShortcut);
    widget.updates?.removeListener(_onUpdates);
    widget.incoming?.removeListener(_onIncoming);
    widget.runNotifications?.removeListener(_onRunNotification);
    super.dispose();
  }

  void _onShortcut() {
    if (widget.shortcuts.pending != null) {
      unawaited(_consumeShortcut());
    }
  }

  Future<void> _consumeShortcut() async {
    final account = widget.session.active;
    final api = widget.session.api;
    if (account == null || api == null || !mounted) {
      return;
    }
    final shortcut = widget.shortcuts.takeFor(account.key);
    if (shortcut == null || !mounted) {
      return;
    }
    if (!await _bringShellForward() || !mounted || widget.session.active?.key != account.key) {
      return;
    }
    _chrome.show();
    switch (shortcut.kind) {
      case ShortcutKind.inbox:
        setState(() {
          _selected = _inbox;
          _visited.add(_inbox);
        });
      case ShortcutKind.search:
        setState(() {
          _selected = _explore;
          _visited.add(_explore);
          _searchToken++;
        });
      case ShortcutKind.recent:
        final id = shortcut.projectId;
        if (id == null) return;
        setState(() {
          _selected = _explore;
          _visited.add(_explore);
        });
        await _openRecent(account, api, id);
    }
  }

  Future<void> _pickLanguage(LanguageController language) async {
    final picked = await showModalBottomSheet<(String?,)>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
          child: ListView(shrinkWrap: true, children: [
            ListTile(
              key: const ValueKey('language-system'),
              title: Text(l10n.systemDefault),
              trailing: language.choice == null ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, (null,)),
            ),
            for (final option in appLanguages)
              ListTile(
                key: ValueKey('language-${option.tag}'),
                title: Text(option.name, locale: localeOf(option)),
                trailing: language.choice == option.tag ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, (option.tag,)),
              ),
          ]),
        ),
      ),
    );
    if (picked == null) return;
    await language.select(picked.$1);
  }

  Future<void> _setLock(AppLockController lock, bool value) async {
    if (await lock.setEnabled(value) || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(value ? l10n.appLockStaysOffUnverified : l10n.cannotTurnOffAppLock),
    ));
  }

  Future<void> _openLinkSettings(IncomingLinks incoming) async {
    if (await incoming.openSettings() || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.cannotOpenSystemSettings)));
  }

  void _onIncoming() {
    if (widget.incoming?.pending != null) unawaited(_consumeIncoming());
  }

  /// Opens a link another app handed over. The shell comes forward and
  /// 探索's locator resolves the link for the active account; a link for
  /// another instance is explained there, never opened for this account.
  Future<void> _consumeIncoming() async {
    final account = widget.session.active;
    if (account == null || widget.session.api == null || !mounted) return;
    final link = widget.incoming?.take();
    if (link == null) return;
    if (!await _bringShellForward() || !mounted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l10n.finishEditBeforeSharedLink),
        ));
      }
      return;
    }
    if (widget.session.active?.key != account.key) return;
    _chrome.show();
    setState(() {
      _selected = _explore;
      _visited.add(_explore);
      _incomingLink = ((_incomingLink?.$1 ?? 0) + 1, link.toString());
    });
  }

  var _runNotificationQueued = false;

  /// The gate also changes while a build binds a new registry, and while the
  /// lock opens; navigation waits until the current frame is done.
  void _onRunNotification() {
    if (_runNotificationQueued ||
        !(widget.runNotifications?.waiting ?? false)) {
      return;
    }
    _runNotificationQueued = true;
    scheduleMicrotask(() {
      _runNotificationQueued = false;
      if (mounted) unawaited(_consumeRunNotification());
    });
  }

  /// Opens what a tapped run notification points to, only once the app lock
  /// has opened: the conversation at its waiting approval card, the
  /// conversation alone when the card is gone, or 首頁 when the conversation
  /// is no longer this account's. Never approves, switches accounts or reads
  /// history.
  Future<void> _consumeRunNotification() async {
    if (!mounted) return;
    final gate = widget.runNotifications;
    final open = gate?.take();
    if (gate == null || open == null) return;
    bool mayNavigate() => mounted &&
        identical(gate, widget.runNotifications) && gate.canNavigate(open);
    if (!await _bringShellForward(mayNavigate: mayNavigate) || !mounted) {
      if (mayNavigate()) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.aiRunNoticeFinishEditFirst)),
        );
      }
      return;
    }
    // No await between this foreground/lock/owner check and the route push.
    if (!mayNavigate()) return;
    final session = open.session;
    if (session == null) {
      _goTo(_home);
      return;
    }
    _chrome.show();
    if (!await openAiChatSession(context, session, proposal: open.proposal) &&
        mounted) {
      _goTo(_home);
    }
  }

  /// Pops pushed routes so the shell is the visible page. A route that refuses
  /// to pop handles that attempt itself. An editor may still be flushing a
  /// draft or confirming the exit; that work is awaited. If the route is still
  /// up afterwards, the shortcut stops instead of discarding the guard.
  Future<bool> _bringShellForward({bool Function()? mayNavigate}) async {
    final navigator = Navigator.of(context);
    while (mounted) {
      final top = _topRoute(navigator);
      if (top == null || top.isFirst) return true;
      if (mayNavigate != null && !mayNavigate()) return false;
      if (top is ModalRoute<Object?> && top.popDisposition == RoutePopDisposition.doNotPop) {
        top.onPopInvokedWithResult(false, null);
        final pending = RouteExit.pending(top);
        if (pending != null) {
          try {
            await pending;
          } catch (_) {
            // The route reports its own failure; the shortcut only needs to
            // know whether the page is still up.
          }
        } else {
          await Future<void>.delayed(Duration.zero);
        }
        if (!mounted || top.isActive) return false;
        continue;
      }
      navigator.pop();
    }
    return false;
  }

  Route<dynamic>? _topRoute(NavigatorState navigator) {
    Route<dynamic>? top;
    navigator.popUntil((route) {
      top = route;
      return true;
    });
    return top;
  }

  bool _sameAccount(Account account, int generation) =>
      mounted &&
      widget.session.generation == generation &&
      widget.session.active?.key == account.key;

  Future<void> _openRecent(Account account, GitLabApi api, int projectId) async {
    final generation = widget.session.generation;
    try {
      final project = await api.project('$projectId');
      if (!_sameAccount(account, generation) || !mounted) return;
      setState(() {
        _recentFailure = null;
        _recentAccount = null;
        _recentProjectId = null;
        _recentGeneration = null;
      });
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ProjectPage(account: account, api: api, project: project),
        ),
      );
    } catch (e) {
      if (!_sameAccount(account, generation)) return;
      final failure = safeFailure(e);
      if (failure.kind == FailureKind.cancelled) return;
      setState(() {
        _recentFailure = failure;
        _recentAccount = account;
        _recentProjectId = projectId;
        _recentGeneration = generation;
      });
    }
  }

  void _retryRecent() {
    final account = _recentAccount;
    final api = widget.session.api;
    final id = _recentProjectId;
    final generation = _recentGeneration;
    if (account == null || api == null || id == null || generation == null) return;
    if (!_sameAccount(account, generation)) return;
    unawaited(_openRecent(account, api, id));
  }

  bool get _showRecentFailure {
    final failure = _recentFailure;
    final account = _recentAccount;
    final generation = _recentGeneration;
    if (failure == null || account == null || generation == null || _recentProjectId == null) {
      return false;
    }
    return widget.session.generation == generation && widget.session.active?.key == account.key;
  }

  Future<void> _consumeResumeTarget() async {
    final account = widget.session.active;
    if (account == null || !mounted) return;
    final target = widget.session.takeResumeTarget();
    if (target == null || !mounted) return;
    await _openResumeTarget(target);
  }

  Future<void> _openResumeTarget(ResumeTarget target) async {
    final account = widget.session.active;
    final api = widget.session.api;
    if (account == null || api == null || !mounted) return;
    if (!await _bringShellForward() || !mounted || widget.session.active?.key != account.key) {
      return;
    }
    final generation = widget.session.generation;
    try {
      final projectRef = (target.projectPath != null && target.projectPath!.isNotEmpty)
          ? target.projectPath!
          : (target.projectId != null ? '${target.projectId}' : '');
      if (projectRef.isEmpty) return;

      final project = await api.project(projectRef);
      if (!_sameAccount(account, generation) || !mounted) return;

      setState(() {
        _resumeFailure = null;
        _resumeAccount = null;
        _resumeGeneration = null;
        _resumeTarget = null;
      });

      final Widget page;
      switch (target.resource) {
        case 'issues' || 'issue':
          if (target.iid != null) {
            page = WorkItemPage(
              account: account,
              api: api,
              project: project,
              resource: 'issues',
              iid: target.iid!,
            );
          } else {
            page = ProjectPage(
              account: account,
              api: api,
              project: project,
              initialTab: 1,
            );
          }
        case 'merge_requests' || 'merge_request':
          if (target.iid != null) {
            page = WorkItemPage(
              account: account,
              api: api,
              project: project,
              resource: 'merge_requests',
              iid: target.iid!,
            );
          } else {
            page = ProjectPage(
              account: account,
              api: api,
              project: project,
              initialTab: 2,
            );
          }
        case 'pipelines' || 'pipeline':
          if (target.iid != null) {
            page = PipelinePage(
              account: account,
              api: api,
              project: project,
              id: target.iid!,
            );
          } else {
            page = ProjectPage(
              account: account,
              api: api,
              project: project,
              initialTab: 3,
            );
          }
        case 'repository':
          page = ProjectPage(
            account: account,
            api: api,
            project: project,
            initialTab: 0,
          );
        case 'project':
        default:
          page = ProjectPage(
            account: account,
            api: api,
            project: project,
          );
      }

      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => page),
      );
    } catch (e) {
      if (!_sameAccount(account, generation)) return;
      final failure = safeFailure(e);
      if (failure.kind == FailureKind.cancelled) return;
      setState(() {
        _resumeFailure = failure;
        _resumeAccount = account;
        _resumeGeneration = generation;
        _resumeTarget = target;
      });
    }
  }

  void _retryResume() {
    final target = _resumeTarget;
    final account = _resumeAccount;
    final generation = _resumeGeneration;
    if (target == null || account == null || generation == null) return;
    if (!_sameAccount(account, generation)) return;
    unawaited(_openResumeTarget(target));
  }

  bool get _showResumeFailure {
    final failure = _resumeFailure;
    final account = _resumeAccount;
    final generation = _resumeGeneration;
    if (failure == null || account == null || generation == null || _resumeTarget == null) {
      return false;
    }
    return widget.session.generation == generation && widget.session.active?.key == account.key;
  }

  void _onRemovalChanged() {
    if (!mounted) return;
    setState(() {});
    if (_removal == null) _showLeftRemovalResults();
  }

  /// Results of removal jobs whose page went away (§8 step 5).
  void _showLeftRemovalResults() {
    if (!mounted || _removal != null) return;
    for (final saved in widget.session.accounts) {
      final result = AiAccountRemoval.takeResult(saved.key);
      if (result != null) presentAiRemovalResult(context, result);
    }
  }

  /// §8 account removal: the hold is taken here, synchronously, before any
  /// dialog; the shared job runs the rest.
  /// Removing the signed-in account deletes its offline projects too (§6.7):
  /// that is confirmed before the removal takes its hold.
  Future<void> _confirmRemove(Account account) async {
    if (_accountLocked || widget.session.busy) return;
    if (widget.session.active?.key == account.key &&
        !await confirmOfflineLoss(
          context,
          repositories: OfflineScope.maybeOf(context, listen: false),
          account: account,
          kind: LeaveKind.remove,
        )) {
      return;
    }
    if (mounted) _remove(account);
  }

  void _remove(Account account) {
    if (_accountLocked || widget.session.busy) return;
    final job = AiAccountRemoval.begin(account.key);
    if (job == null) return;
    setState(() => _removal = job);
    unawaited(_runRemoval(account, job));
  }

  Future<void> _runRemoval(Account account, AiRemovalJob job) async {
    // Only the current account has a registry here.
    final activity = widget.session.active?.key == account.key
        ? widget.aiActivity?.call()
        : null;
    await AiAccountRemoval.run(
      account: account,
      job: job,
      session: widget.session,
      clearReadCacheDisk: (saved) =>
          widget.session.readCache.clearReadCacheDisk(saved.key),
      confirm: (prompt) => _dialogs.confirmRemoval(account, prompt),
      waitForInFlightWrites: activity?.stopAndWait ?? () async {},
      requestCancelOnDispose: () => _cancelOnDispose = job.requestCancel,
      runningOrPending: activity?.runningOrPending ?? 0,
      // stopAndWait applies the §12.1 limit itself when it stops the runs;
      // this is only the outer bound.
      waitLimit: AiAccountRemoval.uploadWaitLimit,
      onWaiting: (waiting) {
        if (mounted) {
          setState(() => _removalWaiting = waiting ? account.key : null);
        }
      },
    );
    _cancelOnDispose = null;
    if (!mounted) return;
    setState(() {
      _removal = null;
      _removalWaiting = null;
    });
    final result = AiAccountRemoval.takeResult(account.key);
    if (result != null) presentAiRemovalResult(context, result);
  }

  /// §12.1 guard before switching accounts or signing out. Without AI the
  /// action runs as before.
  Future<void> _leave(
    Future<void> Function() action, {
    LeaveIntent intent = const LeaveIntent(LeaveKind.signOut),
  }) async {
    if (_accountLocked) return;
    // §6.7: the offline-projects loss is confirmed first, before the AI
    // guard and before anything stops, clears or changes the session.
    final account = widget.session.active;
    if (account != null &&
        !await confirmOfflineLoss(
          context,
          repositories: OfflineScope.maybeOf(context, listen: false),
          account: account,
          kind: intent.kind,
        )) {
      return;
    }
    if (!mounted || _accountLocked) return;
    final activity = widget.aiActivity?.call();
    if (activity == null) {
      await action();
      return;
    }
    setState(() => _leaving = true);
    ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? waiting;
    try {
      final choice = await AiSwitchGuard.confirmSwitch(
        runningOrPending: activity.runningOrPending,
        confirm: (count) => Future.any([
          _dialogs.confirmSwitch(count),
          _gone.future.then((_) => AiSwitchChoice.cancel),
        ]),
      );
      if (!mounted) return;
      // Read before stopping: stopping invalidates the proposals.
      final limit = activity.waitLimit;
      final proceed = await AiSwitchGuard.settle(
        choice: choice,
        stopAndSnapshotWrites: () {
          final writes = activity.stopAndSnapshotWrites();
          if (writes.isNotEmpty &&
              choice == AiSwitchChoice.proceedAndWait &&
              mounted) {
            waiting = ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(l10n.aiRemoveWaitingWrites),
                duration: limit,
              ),
            );
          }
          return writes;
        },
        waitLimit: limit,
      );
      waiting?.close();
      if (!proceed || !mounted) return;
      await action();
    } finally {
      if (mounted) setState(() => _leaving = false);
    }
  }

  Widget _pane(int index, Widget child) => TabActiveScope(
    isActive: _selected == index,
    child: ScrollTopSignal(
      notifier: _scrollTop[index],
      child: ExcludeSemantics(
        excluding: _selected != index,
        child: TickerMode(
          enabled: _selected == index,
          child: IgnorePointer(ignoring: _selected != index, child: child),
        ),
      ),
    ),
  );

  /// Switching destinations reveals the navigation again. Tapping the active
  /// destination scrolls its lists back to the top; open details stay open.
  void _select(int index) {
    _chrome.show();
    if (index != _selected) {
      setState(() {
        _selected = index;
        _visited.add(index);
      });
      return;
    }
    _scrollTop[index].value++;
  }

  /// Home's 待辦, 瀏覽專案, 以連結開啟 and 新增專案 hand over to the inbox or
  /// the explore destination, which own those flows.
  void _goTo(int index, {bool locate = false, bool create = false, bool todo = false}) {
    _chrome.show();
    setState(() {
      _selected = index;
      _visited.add(index);
      if (locate) _locatorToken++;
      if (create) _createToken++;
      if (todo) _todoToken++;
    });
  }

  static List<(IconData, IconData, String)> get _destinations => [
    (Icons.home_outlined, Icons.home, l10n.homeTab),
    (Icons.inbox_outlined, Icons.inbox, l10n.inboxTab),
    (Icons.explore_outlined, Icons.explore, l10n.exploreTab),
    (Icons.person_outline, Icons.person, l10n.meTab),
  ];

  /// A dot on 我的 while an update waits there.
  Widget _updateBadge(int destination, Widget icon) {
    final stage = widget.updates?.stage;
    final waiting = stage == UpdateStage.available || stage == UpdateStage.downloaded;
    return destination == _me && waiting ? Badge(child: icon) : icon;
  }

  Widget _bottomNavigation(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.navigationBarTheme.backgroundColor ?? theme.colorScheme.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CollapsingChrome(
            visible: _chrome,
            edge: AxisDirection.down,
            child: MediaQuery.removePadding(
              context: context,
              // This context is above Scaffold: do not restore its status-bar
              // inset inside NavigationBar's SafeArea.
              removeTop: true,
              removeBottom: true,
              child: NavigationBar(
                selectedIndex: _selected,
                onDestinationSelected: _select,
                destinations: [
                  for (final (index, (icon, selectedIcon, label)) in _destinations.indexed)
                    NavigationDestination(
                      icon: _updateBadge(index, Icon(icon)),
                      selectedIcon: _updateBadge(index, Icon(selectedIcon)),
                      label: label,
                    ),
                ],
              ),
            ),
          ),
          // The gesture-bar inset stays reserved while the bar is tucked away,
          // so list ends never slide under the system handle.
          SizedBox(height: MediaQuery.viewPaddingOf(context).bottom),
        ],
      ),
    );
  }
  Widget _buildMyTab(BuildContext context, Account account, SessionController session) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final ai = AiScope.maybeOf(context);
    void push(Widget Function() page) =>
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page()));
    return Scaffold(
      appBar: AppBar(title: LargeTitle(l10n.meTab)),
      body: gestureSafe(ScrollToTopOnSignal(
        controller: _meScroll,
        child: ListView(
          controller: _meScroll,
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            // Profile header, GitHub-style: round avatar, name, handle, instance.
            Material(
              color: theme.colorScheme.surface,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                child: Row(children: [
                  Monogram(account.user.name, size: 72, circle: true),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          account.user.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.headlineSmall,
                        ),
                        Text(
                          isolated('@${account.user.username}'),
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge?.copyWith(color: muted),
                        ),
                        const SizedBox(height: 4),
                        Row(children: [
                          Icon(Icons.dns_outlined, size: 14, color: muted),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              account.instance.key,
                              style: theme.textTheme.bodySmall?.copyWith(color: muted),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ]),
                      ],
                    ),
                  ),
                ]),
              ),
            ),
            HubSection(
              children: [
                HubRow(
                  leading: const IconTile(Icons.timeline, color: HubColors.slate),
                  title: l10n.myActivity,
                  chevron: true,
                  onTap: () => push(() => ActivityPage(account: account, api: session.api!)),
                ),
                HubRow(
                  leading: const IconTile(Icons.workspaces_outline, color: HubColors.orange),
                  title: l10n.myGroups,
                  chevron: true,
                  onTap: () => push(() => GroupsPage(account: account, api: session.api!)),
                ),
                HubRow(
                  leading: const IconTile(Icons.manage_search, color: HubColors.blue),
                  title: l10n.globalSearch,
                  chevron: true,
                  onTap: () => push(() => SearchPage(account: account, api: session.api!)),
                ),
              ],
            ),
            HubSection(
              title: l10n.accountLabel,
              children: [
                for (final (index, saved) in session.accounts.indexed) ...[
                  if (index > 0) const Divider(height: 1, indent: 64),
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    leading: Monogram(saved.user.name, size: 32, circle: true),
                    title: Text(
                      isolated('@${saved.user.username}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      _removalWaiting == saved.key
                          ? l10n.aiRemoveWaitingWrites
                          : saved.key == account.key
                          ? l10n.hostInUse(saved.instance.base.host)
                          : saved.instance.base.host,
                    ),
                    onTap:
                        session.busy ||
                                _accountLocked ||
                                saved.key == account.key
                            ? null
                            : () => unawaited(
                                _leave(
                                  () => session.select(saved),
                                  intent: LeaveIntent(
                                    LeaveKind.switchAccount,
                                    target: saved,
                                  ),
                                ),
                              ),
                    trailing: IconButton(
                      tooltip: l10n.removeAccountFromDevice,
                      icon: const Icon(Icons.logout, size: 20),
                      onPressed: session.busy || _accountLocked
                          ? null
                          : () => unawaited(_confirmRemove(saved)),
                    ),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Align(alignment: Alignment.centerLeft, child: TextButton.icon(
                    onPressed: _accountLocked
                        ? null
                        : () {
                            unawaited(_leave(session.endSession));
                          },
                    icon: const Icon(Icons.person_add_outlined),
                    label: Text(l10n.addOrReconnectAccount),
                  )),
                ),
              ],
            ),
            if (ai != null)
              HubSection(
                children: [
                  HubRow(
                    key: const ValueKey('ai-settings-row'),
                    leading: const IconTile(Icons.auto_awesome, color: HubColors.purple),
                    title: l10n.aiAssistantLabel,
                    subtitle: ai.settings.initializing ||
                            (!ai.settings.initialized &&
                                ai.settings.initializationFailure == null)
                        ? l10n.loadingDots
                        : ai.settings.initializationFailure != null
                        ? l10n.aiSettingsReadFailure
                        : ai.settings.providers.isEmpty
                        ? l10n.aiNotConfigured
                        : null,
                    chevron: true,
                    onTap: () => push(() => AiSettingsPage(
                      settings: ai.settings,
                      accountKey: ai.accountKey,
                      account: account,
                      api: session.api,
                      isAccountRetained: (accountKey) => session.accounts.any(
                        (saved) => saved.key == accountKey,
                      ),
                      history: ai.history,
                    )),
                  ),
                ],
              ),
            HubSection(
              title: l10n.appearanceLabel,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                  child: AppearancePicker(mode: widget.theme, onChanged: widget.changeTheme),
                ),
                SwitchListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  title: Text(l10n.useSystemColorsMaterialYou),
                  subtitle: Text(
                    widget.dynamicColorAvailable
                        ? l10n.android12WallpaperColors
                        : l10n.deviceNoDynamicColor,
                  ),
                  value: widget.dynamicColorAvailable && widget.useDynamicColor,
                  onChanged: widget.dynamicColorAvailable
                      ? widget.changeDynamicColor
                      : null,
                ),
                if (widget.language case final language?)
                  ListTile(
                    key: const ValueKey('language-row'),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    leading: const Icon(Icons.translate),
                    title: Text(l10n.appLanguage),
                    subtitle: Text(language.choice == null
                        ? l10n.languageFollowsSystem(language.language.name)
                        : language.language.name),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => unawaited(_pickLanguage(language)),
                  ),
              ],
            ),
            if (widget.lock case final lock?)
              ListenableBuilder(
                listenable: lock,
                builder: (context, _) => HubSection(
                  title: l10n.securityLabel,
                  children: [
                    SwitchListTile(
                      key: const ValueKey('app-lock-switch'),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                      secondary: const Icon(Icons.lock_outline),
                      title: Text(l10n.appLockLabel),
                      subtitle: Text(lock.available || lock.enabled
                          ? l10n.appLockAfterOpenOrLeave
                          : l10n.deviceNoScreenLock),
                      value: lock.enabled,
                      onChanged: lock.authenticating || !(lock.available || lock.enabled)
                          ? null
                          : (value) => unawaited(_setLock(lock, value)),
                    ),
                  ],
                ),
              ),
            if (widget.incoming case final incoming? when incoming.canOpenSettings)
              HubSection(
                title: l10n.linksLabel,
                children: [
                  HubRow(
                    leading: const IconTile(Icons.link, color: HubColors.blue),
                    title: l10n.openGitlabComLinksInApp,
                    subtitle: l10n.allowGitlabComLinksSetting,
                    chevron: true,
                    onTap: () => unawaited(_openLinkSettings(incoming)),
                  ),
                ],
              ),
            if (widget.updates case final updates? when updates.enabled)
              UpdateSection(controller: updates),
            HubSection(
              title: l10n.storageAndCacheLabel,
              children: [
                ReadCacheSettingsEntry(
                  cache: session.readCache,
                  binding: _readCacheBinding(account),
                ),
                OfflineProjectsEntry(account: account),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text(
                  appName,
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                BuildInfoLine(load: widget.buildInfoLoader),
                const SizedBox(height: 4),
                Text(
                  appIndependence,
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.tokenScopeLimitsHint,
                  style: TextStyle(fontSize: 12),
                ),
              ]),
            ),
          ],
        ),
      )),
    );
  }

  bool get _keyboardVisible =>
      (MediaQuery.maybeViewInsetsOf(context)?.bottom ?? 0) > 0;

  /// Whether root back may move the task to the background right now. The
  /// bridge calls it again just before the native call, so it reads live
  /// state only: this shell still mounted and owning [registry], the lock
  /// open, nothing above the root page (dialog, sheet, pushed page), no
  /// keyboard, no detail, Home selected and AI work still protected.
  bool _rootBackEligible(AccountAiRunRegistry registry) {
    if (!mounted) return false;
    final lock = widget.lock;
    return (lock == null || !lock.covering) &&
        registry.ownsCurrentSession &&
        identical(
          context.getInheritedWidgetOfExactType<AiRunRegistryScope>()?.registry,
          registry,
        ) &&
        !Navigator.of(context).canPop() &&
        !_keyboardVisible &&
        !_backDispatcher.canHandleBack &&
        _selected == _home &&
        registry.backProtectedCount > 0;
  }

  var _movingBack = false;

  /// Root back with protected AI work: the task goes to the background
  /// instead of the Activity finishing, so the work keeps its process. One
  /// call per back press; a press while one is under way is ignored. This
  /// never starts or stops a run.
  Future<void> _moveTaskToBack(AccountAiRunRegistry registry) async {
    if (_movingBack) return;
    _movingBack = true;
    try {
      final result = await registry.backgroundExecution.moveTaskToBack(
        isBackEligible: () => _rootBackEligible(registry),
      );
      switch (result) {
        case AiTaskBackResult.moved || AiTaskBackResult.notMoved:
          break;
        // Whatever went wrong, the app stays open on the root page; it is
        // never finished while work is protected. Back can be pressed again.
        case AiTaskBackResult.notEligible ||
            AiTaskBackResult.unsupported ||
            AiTaskBackResult.foregroundRequired ||
            AiTaskBackResult.unavailable ||
            AiTaskBackResult.failed:
          break;
      }
    } finally {
      _movingBack = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final account = session.active;
    if (account == null || session.api == null) {
      return const Scaffold(body: SizedBox());
    }
    final aiRuns = switch (AiRunRegistry.maybeOf(context)) {
      final AccountAiRunRegistry registry => registry,
      _ => null,
    };
    return DetailBackScope(
      dispatcher: _backDispatcher,
      depth: 0,
      child: ListenableBuilder(
        listenable: Listenable.merge([_backDispatcher, ?aiRuns]),
        builder: (context, _) {
          // D11: AI work that is running, waiting for approval or paused
          // keeps the root page from closing the app.
          final protected = (aiRuns?.backProtectedCount ?? 0) > 0;
          return PopScope<Object?>(
            canPop:
                _selected == _home &&
                !_backDispatcher.canHandleBack &&
                !protected,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop) return;
              // An open detail, then a tab other than Home, take back first.
              if (_backDispatcher.handleBack()) {
                return;
              }
              if (_selected != _home) {
                _chrome.show();
                setState(() => _selected = _home);
                return;
              }
              if (aiRuns != null && protected) {
                if (_keyboardVisible) {
                  FocusManager.instance.primaryFocus?.unfocus();
                  return;
                }
                unawaited(_moveTaskToBack(aiRuns));
              }
            },
            child: LayoutBuilder(
              builder: (context, constraints) {
                final useRail = AdaptiveBreakpoints.showNavigationRail(constraints.maxWidth);
                if (_useRail != useRail) {
                  // The rail never hides, so the bar comes back visible after rotating.
                  if (_useRail != null) {
                    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _chrome.show(); });
                  }
                  _useRail = useRail;
                }
                return Scaffold(
                  body: Row(
                    children: [
                      if (useRail) ...[
                        SafeArea(
                          // The rail sits on the leading edge: the right in RTL.
                          left: Directionality.of(context) == TextDirection.ltr,
                          top: true,
                          bottom: true,
                          right: Directionality.of(context) == TextDirection.rtl,
                          child: NavigationRail(
                            minWidth: AdaptiveBreakpoints.navigationRailWidth,
                            selectedIndex: _selected,
                            onDestinationSelected: _select,
                            labelType: NavigationRailLabelType.all,
                            destinations: [
                              for (final (icon, selectedIcon, label) in _destinations)
                                NavigationRailDestination(
                                  icon: Icon(icon),
                                  selectedIcon: Icon(selectedIcon),
                                  label: Text(label),
                                ),
                            ],
                          ),
                        ),
                        const VerticalDivider(
                          width: AdaptiveBreakpoints.navigationRailDividerWidth,
                          thickness: 1,
                        ),
                      ],
                      Expanded(
                        key: const ValueKey('shell-main-content-expanded'),
                        child: AdaptiveScope(
                          hasRail: useRail,
                          child: Builder(
                            builder: (contentContext) {
                              final isLtr = Directionality.of(contentContext) == TextDirection.ltr;
                              final content = Column(
                                key: const ValueKey('shell-main-column'),
                                children: [
                                  if (_showRecentFailure)
                                    SafeArea(
                                      bottom: false,
                                      child: FailureNotice(
                                        _recentFailure!,
                                        account: _recentAccount,
                                        resourceLabel: '${_recentProjectId ?? ''}',
                                        onRetry: _retryRecent,
                                        onSwitchAccount: () {
                                          if (_accountLocked) return;
                                          final projectId = _recentProjectId;
                                          unawaited(_leave(intent: const LeaveIntent(LeaveKind.switchAccount), () {
                                            if (projectId != null) {
                                              widget.session.setPendingResumeTarget(
                                                ResumeTarget(projectId: projectId, resource: 'project'),
                                              );
                                            }
                                            return widget.session.endSession(switching: true);
                                          }));
                                        },
                                      ),
                                    ),
                                  if (_showResumeFailure)
                                    SafeArea(
                                      bottom: false,
                                      child: FailureNotice(
                                        _resumeFailure!,
                                        account: _resumeAccount,
                                        resourceLabel: _resumeTarget?.projectPath ??
                                            (_resumeTarget?.projectId != null
                                                ? '${_resumeTarget!.projectId}'
                                                : ''),
                                        onRetry: _retryResume,
                                        onSwitchAccount: () {
                                          if (_accountLocked) return;
                                          final target = _resumeTarget;
                                          unawaited(_leave(intent: const LeaveIntent(LeaveKind.switchAccount), () {
                                            if (target != null) {
                                              widget.session.setPendingResumeTarget(target);
                                            }
                                            return widget.session.endSession(switching: true);
                                          }));
                                        },
                                      ),
                                    ),
                                  Expanded(
                                    key: const ValueKey('shell-indexed-stack-expanded'),
                                    child: NotificationListener<RevealChromeNotification>(
                                      onNotification: (_) {
                                        _chrome.show();
                                        return false;
                                      },
                                      child: NotificationListener<ScrollNotification>(
                                      onNotification: useRail ? null : _chrome.handle,
                                      child: AnimatedIndexedStack(
                                      key: const ValueKey('shell-indexed-stack'),
                                      index: _selected,
                                      children: [
                                        _pane(
                                          _home,
                                          HomePage(
                                            session: session,
                                            shortcuts: widget.shortcuts,
                                            onOpenInbox: () => _goTo(_inbox, todo: true),
                                            onExplore: () => _goTo(_explore),
                                            onLocate: () => _goTo(_explore, locate: true),
                                            onCreate: () => _goTo(_explore, create: true),
                                          ),
                                        ),
                                        _pane(
                                          _inbox,
                                          _visited.contains(_inbox)
                                              ? InboxPage(account: account, api: session.api!, todoToken: _todoToken)
                                              : const SizedBox(),
                                        ),
                                        // Explore stays built from the start so a launcher search
                                        // or a Home action reaches it through its tokens.
                                        _pane(
                                          _explore,
                                          ProjectsPage(
                                            session: session,
                                            shortcuts: widget.shortcuts,
                                            searchToken: _searchToken,
                                            locatorToken: _locatorToken,
                                            createToken: _createToken,
                                            openLink: _incomingLink,
                                          ),
                                        ),
                                        _pane(
                                          _me,
                                          _visited.contains(_me)
                                              ? _buildMyTab(context, account, session)
                                              : const SizedBox(),
                                        ),
                                      ],
                                      ),
                                    ),
                                    ),
                                  ),
                                ],
                              );
                              return MediaQuery.removePadding(
                                key: const ValueKey('shell-content-padding'),
                                context: contentContext,
                                removeLeft: useRail && isLtr,
                                removeRight: useRail && !isLtr,
                                child: content,
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                  bottomNavigationBar: useRail ? null : _bottomNavigation(context),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
