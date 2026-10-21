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

final Expando<Set<String>> _fallbackHistoryClearMarkers = Expando<Set<String>>(
  'aiHistoryClearMarkers',
);

Future<AiStoreRead<bool>> _readHistoryClearMarker(
  AiStore store,
  String account,
) {
  if (store case final AiHistoryClearMarkerStore markers) {
    return markers.readHistoryClearMarker(account);
  }
  return Future.value(
    _fallbackHistoryClearMarkers[store]?.contains(account) == true
        ? const AiStoreRead<bool>.found(true)
        : const AiStoreRead<bool>.absent(),
  );
}

Future<void> _setHistoryClearMarker(AiStore store, String account) {
  if (store case final AiHistoryClearMarkerStore markers) {
    return markers.setHistoryClearMarker(account);
  }
  (_fallbackHistoryClearMarkers[store] ??= <String>{}).add(account);
  return Future.value();
}

Future<void> _clearHistoryClearMarker(AiStore store, String account) {
  if (store case final AiHistoryClearMarkerStore markers) {
    return markers.clearHistoryClearMarker(account);
  }
  _fallbackHistoryClearMarkers[store]?.remove(account);
  return Future.value();
}

enum AiHistoryState {
  unknown,
  disabled,
  ready,
  readFailed,
  unavailable,
  keyMissing,
  cleaning,
}

final class _AccountHistory {
  AiHistoryState state = AiHistoryState.unknown;
  int epoch = 0;
  bool classified = false;
  Uint8List? key;
  AiAccountRecord? record;
  Future<void>? tail;
  Future<void>? cleanup;
  Timer? retry;
  int attempts = 0;
  DateTime? retryAt;
  final Set<String> fullConversations = {};
  final Set<String> capacityConversations = {};
  final Set<String> failedConversations = {};
  final Set<String> evictedConversations = {};
  bool removedUnreadable = false;
  bool repairedIndex = false;
  bool unsupported = false;
  bool unsupportedIndex = false;
  bool removedStaleTemporary = false;
  AiStoreFailure? failure;
}

