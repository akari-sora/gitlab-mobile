import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../core/ai/tools/write_coordinator.dart';
import 'ai_chat_session.dart';
import 'ai_stores.dart';

/// The UI supplies translated, generic text. No account, resource, prompt or
/// model output is passed to this provider. Read it again for every delivery
/// so an in-app language change does not retain the previous language.
final class AiRunNotificationText {
  const AiRunNotificationText({
    required this.approvalChannelName,
    required this.resultChannelName,
    required this.title,
    required this.needsApproval,
    required this.completed,
    required this.failed,
    required this.interrupted,
  });

  final String approvalChannelName;
  final String resultChannelName;
  final String title;
  final String needsApproval;
  final String completed;
  final String failed;
  final String interrupted;

  String bodyFor(AiRunNotificationKind kind) => switch (kind) {
    AiRunNotificationKind.needsApproval => needsApproval,
    AiRunNotificationKind.completed => completed,
    AiRunNotificationKind.failed => failed,
    AiRunNotificationKind.interrupted => interrupted,
  };
}

/// The only notification payload: routing coordinates, never approval data.
final class AiRunNotificationRoute {
  const AiRunNotificationRoute({
    required this.conversationId,
    required this.generation,
  });

  final String conversationId;
  final int generation;

  String encode() =>
      jsonEncode({'conversationId': conversationId, 'generation': generation});

  static AiRunNotificationRoute? decode(String? payload) {
    if (payload == null || payload.length > 512) return null;
    try {
      final value = jsonDecode(payload);
      if (value is! Map<String, dynamic> ||
          value.length != 2 ||
          value['conversationId'] is! String ||
          value['generation'] is! int) {
        return null;
      }
      final id = value['conversationId'] as String;
      final generation = value['generation'] as int;
      if (!RegExp(r'^[A-Za-z0-9._:-]{1,128}$').hasMatch(id) ||
          generation < 0 ||
          generation > 9007199254740991) {
        return null;
      }
      return AiRunNotificationRoute(conversationId: id, generation: generation);
    } on FormatException {
      return null;
    }
  }
}

/// A tap waiting for the existing app lock. This carries no navigation or
/// approval authority; [AiRunNotifications.takePendingOpen] rechecks membership.
final class AiRunPendingOpen {
  AiRunPendingOpen._(this.route, this._owner, this._session);

  final AiRunNotificationRoute route;
  final AiRunRegistry? _owner;
  final AiChatSession? _session;
}

/// A synchronous navigation decision, available only after unlock. A null
/// session means the shell's safe home; a null proposal means open the current
/// conversation without trying to locate an approval card.
final class AiRunNotificationOpen {
  const AiRunNotificationOpen._(this._pending, {this.session, this.proposal});

  final AiRunPendingOpen _pending;
  final AiChatSession? session;
  final AiWriteProposal? proposal;
}

/// Safe reason codes for the UI; platform exceptions and content stay private.
enum AiRunNotificationFailure {
  initialization,
  permission,
  delivery,
  idRangeFull,
}

/// App permission and channel settings are independent. Unknown channel state
/// must not hide a known app permission or claim that approval reminders are off.
final class AiRunNotificationState {
  const AiRunNotificationState({
    this.appEnabled,
    this.approvalChannelEnabled,
    this.resultChannelEnabled,
  });

  final bool? appEnabled;
  final bool? approvalChannelEnabled;
  final bool? resultChannelEnabled;

  bool get approvalRemindersDisabled =>
      appEnabled == false || approvalChannelEnabled == false;
}

/// Device-lifetime notification owner, above the account-keyed shell. Bind the
/// current registry and unbind it on sign-out. This never opens/restores chats,
/// switches accounts, approves writes, or invokes an app-lock authenticator.
final class AiRunNotifications extends ChangeNotifier {
  AiRunNotifications({
    required AiRunNotificationText Function() text,
    AiRunNoticeStore? noticeStore,
  }) : _text = text,
       _noticeStore = noticeStore ?? SecureAiRunNoticeStore();

  static const approvalFirstId = 6200;
  static const approvalLastId = 6299;
  static const resultFirstId = 6300;
  static const resultLastId = 6399;

  final AiRunNotificationText Function() _text;
  final AiRunNoticeStore _noticeStore;
  final _plugin = FlutterLocalNotificationsPlugin();
  final _approvalIds = _NotificationIds(approvalFirstId, approvalLastId);
  final _resultIds = _NotificationIds(resultFirstId, resultLastId);
  final _approvalWatches = <int, ({VoidCallback check, VoidCallback stop})>{};
  final _pendingApprovalCancellations = <int>{};
  AiRunRegistry? _registry;
  StreamSubscription<AiRunNotificationEvent>? _events;
  Future<bool>? _initialization;
  Future<void> _delivery = Future<void>.value();
  AiRunPendingOpen? _pending;
  int _openSequence = 0;
  bool _disposed = false;
  bool _ready = false;
  AiRunNotificationFailure? _failure;
  bool _resultRangeFull = false;

  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get available => !_disposed && _ready && failure == null;
  AiRunNotificationFailure? get failure =>
      _failure ??
      (_resultRangeFull ? AiRunNotificationFailure.idRangeFull : null);
  AiRunPendingOpen? get pendingOpen => _pending;

