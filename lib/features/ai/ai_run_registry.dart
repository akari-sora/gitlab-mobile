import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../core/gitlab_api.dart';
import '../../core/ai/tools/write_coordinator.dart';
import '../auth/session_controller.dart';
import 'ai_chat_controller.dart';
import 'ai_chat_session.dart';
import 'ai_background_execution.dart';
import 'ai_stores.dart';

/// A session plus the cleanup operation for its concrete implementation.
///
/// Keeping disposal beside the session lets tests inject a small
/// [AiChatSession] without widening that page-facing interface.
typedef AiChatSessionHandle = ({
  AiChatSession session,
  VoidCallback capacityChanged,
  VoidCallback dispose,
});

typedef AiChatSessionFactory =
    AiChatSessionHandle Function({
      required AiChatOrigin origin,
      required SessionController session,
      required AiSettingsController settings,
      required int Function() runningCount,
      AiChatWireClientFactory? wireClientFactory,
    });

AiChatSessionHandle _createAiChatSession({
  required AiChatOrigin origin,
  required SessionController session,
  required AiSettingsController settings,
  required int Function() runningCount,
  AiChatWireClientFactory? wireClientFactory,
}) {
  final controller = AiChatController(
    origin: origin,
    session: session,
    settings: settings,
    runningCount: runningCount,
    wireClientFactory: wireClientFactory,
    appInForeground: aiAppInForeground,
    clientMayStart: aiClientMayStart(session),
  );
  return (
    session: controller,
    capacityChanged: controller.notifyCapacityChanged,
    dispose: controller.dispose,
  );
}

/// Whether the app is on screen. Until MR6c adds the foreground service, a
/// write starts only while the app is visible.
bool aiAppInForeground() => switch (WidgetsBinding.instance.lifecycleState) {
  AppLifecycleState.resumed || AppLifecycleState.inactive => true,
  _ => false,
};

/// The write gate's client check for [session]'s current API: open, and not
/// waiting out a 429.
bool Function() aiClientMayStart(SessionController session) {
  final api = session.api;
  return () => api != null && api.mayStartRequest;
}

