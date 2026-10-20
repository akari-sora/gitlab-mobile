import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../core/failure.dart';
import '../../l10n/l10n.dart';
import '../auth/session_controller.dart';
import 'ai_history_codec.dart';
import 'ai_history_files.dart';
import 'ai_stores.dart';

export 'ai_history_codec.dart' show AiHistoryCipher;
export 'ai_history_files.dart';

enum AiHistoryState {
  unknown,
  disabled,
  ready,
  unavailable,
  keyMissing,
  cleaning,
}

final class _AccountHistory {
  AiHistoryState state = AiHistoryState.unknown;
  int epoch = 0;
  Uint8List? key;
  AiAccountRecord? record;
  Future<void>? tail;
  Future<void>? cleanup;
  Timer? retry;
  int attempts = 0;
  DateTime? retryAt;
  final Set<String> fullConversations = {};
  bool removedUnreadable = false;
  AiStoreFailure? failure;
}

/// Single owner of history operations, epochs and removal. It has no provider
/// scope dependency, and recovery/cleanup deliberately do not consult the gate.
final class AiHistoryCoordinator extends ChangeNotifier
    with WidgetsBindingObserver {
  AiHistoryCoordinator({
    required this.store,
    AiHistoryFileStore? files,
    DateTime Function()? clock,
  }) : files = files ?? AiHistoryFileStore(),
       _clock = clock ?? DateTime.now {
    this.files.canEvictAccount = (segment) {
      for (final entry in _accounts.entries) {
        if (aiHistoryAccountSegment(entry.key) == segment &&
            const {
              AiHistoryState.unavailable,
              AiHistoryState.keyMissing,
              AiHistoryState.cleaning,
            }.contains(entry.value.state)) {
          return false;
        }
      }
      return true;
    };
  }

  static AiHistoryCoordinator _instance = AiHistoryCoordinator(
    store: SecureAiStore(),
  );
  static AiHistoryCoordinator get instance => _instance;

  @visibleForTesting
  static AiHistoryCoordinator debugReset({
    AiStore? store,
    AiHistoryFileStore? files,
    DateTime Function()? clock,
  }) {
    _instance.dispose();
    return _instance = AiHistoryCoordinator(
      store: store ?? MemoryAiStore(),
      files: files,
      clock: clock,
    );
  }

  final AiStore store;
  final AiHistoryFileStore files;
  final DateTime Function() _clock;
  final Map<String, _AccountHistory> _accounts = {};
  final Map<SessionController, VoidCallback> _sessionListeners = {};
  final Set<Completer<void>> _waitingRecovery = {};
  bool _disposed = false;
  bool _watchingLifecycle = false;

  _AccountHistory _entry(String account) =>
      _accounts.putIfAbsent(account, _AccountHistory.new);
  AiHistoryState state(String account) => _entry(account).state;
  bool storageLimitReached(String account, String id) =>
      _entry(account).fullConversations.contains(id);
  AiStoreFailure? failure(String account) => _entry(account).failure;
  bool removedUnreadable(String account) => _entry(account).removedUnreadable;
  String? notice(String account, {String? conversationId}) {
    final entry = _entry(account);
    if (entry.failure?.kind == AiStoreFailureKind.malformed) {
      return l10n.aiHistoryInvalidData;
    }
    if (conversationId != null &&
        entry.fullConversations.contains(conversationId)) {
      return l10n.aiHistoryStorageLimit;
    }
    if (entry.removedUnreadable) return l10n.aiHistoryRemovedUnreadable;
    return switch (entry.state) {
      AiHistoryState.unavailable => l10n.aiHistoryUnavailable,
      AiHistoryState.keyMissing => l10n.aiHistoryKeyMissing,
      _ => null,
    };
  }

  Future<T> _run<T>(
    String account,
    Future<T> Function(_AccountHistory) action,
  ) {
    final entry = _entry(account);
    final previous = entry.tail;
    final result = previous == null
        ? action(entry)
        : previous.then((_) => action(entry));
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    entry.tail = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(entry.tail, tail)) entry.tail = null;
      }),
    );
    return result;
  }

  bool _current(_AccountHistory entry, int epoch) =>
      !_disposed &&
      entry.epoch == epoch &&
      entry.state != AiHistoryState.cleaning;
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<AiHistoryState> load(String account) => _run(account, (entry) async {
    await _load(account, entry);
    return entry.state;
  });

  Future<void> _load(
    String account,
    _AccountHistory entry, {
    bool force = false,
  }) async {
    if (_disposed || entry.state == AiHistoryState.cleaning) return;
    if (!force && entry.state != AiHistoryState.unknown) {
      if (entry.state != AiHistoryState.unavailable ||
          entry.attempts > 3 ||
          (entry.retryAt != null && _clock().isBefore(entry.retryAt!))) {
        return;
      }
    }
    final epoch = entry.epoch;
    try {
      final tombstone = await store.readTombstone(account);
      if (!_current(entry, epoch)) return;
      if (tombstone.failure != null) {
        _unavailable(account, entry, failure: tombstone.failure);
        return;
      }
      if (tombstone.value == true) {
        entry.state = AiHistoryState.cleaning;
        entry.key = null;
        _emit();
        return;
      }
      final record = await store.loadAccount(account);
      if (!_current(entry, epoch)) return;
      if (record.failure != null) {
        _unavailable(account, entry, failure: record.failure);
        return;
      }
      entry.failure = null;
      entry.record = record.value ?? AiAccountRecord();
      if (!entry.record!.historyEnabled) {
        entry.state = AiHistoryState.disabled;
        entry.key = null;
        _emit();
        return;
      }
      final key = await store.readHistoryKey(account);
      if (!_current(entry, epoch)) return;
      switch (key.status) {
        case AiStoreReadStatus.found:
          entry.failure = null;
          entry.key = Uint8List.fromList(key.value!);
          entry.state = AiHistoryState.ready;
          entry.attempts = 0;
          entry.retryAt = null;
          entry.retry?.cancel();
        case AiStoreReadStatus.absent:
          if (key.failure != null) {
            _unavailable(account, entry, failure: key.failure);
            return;
          }
          entry.key = null;
          entry.state = AiHistoryState.keyMissing;
        case AiStoreReadStatus.unavailable:
          _unavailable(account, entry);
          return;
      }
      _emit();
    } catch (_) {
      if (_current(entry, epoch)) _unavailable(account, entry);
    }
  }

  void _watchLifecycle() {
    if (_watchingLifecycle || _disposed) return;
    WidgetsBinding.instance.addObserver(this);
    _watchingLifecycle = true;
  }

  void _unavailable(
    String account,
    _AccountHistory entry, {
    AiStoreFailure? failure,
  }) {
    entry.failure = failure;
    entry.state = AiHistoryState.unavailable;
    entry.key = null;
    entry.retry?.cancel();
    entry.attempts++;
    if (entry.attempts <= 3 && failure?.kind != AiStoreFailureKind.malformed) {
      final delay = Duration(seconds: const [1, 5, 30][entry.attempts - 1]);
      entry.retryAt = _clock().add(delay);
      entry.retry = Timer(delay, () {
        if (!_disposed && entry.state == AiHistoryState.unavailable) {
          unawaited(
            _run(account, (value) => _load(account, value, force: true)),
          );
        }
      });
    }
    _watchLifecycle();
    _emit();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(onResume());
  }

  Future<void> onResume() async {
    for (final account in _accounts.keys.toList()) {
      if (_entry(account).state == AiHistoryState.unavailable) {
        await _run(account, (entry) => _load(account, entry, force: true));
      }
    }
  }

  Future<AiHistoryState> enable(String account) => _run(account, (entry) async {
    await _load(account, entry);
    if (entry.state != AiHistoryState.disabled) return entry.state;
    final epoch = entry.epoch;
    try {
      final result = await store.readHistoryKey(account);
      if (!_current(entry, epoch)) return entry.state;
      if (result.failure != null ||
          result.status == AiStoreReadStatus.unavailable) {
        _unavailable(account, entry);
        return entry.state;
      }
      final key = result.value ?? Uint8List.fromList(AiHistoryCipher.newKey());
      if (result.status == AiStoreReadStatus.absent) {
        await store.writeHistoryKey(account, key);
        if (!_current(entry, epoch)) return entry.state;
      }
      final latest = await store.loadAccount(account);
      if (!_current(entry, epoch)) return entry.state;
      if (latest.failure != null) {
        _unavailable(account, entry, failure: latest.failure);
        return entry.state;
      }
      final record = (latest.value ?? AiAccountRecord()).copyWith(
        historyEnabled: true,
      );
      await store.saveAccount(account, record);
      if (!_current(entry, epoch)) return entry.state;
      entry.key = Uint8List.fromList(key);
      entry.record = record;
      entry.state = AiHistoryState.ready;
      _emit();
    } catch (_) {
      if (_current(entry, epoch)) _unavailable(account, entry);
    }
    return entry.state;
  });

  Future<AiHistoryRecovery?> read(String account) =>
      _run(account, (entry) async {
        await _load(account, entry);
        if (entry.state != AiHistoryState.ready) return null;
        final epoch = entry.epoch;
        try {
          final result = await files.recover(
            account,
            Uint8List.fromList(entry.key!),
            entry.record!.retentionDays,
          );
          if (!_current(entry, epoch)) return null;
          entry.removedUnreadable = result.removedUnreadable;
          _emit();
          return result;
        } catch (_) {
          if (_current(entry, epoch)) {
            _unavailable(
              account,
              entry,
              failure: const AiStoreFailure(
                AiStoreFailureKind.unavailable,
                'readHistory',
              ),
            );
          }
          return null;
        }
      });

  Future<AiHistorySaveResult> save(
    String account,
    AiSavedConversation conversation,
  ) {
    final entry = _entry(account);
    final epoch = entry.epoch;
    if (entry.state == AiHistoryState.cleaning || _disposed) {
      return Future.value(AiHistorySaveResult.cancelled);
    }
    return _run(account, (entry) async {
      if (!_current(entry, epoch)) return AiHistorySaveResult.cancelled;
      await _load(account, entry);
      if (!_current(entry, epoch) || entry.state != AiHistoryState.ready) {
        return AiHistorySaveResult.cancelled;
      }
      if (entry.fullConversations.contains(conversation.id)) {
        return AiHistorySaveResult.storageLimit;
      }
      try {
        final result = await files.save(
          account,
          Uint8List.fromList(entry.key!),
          conversation,
          entry.record!.retentionDays,
          isCurrent: () => _current(entry, epoch),
        );
        if (!_current(entry, epoch)) return AiHistorySaveResult.cancelled;
        if (result == AiHistorySaveResult.storageLimit) {
          entry.fullConversations.add(conversation.id);
        }
        _emit();
        return result;
      } catch (_) {
        if (_current(entry, epoch)) {
          _unavailable(
            account,
            entry,
            failure: const AiStoreFailure(
              AiStoreFailureKind.unavailable,
              'saveHistory',
            ),
          );
        }
        return AiHistorySaveResult.cancelled;
      }
    });
  }

  /// Sets cleaning before any await, invalidates all queued snapshots, and drains
  /// writes before deleting keys/files. Failure never resumes a saved writer.
  Future<void> clearAccount(String account) {
    final entry = _entry(account);
    final existing = entry.cleanup;
    if (existing != null) return existing;
    final result = _clearAccount(account, entry);
    entry.cleanup = result;
    void released() {
      if (identical(entry.cleanup, result)) entry.cleanup = null;
    }

    unawaited(
      result.then<void>(
        (_) => released(),
        onError: (Object _, StackTrace _) => released(),
      ),
    );
    return result;
  }

  Future<void> _clearAccount(String account, _AccountHistory entry) async {
    entry.state = AiHistoryState.cleaning;
    entry.epoch++;
    entry.retry?.cancel();
    entry.retry = null;
    entry.key?.fillRange(0, entry.key!.length, 0);
    entry.key = null;
    entry.record = null;
    entry.fullConversations.clear();
    entry.removedUnreadable = false;
    entry.failure = null;
    final pending = entry.tail;
    _emit();
    try {
      await store.setTombstone(account);
      if (pending != null) await pending;
      await store.deleteHistoryKey(account);
      await files.deleteAccount(account);
      await store.deleteAccount(account);
      await store.clearTombstone(account);
      entry.state = AiHistoryState.disabled;
      _emit();
    } catch (_) {
      // A storage implementation can fail after performing the deletion.
      // Reassert the marker best-effort without exposing an untyped exception.
      try {
        await store.setTombstone(account);
      } catch (_) {}
      entry.state = AiHistoryState.cleaning;
      _emit();
      throw const ApiFailure(FailureKind.aiHistoryCleanup);
    }
  }

  Future<void> startRecovery(SessionController session) async {
    _watchLifecycle();
    if (_disposed) return;
    if (!session.accountsLoaded) {
      final loaded = Completer<void>();
      void listener() {
        if (session.accountsLoaded && !loaded.isCompleted) loaded.complete();
      }

      // Multiple calls must not leave stale listeners behind.
      final existing = _sessionListeners[session];
      if (existing != null) return;
      _sessionListeners[session] = listener;
      _waitingRecovery.add(loaded);
      session.addListener(listener);
      try {
        await loaded.future;
      } finally {
        session.removeListener(listener);
        _sessionListeners.remove(session);
        _waitingRecovery.remove(loaded);
      }
    }
    if (_disposed || !session.accountsLoaded) return;
    final accounts = session.accounts.map((account) => account.key).toSet();
    bool current() =>
        !_disposed &&
        session.accountsLoaded &&
        setEquals(
          accounts,
          session.accounts.map((account) => account.key).toSet(),
        );
    try {
      final tombstones = await store.listTombstones();
      if (!current()) return;
      for (final account in tombstones) {
        try {
          await clearAccount(account);
        } on ApiFailure {
          /* Marker remains for retry. */
        }
        if (!current()) return;
      }
      await files.deleteOrphans(accounts, isCurrent: current);
    } catch (_) {
      // A failed secure-store enumeration cannot authorize orphan deletion.
      // Recovery will retry on the next explicit start/launch.
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final entry in _accounts.values) {
      entry.epoch++;
      entry.retry?.cancel();
      entry.key?.fillRange(0, entry.key!.length, 0);
      entry.key = null;
    }
    for (final waiting in _waitingRecovery) {
      if (!waiting.isCompleted) waiting.complete();
    }
    if (_watchingLifecycle) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