  @visibleForTesting
  int get debugApprovalWatchCount => _approvalWatches.length;

  Future<bool> wasPermissionAsked() async {
    try {
      return await _noticeStore.readAsked();
    } catch (_) {
      return false;
    }
  }

  Future<void> _rememberPermissionAsked() async {
    try {
      await _noticeStore.markAsked();
    } catch (_) {
      // Leave the marker absent so the next send can ask and retry the write.
    }
  }

  /// Call once before run events. Repeated calls share the same Future and do
  /// not cancel notifications again. Only C3 owns this startup cancellation:
  /// 6200–6299, preserving result notifications and native FGS ID 6100.
  Future<bool> initialize() =>
      _disposed ? Future<bool>.value(false) : _initialization ??= _initialize();

  Future<bool> _initialize() async {
    if (_disposed || !supported) return false;
    final launchSequence = _openSequence;
    try {
      final initialized = await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('ic_ai_runs'),
        ),
        onDidReceiveNotificationResponse: _receiveResponse,
      );
      if (_disposed) return false;
      if (initialized != true) {
        _setFailure(AiRunNotificationFailure.initialization);
        return false;
      }
      // Read the launch intent before clearing old approval notifications.
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (_disposed) return false;
      // A newer warm tap during initialization takes precedence.
      if (launchSequence == _openSequence &&
          launch?.didNotificationLaunchApp == true) {
        final response = launch?.notificationResponse;
        if (response != null) _receiveResponse(response);
      }
      for (var id = approvalFirstId; id <= approvalLastId; id++) {
        if (_disposed) return false;
        await _plugin.cancel(id: id);
      }
      // Results survive process death. Android exposes their IDs, but not
      // routing payloads: reserve anonymous occupied slots instead of treating
      // a new process's empty allocator as an empty notification drawer.
      await _refreshResultReservations();
      if (_disposed) return false;
      _ready = !_disposed;
      notifyListeners();
      return _ready;
    } catch (_) {
      // No payload, exception text, or content is logged. The UI can disclose
      // unavailable reminders without changing execution authorization.
      _setFailure(AiRunNotificationFailure.initialization);
      return false;
    }
  }

  /// Permission is requested only when the UI explicitly calls this method.
  /// Initializing and receiving run events never prompt the user.
  Future<bool?> requestPermission() async {
    if (!await initialize() || _disposed) return null;
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android == null) return null;
      final allowed = await android.requestNotificationsPermission();
      await _rememberPermissionAsked();
      return allowed;
    } catch (_) {
      _setFailure(AiRunNotificationFailure.permission);
      return null;
    }
  }

  /// Android's current app permission and the two notification channels.
  /// Missing channels have not been created yet; a blocked channel has none
  /// importance. Unsupported platforms or unreadable state remain unknown.
  Future<AiRunNotificationState> areNotificationsEnabled() async {
    if (!await initialize() || _disposed) {
      return const AiRunNotificationState();
    }
    bool? appEnabled;
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      appEnabled = await android?.areNotificationsEnabled();
      if (_disposed) return const AiRunNotificationState();
      if (appEnabled != true) {
        return AiRunNotificationState(appEnabled: appEnabled);
      }
      final channels = await android?.getNotificationChannels();
      if (_disposed) return const AiRunNotificationState();
      return AiRunNotificationState(
        appEnabled: appEnabled,
        approvalChannelEnabled: channels == null
            ? null
            : !channels.any(
                (channel) =>
                    channel.id == 'ai_run_approvals_v1' &&
                    channel.importance == Importance.none,
              ),
        resultChannelEnabled: channels == null
            ? null
            : !channels.any(
                (channel) =>
                    channel.id == 'ai_run_results_v1' &&
                    channel.importance == Importance.none,
              ),
      );
    } catch (_) {
      return AiRunNotificationState(appEnabled: _disposed ? null : appEnabled);
    }
  }

  void _setFailure(AiRunNotificationFailure? failure) {
    if (_disposed || _failure == failure) return;
    _failure = failure;
    notifyListeners();
  }

  Future<void> _refreshResultReservations() async {
    final active = await _plugin.getActiveNotifications();
    if (_disposed) return;
    _resultIds.reserveActive([
      for (final notification in active)
        if (notification.id != null && notification.tag == null)
          notification.id!,
    ]);
  }

  void _setResultRangeFull(bool full) {
    if (_disposed || _resultRangeFull == full) return;
    _resultRangeFull = full;
    notifyListeners();
  }

  void bindRegistry(AiRunRegistry? registry) {
    if (_disposed) return;
    if (_pendingApprovalCancellations.isNotEmpty) {
      _delivery = _delivery.then((_) => _retryApprovalCancellations());
    }
    if (identical(_registry, registry)) return;
    unawaited(_events?.cancel());
    _registry = registry;
    for (final watch in _approvalWatches.values.toList()) {
      watch.check();
    }
    _events = registry?.notificationEvents.listen(
      (event) => _enqueue(registry, event),
      onError: (Object _) {},
    );
    // A cold tap may arrive before authentication has bound the first owner.
    // Once captured, even a missing session stays bound to that owner.
    final pending = _pending;
    if (registry != null && pending != null && pending._owner == null) {
      _pending = _capture(pending.route);
    }
    if (_pending != null) notifyListeners();
  }

  bool _current(
    AiRunRegistry owner,
    AiChatSession session,
    AiRunNotificationRoute route,
  ) =>
      !_disposed &&
      identical(owner, _registry) &&
      session.id == route.conversationId &&
      identical(
        owner.sessionForConversation(route.conversationId, route.generation),
        session,
      );

  bool _awaitingApproval(AiChatSession session) =>
      session.phase == AiChatPhase.awaitingApproval &&
      session.proposals.any(
        (proposal) =>
            proposal.valid && DateTime.now().isBefore(proposal.expiresAt),
      );

  /// The registry's public lookup returns a Listenable session. Its changes
  /// include proposal settlement/expiry even when registry counts stay equal.
  void _watchApproval(
    AiRunRegistry owner,
    AiChatSession session,
    AiRunNotificationRoute route,
    String payload,
    int id,
  ) {
    _approvalWatches.remove(id)?.stop();
    late final VoidCallback check;
    void stop() => session.removeListener(check);
    check = () {
      if (_disposed ||
          (_current(owner, session, route) && _awaitingApproval(session))) {
        return;
      }
      if (!identical(_approvalWatches[id]?.stop, stop)) return;
      _approvalWatches.remove(id)?.stop();
      _approvalIds.remove(payload);
      // Reserve only the ID until cancellation succeeds. Neither the retry
      // state nor its queued work retains the old session/owner callbacks.
      _pendingApprovalCancellations.add(id);
      _approvalIds.reserveActive(_pendingApprovalCancellations);
      _scheduleApprovalCancellation(id);
    };
    _approvalWatches[id] = (check: check, stop: stop);
    session.addListener(check);
  }

  void _scheduleApprovalCancellation(int id) {
    // Run after any in-flight show, without capturing its owner/session.
    _delivery = _delivery.then((_) => _cancelApproval(id));
  }

  Future<void> _cancelApproval(int id) async {
    if (_disposed || !_pendingApprovalCancellations.contains(id)) return;
    try {
      await _plugin.cancel(id: id);
      _pendingApprovalCancellations.remove(id);
      _approvalIds.reserveActive(_pendingApprovalCancellations);
      if (_pendingApprovalCancellations.isEmpty &&
          _failure == AiRunNotificationFailure.delivery) {
        _setFailure(null);
      }
    } catch (_) {
      _setFailure(AiRunNotificationFailure.delivery);
    }
  }

  Future<void> _retryApprovalCancellations() async {
    for (final id in _pendingApprovalCancellations.toList()) {
      await _cancelApproval(id);
    }
  }

  void _enqueue(AiRunRegistry owner, AiRunNotificationEvent event) {
    if (_disposed || !identical(owner, _registry)) return;
    final route = AiRunNotificationRoute(
      conversationId: event.conversationId,
      generation: event.generation,
    );
    final session = owner.sessionForConversation(
      route.conversationId,
      route.generation,
    );
    if (session == null ||
        AiRunNotificationRoute.decode(route.encode()) == null) {
      return;
    }
    _delivery = _delivery
        .then((_) async {
          if (!await initialize() || !_current(owner, session, route)) return;
          await _retryApprovalCancellations();
          if (!_current(owner, session, route)) return;
          final approval = event.kind == AiRunNotificationKind.needsApproval;
          if (approval && !_awaitingApproval(session)) return;
          final payload = route.encode();
          final ids = approval ? _approvalIds : _resultIds;
          var id = ids.allocate(payload);
          if (id == null && !approval) {
            // Dismissed retained results free slots during this process too.
            await _refreshResultReservations();
            if (!_current(owner, session, route)) return;
            id = ids.allocate(payload);
          }
          id ??= ids.replaceOldest(payload);
          if (id == null) {
            _setResultRangeFull(true);
            return;
          }
          if (!approval) _setResultRangeFull(false);
          final text = _text();
          if (approval) _watchApproval(owner, session, route, payload, id);
          await _plugin.show(
            id: id,
            title: text.title,
            body: text.bodyFor(event.kind),
            notificationDetails: NotificationDetails(
              android: AndroidNotificationDetails(
                approval ? 'ai_run_approvals_v1' : 'ai_run_results_v1',
                approval ? text.approvalChannelName : text.resultChannelName,
                icon: 'ic_ai_runs',
                importance: approval
                    ? Importance.high
                    : Importance.defaultImportance,
                priority: approval ? Priority.high : Priority.defaultPriority,
                visibility: NotificationVisibility.private,
              ),
            ),
            payload: payload,
          );
          if (_pendingApprovalCancellations.isEmpty) _setFailure(null);
        })
        .catchError((Object _) {
          _setFailure(AiRunNotificationFailure.delivery);
        });
  }

  void _receiveResponse(NotificationResponse response) {
    if (_disposed ||
        response.notificationResponseType !=
            NotificationResponseType.selectedNotification ||
        (response.actionId?.isNotEmpty ?? false) ||
        response.input != null) {
      return;
    }
    final route = AiRunNotificationRoute.decode(response.payload);
    if (route == null) return;
    _openSequence++;
    _pending = _capture(route);
    notifyListeners();
  }

  AiRunPendingOpen _capture(AiRunNotificationRoute route) => AiRunPendingOpen._(
    route,
    _registry,
    _registry?.sessionForConversation(route.conversationId, route.generation),
  );

  /// Both cold and warm taps arrive here. Call synchronously just before
  /// navigation, after AppLockGate has loaded and actually unlocked. A refused
  /// or cancelled unlock returns null and performs no navigation. The shell
  /// may [discardPendingOpen] on cancellation; no authentication is retried.
  AiRunNotificationOpen? takePendingOpen({
    required bool appLockLoaded,
    required bool appLockUnlocked,
  }) {
    if (_disposed || !appLockLoaded || !appLockUnlocked || _pending == null) {
      return null;
    }
    final pending = _pending!;
    _pending = null;
    final owner = pending._owner;
    final session = pending._session;
    if (owner == null ||
        session == null ||
        !_current(owner, session, pending.route)) {
      return AiRunNotificationOpen._(pending);
    }
    final now = DateTime.now();
    final proposals = session.proposals.where(
      (proposal) => proposal.valid && now.isBefore(proposal.expiresAt),
    );
    return AiRunNotificationOpen._(
      pending,
      session: session,
      proposal: proposals.firstOrNull,
    );
  }

  void discardPendingOpen() {
    _openSequence++;
    _pending = null;
  }

  /// The shell may have awaited an editor exit since consuming this decision.
  bool isCurrentOpen(AiRunNotificationOpen open) {
    final pending = open._pending;
    final owner = pending._owner;
    return !_disposed &&
        owner != null &&
        identical(owner, _registry) &&
        (open.session == null || _current(owner, open.session!, pending.route));
  }

  @override
  void dispose() {
    _disposed = true;
    _pending = null;
    _registry = null;
    unawaited(_events?.cancel());
    for (final watch in _approvalWatches.values) {
      watch.stop();
    }
    _approvalWatches.clear();
    _pendingApprovalCancellations.clear();
    super.dispose();
  }
}