void _resetHistoryNotices(_AccountHistory entry) {
  entry.classified = false;
  entry.fullConversations.clear();
  entry.capacityConversations.clear();
  entry.failedConversations.clear();
  entry.evictedConversations.clear();
  entry.removedUnreadable = false;
  entry.repairedIndex = false;
  entry.unsupported = false;
  entry.unsupportedIndex = false;
  entry.removedStaleTemporary = false;
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
        if (aiHistoryAccountSegment(entry.key) == segment) {
          return entry.value.classified &&
              entry.value.state == AiHistoryState.ready;
        }
      }
      // Loading a key alone cannot establish that history is supported. Keep
      // unscanned accounts protected until a complete file scan succeeds.
      return false;
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
  final Map<SessionController, VoidCallback> _accountLifecycleListeners = {};
  final Set<Completer<void>> _waitingRecovery = {};
  bool _disposed = false;
  bool _watchingLifecycle = false;
  bool _recoveryInvalidData = false;
  bool get recoveryInvalidData => _recoveryInvalidData;

  void acknowledgeRecoveryNotice() {
    _recoveryInvalidData = false;
    _emit();
  }

  _AccountHistory _entry(String account) =>
      _accounts.putIfAbsent(account, _AccountHistory.new);
  AiHistoryState state(String account) => _entry(account).state;
  bool storageLimitReached(String account, String id) =>
      _entry(account).fullConversations.contains(id) ||
      _entry(account).capacityConversations.contains(id);
  AiStoreFailure? failure(String account) => _entry(account).failure;
  bool canClearUnsupportedIndex(String account) =>
      _entry(account).unsupportedIndex;
  bool removedUnreadable(String account) => _entry(account).removedUnreadable;
  bool saveFailed(String account, String id) =>
      _entry(account).failedConversations.contains(id);
  bool evicted(String account, String id) =>
      _entry(account).evictedConversations.contains(id);

  void acknowledgeNotices(String account) {
    final entry = _entry(account);
    entry.removedUnreadable = false;
    entry.repairedIndex = false;
    entry.unsupported = false;
    entry.removedStaleTemporary = false;
    _emit();
  }

  void _accumulateRecovery(_AccountHistory entry, AiHistoryRecovery result) {
    entry.removedUnreadable |= result.removedUnreadable;
    entry.repairedIndex |= result.repairedIndex;
    entry.unsupported |= result.unsupported;
    entry.unsupportedIndex |= result.unsupportedIndex;
    entry.removedStaleTemporary |= result.removedStaleTemporary;
  }

  String? notice(String account, {String? conversationId}) {
    final entry = _entry(account);
    if (entry.failure?.kind == AiStoreFailureKind.malformed) {
      return l10n.aiHistoryInvalidData;
    }
    if (conversationId != null &&
        entry.fullConversations.contains(conversationId)) {
      return l10n.aiHistoryStorageLimit;
    }
    if (conversationId != null &&
        entry.capacityConversations.contains(conversationId)) {
      return l10n.aiHistoryCapacityLimit;
    }
    if (conversationId != null &&
        entry.failedConversations.contains(conversationId)) {
      return l10n.aiHistoryNotSaved;
    }
    if (conversationId != null &&
        entry.evictedConversations.contains(conversationId)) {
      return l10n.aiHistoryEvicted;
    }
    if (entry.removedUnreadable) return l10n.aiHistoryRemovedUnreadable;
    if (entry.unsupported) return l10n.aiHistoryUnsupported;
    if (entry.removedStaleTemporary) return l10n.aiHistoryTemporaryFilesRemoved;
    if (entry.repairedIndex) return l10n.aiHistoryIndexRepaired;
    return switch (entry.state) {
      AiHistoryState.readFailed => l10n.aiHistoryReadFailed,
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
    // Invalid stored data needs an explicit repair/clear, never a timed retry
    // which would turn a disabled record into a successful load.
    if (entry.failure?.kind == AiStoreFailureKind.malformed) return;
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
      final historyClear = await _readHistoryClearMarker(store, account);
      if (!_current(entry, epoch)) return;
      if (historyClear.failure != null) {
        _unavailable(account, entry, failure: historyClear.failure);
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
      if (historyClear.value == true) {
        entry.state = AiHistoryState.readFailed;
        entry.key = null;
        entry.failure = const AiStoreFailure(
          AiStoreFailureKind.unavailable,
          'clearHistory',
        );
        _emit();
        return;
      }
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
          _unavailable(account, entry, failure: key.failure);
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
    if (entry.state != AiHistoryState.disabled ||
        AiAccountMutationCoordinator.forStore(store).isCleaning(account)) {
      return entry.state;
    }
    final epoch = entry.epoch;
    try {
      final result = await store.readHistoryKey(account);
      if (!_current(entry, epoch)) return entry.state;
      if (result.failure != null ||
          result.status == AiStoreReadStatus.unavailable) {
        _unavailable(account, entry, failure: result.failure);
        return entry.state;
      }
      final key = result.value ?? Uint8List.fromList(AiHistoryCipher.newKey());
      if (result.status == AiStoreReadStatus.absent) {
        await store.writeHistoryKey(account, key);
        if (!_current(entry, epoch)) return entry.state;
      }
      final record = await AiAccountMutationCoordinator.forStore(
        store,
      ).mutate(account, (latest) => latest.copyWith(historyEnabled: true));
      if (!_current(entry, epoch) || record == null) return entry.state;
      entry.key = Uint8List.fromList(key);
      entry.record = record;
      entry.state = AiHistoryState.ready;
      _emit();
    } catch (_) {
      if (_current(entry, epoch)) _unavailable(account, entry);
    }
    return entry.state;
  });

  /// Disabling pauses persistence without deleting existing encrypted history.
  Future<void> disable(String account) => _run(account, (entry) async {
    await _load(account, entry);
    if (entry.state != AiHistoryState.ready &&
        entry.state != AiHistoryState.readFailed) {
      return;
    }
    final record = await AiAccountMutationCoordinator.forStore(
      store,
    ).mutate(account, (current) => current.copyWith(historyEnabled: false));
    if (record == null) return;
    entry.epoch++;
    entry.record = record;
    entry.key?.fillRange(0, entry.key!.length, 0);
    entry.key = null;
    entry.state = AiHistoryState.disabled;
    _emit();
  });

  Future<void> setRetention(String account, int days) =>
      _run(account, (entry) async {
        await _load(account, entry);
        if (entry.state != AiHistoryState.ready &&
            entry.state != AiHistoryState.disabled) {
          return;
        }
        final record = await AiAccountMutationCoordinator.forStore(
          store,
        ).mutate(account, (current) => current.copyWith(retentionDays: days));
        if (record == null) return;
        entry.record = record;
        final epoch = entry.epoch;
        if (entry.key != null) {
          final recovery = await files.maintain(
            account,
            Uint8List.fromList(entry.key!),
            days,
          );
          if (!_current(entry, epoch)) return;
          _accumulateRecovery(entry, recovery);
        }
        _emit();
      });

  /// Settings may retry account cleanup only while that account is retained.
  /// Reopen its mutation fence after cleanup succeeds, never after a failure.
  Future<void> retryCleanup(
    String account, {
    required bool Function() isRetained,
  }) async {
    await clearAccount(account);
    if (!isRetained() || _disposed) return;
    AiAccountMutationCoordinator.forStore(store).reopen(account);
    final entry = _entry(account);
    entry.epoch++;
    entry.state = AiHistoryState.unknown;
    await load(account);
  }

  /// History-only clearing preserves consents and account preferences. Disable
  /// durably before deleting files, then delete the key last. A failed clear
  /// stays disabled, keeps any remaining key and supports explicit retry.
  Future<void> clearHistory(String account) {
    final entry = _entry(account);
    entry.epoch++;
    return _run(account, (entry) async {
      final owner = AiAccountMutationCoordinator.forStore(store);
      if (owner.isCleaning(account)) {
        throw const AiStoreException(
          AiStoreFailure(AiStoreFailureKind.cleaning, 'clearHistory'),
        );
      }
      await _setHistoryClearMarker(store, account);
      final epoch = entry.epoch;
      entry.state = AiHistoryState.cleaning;
      entry.key?.fillRange(0, entry.key!.length, 0);
      entry.key = null;
      _emit();
      try {
        final record = await owner.mutate(
          account,
          (current) => current.copyWith(historyEnabled: false),
        );
        if (record == null) {
          throw const AiStoreException(
            AiStoreFailure(AiStoreFailureKind.cleaning, 'clearHistory'),
          );
        }
        entry.record = record;
        await files.deleteAccount(account);
        await store.deleteHistoryKey(account);
        await _clearHistoryClearMarker(store, account);
        if (entry.epoch != epoch) return;
        entry.state = AiHistoryState.disabled;
        entry.failure = null;
        _resetHistoryNotices(entry);
      } catch (_) {
        if (entry.epoch != epoch) rethrow;
        entry.state = AiHistoryState.readFailed;
        entry.failure = const AiStoreFailure(
          AiStoreFailureKind.unavailable,
          'clearHistory',
        );
        rethrow;
      } finally {
        _emit();
      }
    });
  }

  Future<AiHistoryRecovery?> read(String account) =>
      _run(account, (entry) async {
        await _load(account, entry);
        if (entry.state != AiHistoryState.ready &&
            entry.state != AiHistoryState.readFailed) {
          return null;
        }
        // A failed explicit clear has already paused persistence and released
        // the in-memory key. Preserve its failure for the cleanup retry UI.
        if (entry.key == null) return null;
        final epoch = entry.epoch;
        try {
          final result = await files.recover(
            account,
            Uint8List.fromList(entry.key!),
            entry.record!.retentionDays,
            onRecovery: (recovery) {
              if (_current(entry, epoch)) _accumulateRecovery(entry, recovery);
            },
          );
          if (!_current(entry, epoch)) return null;
          _accumulateRecovery(entry, result);
          entry.classified = true;
          entry.state = AiHistoryState.ready;
          entry.failure = null;
          _emit();
          return result;
        } catch (_) {
          if (_current(entry, epoch)) {
            entry.state = AiHistoryState.readFailed;
            entry.failure = const AiStoreFailure(
              AiStoreFailureKind.unavailable,
              'readHistory',
            );
            _emit();
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
      if (!_current(entry, epoch) ||
          (entry.state != AiHistoryState.ready &&
              entry.state != AiHistoryState.readFailed) ||
          entry.key == null) {
        return AiHistorySaveResult.cancelled;
      }
      if (entry.fullConversations.contains(conversation.id)) {
        return AiHistorySaveResult.storageLimit;
      }
      try {
        var capacityLimited = false;
        final result = await files.save(
          account,
          Uint8List.fromList(entry.key!),
          conversation,
          entry.record!.retentionDays,
          isCurrent: () => _current(entry, epoch),
          onRecovery: (recovery) {
            if (_current(entry, epoch)) _accumulateRecovery(entry, recovery);
          },
          onCapacityLimit: () => capacityLimited = true,
        );
        if (!_current(entry, epoch)) return AiHistorySaveResult.cancelled;
        if (result == AiHistorySaveResult.storageLimit) {
          if (capacityLimited) {
            entry.capacityConversations.add(conversation.id);
          } else {
            entry.fullConversations.add(conversation.id);
          }
        }
        if (result == AiHistorySaveResult.unsupported) {
          entry.unsupported = true;
        }
        if (result == AiHistorySaveResult.failed) {
          entry.failedConversations.add(conversation.id);
        } else if (result == AiHistorySaveResult.saved) {
          entry.classified = true;
          entry.state = AiHistoryState.ready;
          entry.failure = null;
          entry.capacityConversations.remove(conversation.id);
          entry.failedConversations.remove(conversation.id);
          entry.evictedConversations.remove(conversation.id);
        } else if (result == AiHistorySaveResult.evicted) {
          entry.classified = true;
          entry.evictedConversations.add(conversation.id);
        }
        _emit();
        return result;
      } catch (_) {
        if (_current(entry, epoch)) {
          entry.failedConversations.add(conversation.id);
          _emit();
        }
        return AiHistorySaveResult.failed;
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
    entry.classified = false;
    entry.epoch++;
    entry.retry?.cancel();
    entry.retry = null;
    entry.key?.fillRange(0, entry.key!.length, 0);
    entry.key = null;
    entry.record = null;
    entry.fullConversations.clear();
    entry.capacityConversations.clear();
    entry.failedConversations.clear();
    entry.evictedConversations.clear();
    entry.repairedIndex = false;
    entry.unsupported = false;
    entry.unsupportedIndex = false;
    entry.removedStaleTemporary = false;
    entry.removedUnreadable = false;
    entry.failure = null;
    final pending = entry.tail;
    final cleaning = AiAccountMutationCoordinator.forStore(
      store,
    ).beginCleaning(account);
    _emit();
    try {
      await store.setTombstone(account);
      if (pending != null) await pending;
      await cleaning.run(() async {
        await store.deleteHistoryKey(account);
        await files.deleteAccount(account);
        await store.deleteAccount(account);
        await _clearHistoryClearMarker(store, account);
        await store.clearTombstone(account);
      });
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

  void _reopenRetainedAccount(SessionController session, String account) {
    final entry = _entry(account);
    if (!session.accountsLoaded ||
        !session.accounts.any((value) => value.key == account) ||
        entry.state != AiHistoryState.disabled) {
      return;
    }
    AiAccountMutationCoordinator.forStore(store).reopen(account);
    entry.epoch++;
    entry.state = AiHistoryState.unknown;
    entry.failure = null;
  }

  /// Explicit destructive action for the later history UI. Unsupported
  /// authenticated content is otherwise preserved indefinitely.
  Future<AiHistoryClearUnsupportedIndexResult> clearUnsupportedIndex(
    String account,
  ) => _run(account, (entry) async {
    await _load(account, entry);
    if (entry.key == null || entry.state == AiHistoryState.cleaning) {
      return AiHistoryClearUnsupportedIndexResult.failed;
    }
    final epoch = entry.epoch;
    try {
      final result = await files.clearUnsupportedIndex(
        account,
        Uint8List.fromList(entry.key!),
      );
      if (!_current(entry, epoch)) {
        return AiHistoryClearUnsupportedIndexResult.failed;
      }
      if (result == AiHistoryClearUnsupportedIndexResult.cleared) {
        entry.unsupportedIndex = false;
        _emit();
      }
      return result;
    } catch (_) {
      return AiHistoryClearUnsupportedIndexResult.failed;
    }
  });

  void _trackAccountLifecycle(SessionController session) {
    if (_accountLifecycleListeners.containsKey(session)) return;
    var previous = session.accountsLoaded
        ? session.accounts.map((account) => account.key).toSet()
        : <String>{};
    void listener() {
      if (_disposed || !session.accountsLoaded) return;
      final live = session.accounts.map((account) => account.key).toSet();
      final owner = AiAccountMutationCoordinator.forStore(store);
      for (final account in live) {
        final entry = _entry(account);
        // Session removal can fail and restore the same membership. Only a
        // completed cleanup may reopen; a durable tombstone stays fenced.
        if (entry.state == AiHistoryState.disabled &&
            owner.isCleaning(account) &&
            (!previous.contains(account) || !session.busy)) {
          owner.reopen(account);
          entry.epoch++;
          entry.state = AiHistoryState.unknown;
          entry.failure = null;
        }
      }
      previous = live;
    }

    _accountLifecycleListeners[session] = listener;
    session.addListener(listener);
  }

  Future<void> startRecovery(SessionController session) async {
    _watchLifecycle();
    if (_disposed) return;
    _trackAccountLifecycle(session);
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
    while (!_disposed && session.accountsLoaded) {
      final accounts = session.accounts.map((account) => account.key).toSet();
      await _recoverAccounts(session, accounts);
      if (setEquals(
        accounts,
        session.accounts.map((account) => account.key).toSet(),
      )) {
        return;
      }
      // Membership changed during an awaited step. Retry with the current
      // account set so later accounts do not stay unclassified for this run.
    }
  }

  Future<void> _recoverAccounts(
    SessionController session,
    Set<String> accounts,
  ) async {
    bool current() =>
        !_disposed &&
        session.accountsLoaded &&
        setEquals(
          accounts,
          session.accounts.map((account) => account.key).toSet(),
        );
    try {
      final inventory = await readAiTombstoneInventory(store);
      if (!current()) return;
      if (inventory.malformedCount > 0) {
        _recoveryInvalidData = true;
        _emit();
      }
      for (final account in inventory.accountKeys) {
        try {
          await clearAccount(account);
          _reopenRetainedAccount(session, account);
        } on ApiFailure {
          /* Marker remains for retry. */
        }
        if (!current()) return;
      }
      if (!current()) return;
      final secureCleanup = await cleanupOrphanAiSecureData(
        store,
        accounts,
        isCurrent: current,
      );
      if (!current()) return;
      if (secureCleanup.malformedAccountKeyCount > 0 ||
          secureCleanup.malformedHistoryKeyCount > 0) {
        _recoveryInvalidData = true;
        _emit();
      }
      for (final account in {
        ...secureCleanup.deletedAccountRecords,
        ...secureCleanup.deletedHistoryKeys,
      }) {
        final entry = _entry(account);
        if (entry.state != AiHistoryState.cleaning) {
          entry.state = AiHistoryState.disabled;
        }
      }
      await files.deleteOrphans(accounts, isCurrent: current);
      if (!current()) return;
      for (final account in accounts) {
        try {
          await _run(account, (entry) async {
            await _load(account, entry);
            if (!current() || entry.state != AiHistoryState.ready) return;
            final epoch = entry.epoch;
            final recovery = await files.maintain(
              account,
              Uint8List.fromList(entry.key!),
              entry.record!.retentionDays,
              onRecovery: (recovery) {
                if (current() && _current(entry, epoch)) {
                  _accumulateRecovery(entry, recovery);
                }
              },
            );
            if (current() && _current(entry, epoch)) {
              _accumulateRecovery(entry, recovery);
              entry.classified = true;
              _emit();
            }
          });
        } catch (_) {
          final entry = _entry(account);
          if (entry.state == AiHistoryState.ready) {
            entry.state = AiHistoryState.readFailed;
            entry.failure = const AiStoreFailure(
              AiStoreFailureKind.unavailable,
              'maintainHistory',
            );
            _emit();
          }
        }
        if (!current()) return;
      }
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
    for (final item in _accountLifecycleListeners.entries) {
      item.key.removeListener(item.value);
    }
    _accountLifecycleListeners.clear();
    for (final waiting in _waitingRecovery) {
      if (!waiting.isCompleted) waiting.complete();
    }
    if (_watchingLifecycle) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