/// Conversations owned by one exact authenticated account generation.
///
/// The registry is deliberately invalid after an account/API transition. A
/// new authenticated shell creates a new registry; no session can cross that
/// boundary even when two accounts happen to have similar resource keys.
final class AccountAiRunRegistry extends ChangeNotifier
    implements AiRunRegistry, AiExecutionRunRegistry, AiWriteSettlementSource {
  AccountAiRunRegistry({
    required SessionController session,
    required this.settings,
    AiChatSessionFactory? sessionFactory,
    this.wireClientFactory,
    AiBackgroundExecution? backgroundExecution,
  }) : _session = session,
       _sessionFactory = sessionFactory ?? _createAiChatSession,
       generation = session.generation,
       accountKey =
           session.active?.key ??
           (throw StateError('An AI run registry requires an active account')),
       api =
           session.api ??
           (throw StateError('An AI run registry requires an active API')) {
    this.backgroundExecution =
        backgroundExecution ??
        AiBackgroundExecution(
          accountKey: accountKey,
          generation: generation,
          ownerApi: api,
          isCurrent: () => ownsCurrentSession,
          appInForeground: aiAppInForeground,
        );
    _session.addListener(_handleOwnerChanged);
  }

  final SessionController _session;
  final AiSettingsController settings;
  final AiChatSessionFactory _sessionFactory;

  /// Shared by every conversation in this registry. Tests can inject a
  /// transport-backed factory once and assert all sessions use it.
  final AiChatWireClientFactory? wireClientFactory;

  final int generation;
  final String accountKey;
  final GitLabApi api;
  late final AiBackgroundExecution backgroundExecution;
  final Map<String, AiChatSessionHandle> _sessions =
      <String, AiChatSessionHandle>{};
  var _disposed = false;

  /// Open pages per session; release drops a session only after the last.
  final Map<AiChatSession, int> _visits = {};
  var _lastRunningCount = 0;
  var _lastServiceWorkCount = 0;
  var _lastBackProtectedCount = 0;
  final _notificationEvents =
      StreamController<AiRunNotificationEvent>.broadcast(sync: true);
  final _eventSubscriptions =
      <AiChatSession, StreamSubscription<AiRunNotificationEvent>>{};
  final _deliveredEventKinds = <AiChatSession, Set<AiRunNotificationKind>>{};
  final _notificationStates =
      <AiChatSession, ({String id, AiChatPhase phase})>{};
  var _capacityRecheckScheduled = false;

  bool get isDisposed => _disposed;

  bool get ownsCurrentSession =>
      !_disposed &&
      _session.generation == generation &&
      _session.active?.key == accountKey &&
      identical(_session.api, api) &&
      !api.isClosed;

  @override
  AiChatSession open(AiChatOrigin origin) {
    if (!ownsCurrentSession) {
      _invalidate();
      throw StateError('The AI run registry is no longer current');
    }
    // Origins supply resource/entry coordinates only. This registry supplies
    // the exact account, generation and API boundary, including after renames.
    final key = origin.key;
    final existing = _sessions[key];
    if (existing != null) {
      _visits[existing.session] = (_visits[existing.session] ?? 0) + 1;
      return existing.session;
    }

    final handle = _sessionFactory(
      origin: origin,
      session: _session,
      settings: settings,
      runningCount: () => runningCount,
      wireClientFactory: wireClientFactory,
    );
    if (!ownsCurrentSession) {
      handle.session.stop();
      handle.dispose();
      throw StateError('The AI run registry changed while opening a session');
    }
    if (handle.session case AiChatController controller) {
      try {
        controller.bindBackgroundExecution(backgroundExecution);
      } catch (_) {
        try {
          handle.session.stop();
        } finally {
          handle.dispose();
        }
        rethrow;
      }
    }
    _sessions[key] = handle;
    _syncNotificationState(handle.session);
    _visits[handle.session] = 1;
    handle.session.addListener(_handleSessionChanged);
    if (handle.session case AiRunNotificationSource source) {
      _eventSubscriptions[handle.session] = source.notificationEvents.listen((
        event,
      ) {
        if (!ownsCurrentSession ||
            !_sessions.values.any(
              (h) => identical(h.session, handle.session),
            ) ||
            event.generation != generation ||
            handle.session.id != event.conversationId ||
            (handle.session is AiChatController &&
                (handle.session as AiChatController).isDisposed)) {
          return;
        }
        _syncNotificationState(handle.session);
        if (!_deliveredEventKinds[handle.session]!.add(event.kind)) return;
        _notificationEvents.add(event);
      });
    }
    _lastRunningCount = runningCount;
    _lastServiceWorkCount = serviceWorkCount;
    _lastBackProtectedCount = backProtectedCount;
    return handle.session;
  }

  @override
  int get runningCount => _sessions.values.where((handle) {
    final phase = handle.session.phase;
    return phase == AiChatPhase.running || phase == AiChatPhase.stopping;
  }).length;

  @override
  int get serviceWorkCount => _sessions.values.where((handle) {
    final chat = handle.session;
    if (chat case AiExecutionChatSession source) {
      return source.serviceWorkCount > 0;
    }
    final settling = switch (chat) {
      AiWriteSettlementSource source => source.inFlightWrites.isNotEmpty,
      _ => false,
    };
    return chat.phase == AiChatPhase.running ||
        chat.phase == AiChatPhase.stopping ||
        settling;
  }).length;

  @override
  int get backProtectedCount => _sessions.values.where((handle) {
    final chat = handle.session;
    if (chat case AiExecutionChatSession source) {
      return source.backProtectedCount > 0;
    }
    return chat.phase == AiChatPhase.running ||
        chat.phase == AiChatPhase.stopping ||
        chat.phase == AiChatPhase.awaitingApproval;
  }).length;

  @override
  Stream<AiRunNotificationEvent> get notificationEvents =>
      _notificationEvents.stream;

  /// Looks only in the current in-memory owner; never opens or restores a chat.
  @override
  AiChatSession? sessionForConversation(String conversationId, int generation) {
    if (!ownsCurrentSession || generation != this.generation) return null;
    for (final handle in _sessions.values) {
      final chat = handle.session;
      if (chat is AiChatController && chat.isDisposed) continue;
      if (chat.id == conversationId) return chat;
    }
    return null;
  }

  /// Packet 9 snapshots these before changing the account/API generation.
  @override
  List<Future<AiWriteOutcome>> get inFlightWrites => List.unmodifiable([
    for (final source
        in _sessions.values
            .map((handle) => handle.session)
            .whereType<AiWriteSettlementSource>())
      ...source.inFlightWrites,
  ]);

  List<Future<AiWriteOutcome>> stopAndSnapshotWrites() {
    for (final handle in _sessions.values.toList(growable: false)) {
      handle.session.stop();
    }
    return inFlightWrites;
  }

  void _handleSessionChanged() {
    if (_disposed) return;
    for (final handle in _sessions.values) {
      _syncNotificationState(handle.session);
    }
    final next = runningCount;
    final service = serviceWorkCount;
    final back = backProtectedCount;
    if (next == _lastRunningCount &&
        service == _lastServiceWorkCount &&
        back == _lastBackProtectedCount) {
      return;
    }
    final capacityChanged = next != _lastRunningCount;
    _lastRunningCount = next;
    _lastServiceWorkCount = service;
    _lastBackProtectedCount = back;
    notifyListeners();
    // Idle pages rebuild both when capacity fills (they must show why they
    // cannot send) and when it opens again.
    if (capacityChanged) _scheduleCapacityRecheck();
  }

  void _syncNotificationState(AiChatSession chat) {
    if (chat is! AiRunNotificationSource) return;
    final previous = _notificationStates[chat];
    final kinds = _deliveredEventKinds.putIfAbsent(chat, () => {});
    if (previous == null ||
        previous.id != chat.id ||
        (chat.phase == AiChatPhase.running &&
            (previous.phase == AiChatPhase.idle ||
                previous.phase == AiChatPhase.preparing))) {
      kinds.clear();
    } else if (chat.phase == AiChatPhase.awaitingApproval &&
        previous.phase != AiChatPhase.awaitingApproval) {
      kinds.remove(AiRunNotificationKind.needsApproval);
    }
    _notificationStates[chat] = (id: chat.id, phase: chat.phase);
  }

  void _scheduleCapacityRecheck() {
    if (_capacityRecheckScheduled || _disposed) return;
    _capacityRecheckScheduled = true;
    scheduleMicrotask(() {
      _capacityRecheckScheduled = false;
      if (_disposed) return;
      final callbacks = <VoidCallback>[
        for (final handle in _sessions.values)
          if (handle.session.phase == AiChatPhase.idle) handle.capacityChanged,
      ];
      for (final callback in callbacks) {
        callback();
      }
    });
  }

  @override
  void release(AiChatSession session) {
    if (_disposed) return;
    final visits = (_visits[session] ?? 1) - 1;
    if (visits > 0) {
      // Another page still shows this session.
      _visits[session] = visits;
      return;
    }
    _visits.remove(session);
    final key = _sessions.entries
        .where((entry) => identical(entry.value.session, session))
        .map((entry) => entry.key)
        .firstOrNull;
    if (key == null) return;
    final phase = session.phase;
    if (phase == AiChatPhase.running ||
        phase == AiChatPhase.stopping ||
        phase == AiChatPhase.awaitingApproval ||
        session.proposals.isNotEmpty ||
        session.items.isNotEmpty) {
      return;
    }
    final handle = _sessions.remove(key)!;
    session.removeListener(_handleSessionChanged);
    unawaited(_eventSubscriptions.remove(session)?.cancel());
    _deliveredEventKinds.remove(session);
    _notificationStates.remove(session);
    handle.dispose();
    _handleSessionChanged();
  }

  void _handleOwnerChanged() {
    if (!ownsCurrentSession) _invalidate();
  }

  void _invalidate() => dispose();

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _visits.clear();
    _session.removeListener(_handleOwnerChanged);
    final handles = _sessions.values.toList(growable: false);
    _sessions.clear();
    for (final subscription in _eventSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    _eventSubscriptions.clear();
    _deliveredEventKinds.clear();
    _notificationStates.clear();
    unawaited(_notificationEvents.close());
    for (final handle in handles) {
      handle.session.removeListener(_handleSessionChanged);
    }
    for (final handle in handles) {
      handle.session.stop();
      handle.dispose();
    }
    backgroundExecution.dispose();
    super.dispose();
  }
}
