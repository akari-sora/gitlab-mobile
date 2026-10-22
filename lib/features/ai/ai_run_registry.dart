import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/gitlab_api.dart';
import '../../core/ai/tools/write_coordinator.dart';
import '../auth/session_controller.dart';
import 'ai_chat_controller.dart';
import 'ai_chat_session.dart';
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
  );
  return (
    session: controller,
    capacityChanged: controller.notifyCapacityChanged,
    dispose: controller.dispose,
  );
}

/// Conversations owned by one exact authenticated account generation.
///
/// The registry is deliberately invalid after an account/API transition. A
/// new authenticated shell creates a new registry; no session can cross that
/// boundary even when two accounts happen to have similar resource keys.
final class AccountAiRunRegistry extends ChangeNotifier
    implements AiRunRegistry, AiWriteSettlementSource {
  AccountAiRunRegistry({
    required SessionController session,
    required this.settings,
    AiChatSessionFactory? sessionFactory,
    this.wireClientFactory,
  }) : _session = session,
       _sessionFactory = sessionFactory ?? _createAiChatSession,
       generation = session.generation,
       accountKey =
           session.active?.key ??
           (throw StateError('An AI run registry requires an active account')),
       api =
           session.api ??
           (throw StateError('An AI run registry requires an active API')) {
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
  final Map<String, AiChatSessionHandle> _sessions =
      <String, AiChatSessionHandle>{};
  var _disposed = false;

  /// Open pages per session; release drops a session only after the last.
  final Map<AiChatSession, int> _visits = {};
  var _lastRunningCount = 0;
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
    final existing = _sessions[origin.key];
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
    _sessions[origin.key] = handle;
    _visits[handle.session] = 1;
    handle.session.addListener(_handleSessionChanged);
    _lastRunningCount = runningCount;
    return handle.session;
  }

  @override
  int get runningCount => _sessions.values.where((handle) {
    final phase = handle.session.phase;
    return phase == AiChatPhase.running || phase == AiChatPhase.stopping;
  }).length;

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
    final next = runningCount;
    if (next == _lastRunningCount) return;
    _lastRunningCount = next;
    notifyListeners();
    // Idle pages rebuild both when capacity fills (they must show why they
    // cannot send) and when it opens again.
    _scheduleCapacityRecheck();
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
    handle.dispose();
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
    for (final handle in handles) {
      handle.session.removeListener(_handleSessionChanged);
    }
    for (final handle in handles) {
      handle.session.stop();
      handle.dispose();
    }
    super.dispose();
  }
}