/// Bounded probing resolves hash collisions. At capacity, replace the oldest
/// notification in this same range and remove its reverse mapping atomically.
final class _NotificationIds {
  _NotificationIds(this.first, this.last);
  final int first;
  final int last;
  final _byPayload = <String, int>{};
  final _byId = <int, String>{};
  final _reserved = <int>{};

  void remove(String payload) {
    final id = _byPayload.remove(payload);
    if (id != null) _byId.remove(id);
  }

  void reserveActive(Iterable<int> ids) {
    _reserved
      ..clear()
      ..addAll(
        ids.where((id) => id >= first && id <= last && !_byId.containsKey(id)),
      );
  }

  int? allocate(String payload) {
    final existing = _byPayload[payload];
    if (existing != null) return existing;
    final size = last - first + 1;
    final slot = payload.hashCode % size;
    for (var offset = 0; offset < size; offset++) {
      final id = first + (slot + offset) % size;
      if (!_byId.containsKey(id) && !_reserved.contains(id)) {
        return _assign(payload, id);
      }
    }
    return null;
  }

  int? replaceOldest(String payload) {
    // If every slot belongs to an older process, keep its retained results.
    // Report the bounded capacity failure instead of overwriting unknown work.
    if (_byPayload.isEmpty) return null;
    final oldest = _byPayload.keys.first;
    final id = _byPayload.remove(oldest)!;
    return _assign(payload, id);
  }

  int _assign(String payload, int id) {
    _byPayload[payload] = id;
    _byId[id] = payload;
    return id;
  }
}
