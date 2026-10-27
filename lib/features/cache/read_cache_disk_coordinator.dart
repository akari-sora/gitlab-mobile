import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../core/failure.dart';
import '../../core/read_cache_cipher.dart';
import '../../core/read_cache_disk_contract.dart';
import '../../core/read_cache_files.dart';
import 'read_cache_key_store.dart';
import 'read_cache_settings_store.dart';

enum ReadCacheDiskState { closed, ready, cleaning, disabled, unavailable }

/// Schedulers return a cancellation function. Tests can advance the same clock
/// used for queue deadlines and caller timeouts without delaying native I/O.
typedef ReadCacheScheduler =
    void Function() Function(Duration delay, void Function() callback);

final class ReadCacheDiskStats {
  const ReadCacheDiskStats(this.queuedEntries, this.queuedBytes, this.dropped);
  final int queuedEntries, queuedBytes, dropped;
}

/// The only owner of read-cache keys, intents and transactions. No production
/// reader/writer is attached in C2c. In particular the singleton starts both
/// unconfigured and without user controls; neither condition proves disk empty.
final class ReadCacheDiskCoordinator {
  ReadCacheDiskCoordinator({
    ReadCacheKeyStore? keys,
    ReadCacheFileStore? files,
    ReadCacheSettingsStore? settings,
    Object? coordinationScope,
    DateTime Function()? clock,
    ReadCacheScheduler? schedule,
    bool controlsInstalled = false,
  }) : _keys = keys,
       _files = files,
       _settings = settings,
       _domain = coordinationScope == null
           ? _processDomain
           : (_scopes[coordinationScope] ??= _Domain()),
       _clock = clock ?? DateTime.now,
       _schedule = schedule ?? _timer {
    if (controlsInstalled) _domain.controlsInstalled = true;
  }

  static final instance = ReadCacheDiskCoordinator();
  static final _processDomain = _Domain();
  static final _scopes = Expando<_Domain>();
  static final _random = Random.secure();
  static const queueByteLimit = 2 * 1024 * 1024;
  static const batchEntries = 32;
  static const batchDelay = Duration(seconds: 2);
  static const barrierLimit = Duration(seconds: 5);

  ReadCacheKeyStore? _keys;
  ReadCacheFileStore? _files;
  ReadCacheSettingsStore? _settings;
  final _Domain _domain;
  final DateTime Function() _clock;
  final ReadCacheScheduler _schedule;
  Map<DiskBinding, ReadCacheNotice> get _notices => _domain.notices;
  Map<DiskBinding, ReadCacheNotice> get _signedOut => _domain.signedOut;
  Set<ReadCacheNoticeSink> get _subscribers => _domain.subscribers;

  bool get configured => _keys != null && _files != null && _settings != null;
  bool get startupRecovered => _domain.recovered;
  bool get controlsInstalled => _domain.controlsInstalled;
  ReadCacheDiskState state(String accountKey) => _account(accountKey).state;
  ReadCacheNotice? notice(DiskBinding binding) => _notices[binding];
  List<ReadCacheNotice> get signedOutNotices =>
      List.unmodifiable(_signedOut.values);

  ReadCacheDiskStats get stats => ReadCacheDiskStats(
    _domain.accounts.values.fold(0, (n, a) => n + a.pending.length),
    _domain.accounts.values.fold(0, (n, a) => n + a.queuedBytes),
    _domain.dropped,
  );

  void configure({
    required ReadCacheKeyStore keys,
    required ReadCacheFileStore files,
    required ReadCacheSettingsStore settings,
  }) {
    // Configuration never opens a gate or forgets a pending clear.
    _keys = keys;
    _files = files;
    _settings = settings;
  }

  void installUserControls() => _domain.controlsInstalled = true;

  void Function() subscribe(ReadCacheNoticeSink sink) {
    _subscribers.add(sink);
    return () => _subscribers.remove(sink);
  }

  void reportCleanup(DiskBinding binding, ReadCacheCleanupState state) {
    final value = ReadCacheNotice(ApiFailure.readCacheCleanup(state));
    _notices[binding] = value;
    if (state.disposition ==
        ReadCacheCleanupDisposition.signedOutCleanupPending) {
      _signedOut[binding] = value;
    }
    for (final sink in List.of(_subscribers)) {
      try {
        sink(value);
      } on Object {
        // Observers cannot replace a transport outcome or lose the snapshot.
      }
    }
  }

  void supersedeNotice(DiskBinding binding) {
    _notices.remove(binding);
    _signedOut.remove(binding);
  }

  _Account _account(String key) =>
      _domain.accounts.putIfAbsent(key, () => _Account(key));

  /// One process-wide serialized I/O section also makes device capacity and
  /// root sweeps atomic with respect to every account transaction. Wrappers
  /// share it, not the identity of a particular key-store instance.
  Future<T> _serial<T>(_Account? account, Future<T> Function() action) {
    final result = Completer<T>();
    account?.work++;
    _domain.work++;
    _domain.tail = _domain.tail.then((_) async {
      try {
        result.complete(await action());
      } on Object catch (error, stack) {
        result.completeError(error, stack);
      } finally {
        _domain.work--;
        if (account != null) account.work--;
      }
    });
    return result.future;
  }

  Future<void> get quiesced => _domain.tail;

  bool _gates(DiskBinding binding) =>
      configured &&
      _domain.controlsInstalled &&
      _domain.foreground &&
      _domain.preferenceChanges == 0 &&
      _domain.recovered &&
      _domain.setting == ReadCacheSettingsState.enabled &&
      _domain.active == binding &&
      !_account(binding.accountKey).cleanup;

  bool _ready(DiskBinding binding) =>
      _gates(binding) &&
      _account(binding.accountKey).state == ReadCacheDiskState.ready;

  bool _blocked(_Account account, ProjectedDiskEntry entry) =>
      account.invalidations.any((i) => _matches(entry, i));

  /// Binding is supplied only by a verified activation caller. It can arrive
  /// before recovery; the rendezvous never interprets accountsLoaded as ready.
  Future<bool> activate(DiskBinding binding) {
    if (binding.generation < _domain.highestGeneration ||
        binding.generation <= _domain.revokedThrough ||
        (binding.generation == _domain.highestGeneration &&
            _domain.latestVerified != null &&
            _domain.latestVerified != binding)) {
      return Future.value(false);
    }
    _domain.highestGeneration = binding.generation;
    _domain.latestVerified = binding;
    final previous = _domain.active;
    if (previous != binding && previous != null) revoke(previous);
    _domain.active = binding;
    final account = _account(binding.accountKey);
    if (account.cleanup &&
        account.clearComplete &&
        account.intent == null &&
        account.sessionFence != binding) {
      account.cleanup = false;
      account.state = ReadCacheDiskState.closed;
    }
    if (!_gates(binding)) return Future.value(false);
    return _serial(account, () => _prepare(binding));
  }

  Future<bool> _prepare(DiskBinding binding) async {
    final account = _account(binding.accountKey);
    if (!_gates(binding)) return false;
    final epoch = account.epoch;
    bool current() => _gates(binding) && epoch == account.epoch;
    final marker = await _keys!.readMarker(account.key);
    if (!current()) return false;
    if (marker.status == ReadCacheStoreReadStatus.unavailable) {
      _unavailable(account, binding);
      return false;
    }
    if (marker.isFound) {
      final intent = account.intent;
      final ownedScope =
          intent != null &&
          intent.valid &&
          !intent.full &&
          intent.revision == account.revision &&
          marker.value == intent.marker;
      if (!ownedScope) {
        final full = _fullIntent(account, ReadCacheClearReason.accountClear);
        await _clearNow(account, full, hadWork: true);
        return false;
      }
    }
    final read = await _keys!.readKey(account.key);
    if (!current()) return false;
    if (read.status == ReadCacheStoreReadStatus.unavailable) {
      _unavailable(account, binding);
      return false;
    }
    try {
      if (read.isFound) {
        account.keyBytes = read.value;
      } else {
        final directory = await _files!.accountDirectoryState(account.key);
        final names = await _files!.accountDirectoryNames();
        if (!current()) return false;
        if (directory == ReadCacheDirectoryState.hasFiles ||
            (directory == ReadCacheDirectoryState.absent &&
                names.contains(
                  ReadCacheCipher.accountDirectoryName(account.key),
                ))) {
          final intent = _fullIntent(account, ReadCacheClearReason.keyRepair);
          final cleared = await _clearNow(account, intent, hadWork: true);
          if (!cleared.complete || _domain.active != binding) return false;
          // Key repair owns this fence; no other clear may have superseded it.
          if (account.intent != null || account.epoch != epoch + 1) {
            return false;
          }
          account.cleanup = false;
        }
        if (!_gates(binding)) return false;
        final creationEpoch = account.epoch;
        final bytes = Uint8List.fromList(
          List.generate(32, (_) => _random.nextInt(256)),
        );
        await _keys!.writeKey(account.key, bytes);
        if (!_gates(binding) || account.epoch != creationEpoch) {
          // A late secure write is drained before the queued clear deletes it.
          return false;
        }
        final confirmed = await _keys!.readKey(account.key);
        if (!_gates(binding) || account.epoch != creationEpoch) return false;
        if (!confirmed.isFound || !_sameBytes(bytes, confirmed.value!)) {
          _unavailable(account, binding);
          return false;
        }
        account.keyBytes = confirmed.value;
      }
      if (!_gates(binding)) return false;
      final preparedEpoch = account.epoch;
      await _loadIndex(
        account,
        () => _gates(binding) && account.epoch == preparedEpoch,
      );
      if (!_gates(binding) || account.epoch != preparedEpoch) return false;
      account.state = ReadCacheDiskState.ready;
      account.retryAttempt = 0;
      account.cancelRetry?.call();
      account.cancelRetry = null;
      return true;
    } on ReadCacheStoreException catch (error) {
      account.indexTrusted = false;
      if (error.failure.kind == ReadCacheStoreFailureKind.unavailable) {
        _unavailable(account, binding);
      } else if (!account.cleanup) {
        account.state = ReadCacheDiskState.closed;
      }
      return false;
    } on Object {
      account.indexTrusted = false;
      if (!account.cleanup) account.state = ReadCacheDiskState.closed;
      return false;
    }
  }

  void _unavailable(_Account account, DiskBinding binding) {
    if (account.cleanup) return;
    account.state = ReadCacheDiskState.unavailable;
    account.keyBytes = null;
    account.cancelRetry?.call();
    if (account.retryAttempt >= 3) return;
    final seconds = [1, 5, 30][account.retryAttempt++];
    account.cancelRetry = _schedule(Duration(seconds: seconds), () {
      account.cancelRetry = null;
      if (_gates(binding)) unawaited(activate(binding));
    });
  }

  Future<void> _loadIndex(_Account account, bool Function() current) async {
    // A partially reconstructed map cannot prove a scoped deletion set.
    account.indexTrusted = false;
    final key = account.keyBytes!;
    ReadCacheIndex? index;
    var readable = true;
    try {
      index = await _files!.readIndex(account.key, key);
    } on ReadCacheCodecException {
      // A damaged index never proves a deletion set. Full clear is the fallback.
      readable = false;
    }
    final metadata = {
      for (final m in index?.entries ?? <ReadCacheIndexEntry>[]) m.fileName: m,
    };
    if (!current()) return;
    account.entries.clear();
    final names = await _files!.entryFiles(account.key, key);
    if (!current()) return;
    for (final name in names) {
      if (!current()) return;
      ProjectedDiskEntry? entry;
      try {
        entry = await _files!.readEntryFile(account.key, key, name);
      } on ReadCacheCodecException {
        // Individually corrupt, unsupported or expired cache entries are misses.
      }
      if (!current()) return;
      if (entry == null) {
        await _files!.evict(account.key, key, name);
        continue;
      }
      final expected = await const ReadCacheCipher().entryFileName(
        key,
        entry.canonicalKey,
      );
      if (!current()) return;
      if (expected != name) {
        await _files!.evict(account.key, key, name);
        continue;
      }
      final publication = account.unindexed[entry.canonicalKey];
      if (publication != null && !publication.isCurrent) {
        await _files!.evict(account.key, key, name);
        account.unindexed.remove(entry.canonicalKey);
        continue;
      }
      account.entries[entry.canonicalKey] = _Record(
        entry,
        ReadCacheIndexEntry(
          fileName: name,
          sizeBytes: entry.serializedLength + readCacheEnvelopeOverhead,
          fetchedAt: entry.fetchedAt,
          lastUsedAt: metadata[name]?.lastUsedAt ?? entry.fetchedAt,
          cacheClass: entry.cacheClass,
          scopeTags: entry.scopeTags,
          issueIdentities: entry.issueIdentities,
        ),
      );
    }
    if (!current()) return;
    await _files!.removeStaleTemporaryFiles(account.key, key);
    if (!current()) return;
    account.unindexed.removeWhere(
      (name, _) => !account.entries.containsKey(name),
    );
    account.indexTrusted =
        readable &&
        account.unindexed.isEmpty &&
        ((index == null && account.entries.isEmpty) ||
            (index != null &&
                metadata.length == account.entries.length &&
                account.entries.values.every(
                  (r) => metadata.containsKey(r.index.fileName),
                )));
    account.indexDirty = !account.indexTrusted;
  }

  Future<ProjectedDiskEntry?> lookup(DiskLookup lookup) {
    if (!_ready(lookup.binding) || !lookup.lease.isCurrent) {
      return Future.value(null);
    }
    final account = _account(lookup.binding.accountKey);
    final epoch = account.epoch;
    final lease = _CommitLease(
      () =>
          _ready(lookup.binding) &&
          epoch == account.epoch &&
          account.unindexed[lookup.canonicalKey]?.isCurrent != false &&
          lookup.lease.isCurrent,
    );
    account.reads.add(lease);
    return _serial(account, () async {
      try {
        if (!lease.isCurrent) return null;
        final keyRead = await _keys!.readKey(account.key);
        if (!lease.isCurrent) return null;
        if (keyRead.status == ReadCacheStoreReadStatus.unavailable) {
          _unavailable(account, lookup.binding);
          return null;
        }
        if (!keyRead.isFound) {
          final intent = _fullIntent(account, ReadCacheClearReason.keyRepair);
          await _clearNow(account, intent, hadWork: true);
          return null;
        }
        final value = await _files!.readEntry(
          account.key,
          keyRead.value,
          lookup.canonicalKey,
        );
        if (!lease.isCurrent) return null;
        final record = account.entries[lookup.canonicalKey];
        if (record != null) {
          if (value == null) {
            await _files!.evict(
              account.key,
              keyRead.value,
              record.index.fileName,
            );
            account.entries.remove(lookup.canonicalKey);
            account.indexTrusted = false;
            account.indexDirty = true;
          } else {
            account.entries[lookup.canonicalKey] = _Record(
              value,
              _used(record.index, _clock()),
            );
            account.indexDirty = true;
          }
        }
        return value != null && !_blocked(account, value) ? value : null;
      } on Object {
        return null;
      } finally {
        account.reads.remove(lease);
      }
    });
  }

  void accept(DiskWriteCandidate candidate, ProjectedDiskEntry entry) {
    final binding = candidate.binding;
    if (!_ready(binding) ||
        !candidate.lease.isCurrent ||
        !candidate.cacheable ||
        candidate.noStore ||
        !candidate.firstPage ||
        candidate.method != 'GET' ||
        binding.accountKey != entry.accountKey) {
      return;
    }
    int bytes;
    try {
      bytes = const ReadCacheCipher().encodeEntry(entry).length;
    } on Object {
      _domain.dropped++;
      return;
    }
    if (bytes > queueByteLimit) {
      _domain.dropped++;
      return;
    }
    final account = _account(binding.accountKey);
    if (_blocked(account, entry)) return;
    final epoch = account.epoch;
    final work = _Write(
      entry,
      bytes,
      _CommitLease(
        () =>
            _ready(binding) &&
            account.epoch == epoch &&
            candidate.lease.isCurrent,
      ),
    );
    while (account.pending.isNotEmpty &&
        account.queuedBytes + bytes > queueByteLimit) {
      _drop(account, account.pending.removeFirst());
    }
    account.pending.add(work);
    account.queuedBytes += bytes;
    account.batchDeadline ??= _clock().add(batchDelay);
    _scheduleBatch(binding);
    if (account.pending.length >= batchEntries) {
      unawaited(_flush(binding, force: false));
    }
  }

  void _scheduleBatch(DiskBinding binding) {
    final account = _account(binding.accountKey);
    if (account.cancelBatch != null || account.pending.isEmpty) return;
    final delay = account.batchDeadline!.difference(_clock());
    account.cancelBatch = _schedule(
      delay.isNegative ? Duration.zero : delay,
      () {
        account.cancelBatch = null;
        unawaited(_flush(binding, force: false));
      },
    );
  }

  Future<void> flush(DiskBinding binding) => _flush(binding, force: true);

  Future<void> _flush(DiskBinding binding, {required bool force}) {
    final account = _account(binding.accountKey);
    account.flushForced |= force;
    final running = account.flush;
    if (running != null) return running;
    if (!_ready(binding) || (account.pending.isEmpty && !account.indexDirty)) {
      account.flushForced = false;
      return Future.value();
    }
    late final Future<void> flight;
    flight =
        _serial(account, () async {
          try {
            while (_ready(binding)) {
              if (account.pending.isEmpty && !account.indexDirty) return;
              if (!account.flushForced &&
                  account.pending.isNotEmpty &&
                  account.pending.length < batchEntries &&
                  _clock().isBefore(account.batchDeadline!)) {
                _scheduleBatch(binding);
                return;
              }
              final epoch = account.epoch;
              final indexRevision = account.indexRevision;
              bool current() => _ready(binding) && account.epoch == epoch;
              final deadline =
                  account.batchDeadline ?? _clock().add(batchDelay);
              account.cancelBatch?.call();
              account.cancelBatch = null;
              final keyRead = await _keys!.readKey(account.key);
              if (!current()) return;
              if (keyRead.status == ReadCacheStoreReadStatus.unavailable) {
                _dropQueue(account);
                _unavailable(account, binding);
                return;
              }
              if (!keyRead.isFound) {
                final intent = _fullIntent(
                  account,
                  ReadCacheClearReason.keyRepair,
                );
                await _clearNow(account, intent, hadWork: true);
                return;
              }
              account.keyBytes = keyRead.value;
              for (final publication in account.unindexed.entries.toList()) {
                if (publication.value.isCurrent) continue;
                final record = account.entries[publication.key];
                if (record != null) {
                  await _files!.evict(
                    account.key,
                    keyRead.value,
                    record.index.fileName,
                  );
                  account.entries.remove(publication.key);
                }
                account.unindexed.remove(publication.key);
                account.indexDirty = true;
                if (!current()) return;
              }
              var processed = 0;
              while (account.pending.isNotEmpty &&
                  current() &&
                  processed < batchEntries &&
                  (processed == 0 || _clock().isBefore(deadline))) {
                final work = account.pending.removeFirst();
                account.queuedBytes -= work.bytes;
                account.inFlight.add(work);
                processed++;
                try {
                  if (!work.lease.isCurrent) continue;
                  if (!await _makeRoom(
                    account,
                    work.bytes +
                        readCacheEnvelopeOverhead +
                        readCacheIndexLimit +
                        readCacheEnvelopeOverhead,
                    () => work.lease.isCurrent,
                  )) {
                    _domain.dropped++;
                    continue;
                  }
                  if (!work.lease.isCurrent) continue;
                  if (processed > 1 && !_clock().isBefore(deadline)) {
                    // Capacity checks can yield past the deadline. Commit the
                    // completed batch before staging another entry.
                    account.pending.addFirst(work);
                    account.queuedBytes += work.bytes;
                    break;
                  }
                  final staged = await _files!.stageEntry(
                    work.entry,
                    account.keyBytes,
                    mayCommit: () => work.lease.isCurrent,
                  );
                  if (staged == null) continue;
                  if (staged.commit() != ReadCacheCommitResult.committed) {
                    continue;
                  }
                  account.entries[work.entry.canonicalKey] = _Record(
                    work.entry,
                    ReadCacheIndexEntry(
                      fileName: staged.fileName,
                      sizeBytes: staged.ciphertextBytes,
                      fetchedAt: work.entry.fetchedAt,
                      lastUsedAt: _clock().toUtc(),
                      cacheClass: work.entry.cacheClass,
                      scopeTags: work.entry.scopeTags,
                      issueIdentities: work.entry.issueIdentities,
                    ),
                  );
                  account.unindexed[work.entry.canonicalKey] = work.lease;
                  account.indexDirty = true;
                } finally {
                  account.inFlight.remove(work);
                }
              }
              bool indexCurrent() =>
                  current() && account.indexRevision == indexRevision;
              if (account.indexDirty && indexCurrent()) {
                await _commitIndex(account, indexCurrent);
              }
              if (!current()) return;
              if (account.pending.isEmpty) {
                account.batchDeadline = null;
                account.cancelBatch?.call();
                account.cancelBatch = null;
                return;
              }
              account.batchDeadline = _clock().add(batchDelay);
            }
          } on Object {
            if (!account.cleanup) account.state = ReadCacheDiskState.closed;
            _dropQueue(account);
          } finally {
            account.flushForced = false;
          }
        }).whenComplete(() {
          if (identical(account.flush, flight)) account.flush = null;
        });
    account.flush = flight;
    return flight;
  }

  Future<bool> _makeRoom(
    _Account account,
    int incoming,
    bool Function() current,
  ) async {
    final unavailable = <_Account>{};
    while (current()) {
      final usage = await _files!.usage(account.key, account.keyBytes);
      if (!current()) return false;
      final accountFull =
          usage.accountBytes + incoming > readCacheAccountByteLimit;
      final deviceFull =
          usage.deviceBytes + incoming > readCacheDeviceByteLimit;
      if (!accountFull && !deviceFull) return true;
      final candidates = <(_Account, _Record)>[
        for (final owner in _domain.accounts.values)
          if (owner.keyBytes != null &&
              !owner.cleanup &&
              (!accountFull || owner == account) &&
              !unavailable.contains(owner))
            for (final entry in owner.entries.values) (owner, entry),
      ]..sort((a, b) => a.$2.index.lastUsedAt.compareTo(b.$2.index.lastUsedAt));
      if (candidates.isEmpty) return false;
      final (owner, victim) = candidates.first;
      final key = await _keys!.readKey(owner.key);
      if (!current()) return false;
      if (!key.isFound) {
        unavailable.add(owner);
        continue;
      }
      await _files!.evict(owner.key, key.value, victim.index.fileName);
      if (!current()) return false;
      owner.entries.remove(victim.entry.canonicalKey);
      owner.unindexed.remove(victim.entry.canonicalKey);
      owner.indexTrusted = false;
      owner.indexDirty = true;
    }
    return false;
  }

  Future<bool> _commitIndex(_Account account, bool Function() current) async {
    bool permitted() =>
        current() && account.unindexed.values.every((lease) => lease.isCurrent);
    while (permitted()) {
      final index = ReadCacheIndex(
        entries: account.entries.values.map((e) => e.index).toList(),
      );
      late int indexBytes;
      try {
        indexBytes = const ReadCacheCipher().encodeIndex(index).length;
      } on ReadCacheCodecException {
        if (account.entries.isEmpty) rethrow;
        final oldest = account.entries.values.reduce(
          (a, b) => a.index.lastUsedAt.isBefore(b.index.lastUsedAt) ? a : b,
        );
        await _files!.evict(
          account.key,
          account.keyBytes,
          oldest.index.fileName,
        );
        account.entries.remove(oldest.entry.canonicalKey);
        account.unindexed.remove(oldest.entry.canonicalKey);
        continue;
      }
      if (!await _makeRoom(
        account,
        indexBytes + readCacheEnvelopeOverhead,
        permitted,
      )) {
        throw const ReadCacheFileException(ReadCacheFileFailure.capacity);
      }
      if (!permitted()) return false;
      if (index.entries.length != account.entries.length) continue;
      final staged = await _files!.stageIndex(
        account.key,
        account.keyBytes,
        index,
        mayCommit: permitted,
      );
      if (staged == null) return false;
      if (staged.commit() == ReadCacheCommitResult.committed) {
        account.indexTrusted = true;
        account.indexDirty = false;
        account.unindexed.clear();
        return true;
      }
      return false;
    }
    return false;
  }

  void _drop(_Account account, _Write work) {
    account.queuedBytes -= work.bytes;
    work.lease.revoke();
    _domain.dropped++;
  }

  void _dropQueue(_Account account) {
    while (account.pending.isNotEmpty) {
      _drop(account, account.pending.removeFirst());
    }
    account.cancelBatch?.call();
    account.cancelBatch = null;
    account.batchDeadline = null;
  }

  void revoke(DiskBinding binding) {
    final account = _account(binding.accountKey);
    if (_domain.active != binding) return;
    _domain.revokedThrough = max(_domain.revokedThrough, binding.generation);
    account.epoch++;
    account.state = account.cleanup
        ? ReadCacheDiskState.cleaning
        : ReadCacheDiskState.closed;
    _dropQueue(account);
    for (final work in account.inFlight) {
      work.lease.revoke();
    }
    for (final lease in account.reads) {
      lease.revoke();
    }
    if (_domain.active == binding) _domain.active = null;
  }

  void background() {
    _domain.foreground = false;
    _suspendAccounts();
  }

  void _suspendAccounts() {
    for (final account in _domain.accounts.values) {
      account.epoch++;
      _dropQueue(account);
      for (final work in account.inFlight) {
        work.lease.revoke();
      }
      if (!account.cleanup) account.state = ReadCacheDiskState.closed;
    }
  }

  Future<bool> resume(DiskBinding binding) async {
    _domain.foreground = true;
    if (!configured) return false;
    _domain.setting = await _settings!.read();
    return activate(binding);
  }

  _Intent _fullIntent(_Account account, ReadCacheClearReason reason) {
    account.epoch++;
    account.cleanup = true;
    account.clearComplete = false;
    account.state = ReadCacheDiskState.cleaning;
    account.cancelRetry?.call();
    account.cancelRetry = null;
    _dropQueue(account);
    for (final work in account.inFlight) {
      work.lease.revoke();
    }
    for (final lease in account.reads) {
      lease.revoke();
    }
    account.keyBytes = null;
    final intent = _Intent(_marker(reason), ++account.revision, full: true);
    account.intent = intent;
    return intent;
  }

  ReadCacheClearMarker _marker(ReadCacheClearReason reason) =>
      ReadCacheClearMarker(
        intentId: List.generate(
          16,
          (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join(),
        reason: reason,
        requestedAt: _clock().toUtc(),
      );

  Future<T> _markerSerial<T>(_Account account, Future<T> Function() action) {
    final result = Completer<T>();
    account.markerTail = account.markerTail.then((_) async {
      try {
        result.complete(await action());
      } on Object catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<bool> _persist(_Account account, _Intent intent) =>
      _markerSerial(account, () => _persistNow(account, intent));

  Future<bool> _persistNow(_Account account, _Intent intent) async {
    try {
      if (account.intent != intent || !intent.valid) return false;
      if (!intent.durable) await _keys!.writeMarker(account.key, intent.marker);
      final read = await _keys!.readMarker(account.key);
      intent.durable = read.isFound && read.value == intent.marker;
      return intent.durable;
    } on Object {
      intent.durable = false;
      return false;
    }
  }

  Future<bool> _removeIntent(_Account account, _Intent intent) =>
      _markerSerial(account, () => _removeIntentNow(account, intent));

  Future<bool> _removeIntentNow(_Account account, _Intent intent) async {
    if (account.intent != intent || !intent.durable || !intent.valid) {
      return false;
    }
    try {
      final read = await _keys!.readMarker(account.key);
      if (account.intent != intent ||
          !intent.valid ||
          !read.isFound ||
          read.value != intent.marker) {
        return false;
      }
      await _keys!.deleteMarker(account.key);
      if (account.intent != intent || !intent.valid) {
        // The native delete was already in flight when this owner was revoked.
        // Restore the current pending intent before releasing the I/O section.
        var pending = account.intent;
        if (pending != null) {
          if (!pending.valid) {
            pending = _fullIntent(account, ReadCacheClearReason.accountClear);
          }
          pending.durable = false;
          await _persistNow(account, pending);
        }
        return false;
      }
      account.intent = null;
      return true;
    } on Object {
      if (account.intent != intent || !intent.valid) {
        var pending = account.intent;
        if (pending != null) {
          if (!pending.valid) {
            pending = _fullIntent(account, ReadCacheClearReason.accountClear);
          }
          pending.durable = false;
          await _persistNow(account, pending);
        }
      }
      return false;
    }
  }

  Future<bool> _directoryGone(String accountKey) async {
    final state = await _files!.accountDirectoryState(accountKey);
    final names = await _files!.accountDirectoryNames();
    return state == ReadCacheDirectoryState.absent &&
        !names.contains(ReadCacheCipher.accountDirectoryName(accountKey));
  }

  Future<bool> _empty(
    _Account account,
    ReadCacheSecureInventory inventory,
    bool hadWork,
  ) async =>
      inventory.status == ReadCacheStoreReadStatus.found &&
      inventory.malformedNames.isEmpty &&
      !inventory.keys.containsKey(account.key) &&
      !inventory.markers.containsKey(account.key) &&
      !hadWork &&
      account.pending.isEmpty &&
      account.inFlight.isEmpty &&
      account.reads.isEmpty &&
      await _directoryGone(account.key);

  Future<DiskClearResult> _clearNow(
    _Account account,
    _Intent intent, {
    required bool hadWork,
    Future<bool>? markerReady,
  }) async {
    if (!configured) return _none;
    // Revoked callers can have abandoned an already dispatched native marker
    // write. Drain that lane before taking the inventory used to prove empty.
    await account.markerTail;
    final inventory = await _keys!.readInventory();
    try {
      if (await _empty(account, inventory, hadWork)) {
        if (account.intent != intent || !intent.valid) return _none;
        account.intent = null;
        account.clearComplete = true;
        return const DiskClearResult(
          keyGoneConfirmed: true,
          directoryGoneConfirmed: true,
          markerDurable: false,
          complete: true,
        );
      }
    } on Object {
      // Unknown is not empty. Still attempt both independent explicit deletes.
    }
    final durable = await (markerReady ?? _persist(account, intent));
    var keyGone = false, directoryGone = false;
    try {
      await _keys!.deleteKey(account.key);
      keyGone =
          (await _keys!.readKey(account.key)).status ==
          ReadCacheStoreReadStatus.absent;
    } on Object {
      // Directory deletion proceeds even if secure storage is unavailable.
    }
    try {
      await _files!.clearAccount(account.key);
      directoryGone = await _directoryGone(account.key);
    } on Object {
      // Neither an acknowledgement nor an I/O error is evidence of absence.
    }
    account.entries.clear();
    account.unindexed.clear();
    account.indexTrusted = false;
    account.indexDirty = false;
    var complete = false;
    if (keyGone &&
        directoryGone &&
        durable &&
        inventory.status == ReadCacheStoreReadStatus.found &&
        inventory.malformedNames.isEmpty) {
      complete = await _removeIntent(account, intent);
      if (complete) {
        account.invalidations.clear();
        account.clearComplete = true;
      }
    }
    return DiskClearResult(
      keyGoneConfirmed: keyGone,
      directoryGoneConfirmed: directoryGone,
      markerDurable: durable,
      complete: complete,
    );
  }

  Future<DiskClearResult> clear(
    DiskBinding binding,
    ReadCacheCleanupOperation operation,
  ) {
    final account = _account(binding.accountKey);
    _domain.startupRevision++;
    if (operation == ReadCacheCleanupOperation.accountRemoval ||
        operation == ReadCacheCleanupOperation.signOut) {
      account.sessionFence = binding;
    }
    final hadWork =
        _domain.work > 0 ||
        account.work > 0 ||
        account.pending.isNotEmpty ||
        account.inFlight.isNotEmpty ||
        account.reads.isNotEmpty;
    final intent = _fullIntent(account, ReadCacheClearReason.accountClear);
    // Persist before waiting for old file/key work. The intent lane is separate
    // from the draining I/O lane, so a paused isolate cannot delay the marker.
    final preferencePending = _domain.preferenceChanges > 0;
    final markerReady = configured && hadWork && !preferencePending
        ? _persist(account, intent)
        : null;
    final future = _serial(account, () async {
      final result = await _clearNow(
        account,
        intent,
        // A preceding preference sweep drains the historical work. Prove empty
        // again here instead of starting a late marker for that drained work.
        hadWork: hadWork && !preferencePending,
        markerReady: markerReady,
      );
      if (result.complete && account.intent == null && intent.valid) {
        // Removal/session clears stay fenced even after all storage is gone.
        if (operation == ReadCacheCleanupOperation.settingsClear &&
            account.sessionFence == null) {
          account.cleanup = false;
        }
        account.state = account.cleanup
            ? ReadCacheDiskState.cleaning
            : ReadCacheDiskState.closed;
        supersedeNotice(binding);
      }
      return result;
    });
    return _wait(binding, operation, future, () {
      if (account.intent == intent) {
        intent.valid = false;
        account.epoch++;
        account.cleanup = true;
        account.state = ReadCacheDiskState.cleaning;
      }
    }).then((result) {
      if (result.complete &&
          intent.valid &&
          operation == ReadCacheCleanupOperation.settingsClear &&
          _gates(binding)) {
        unawaited(activate(binding));
      }
      return result;
    });
  }

  Future<void> clearReadCacheDisk(String accountKey) async {
    final binding = _domain.active?.accountKey == accountKey
        ? _domain.active!
        : DiskBinding(accountKey: accountKey, generation: 0);
    final result = await clear(
      binding,
      ReadCacheCleanupOperation.accountRemoval,
    );
    if (!result.keyGoneConfirmed && !result.directoryGoneConfirmed) {
      throw _notices[binding]?.failure ??
          ApiFailure.readCacheCleanup(
            _cleanup(
              ReadCacheCleanupOperation.accountRemoval,
              result,
              ReadCacheCleanupCode.cleanupFailed,
            ),
          );
    }
  }

  ReadCacheCleanupState _cleanup(
    ReadCacheCleanupOperation operation,
    DiskClearResult result,
    ReadCacheCleanupCode code,
  ) => ReadCacheCleanupState(
    operation: operation,
    disposition: switch (operation) {
      ReadCacheCleanupOperation.mutation =>
        ReadCacheCleanupDisposition.requestBlockedBeforeSend,
      ReadCacheCleanupOperation.privacyRead =>
        ReadCacheCleanupDisposition.legalNetworkValueReturned,
      ReadCacheCleanupOperation.accountRemoval =>
        ReadCacheCleanupDisposition.accountRetained,
      ReadCacheCleanupOperation.signOut =>
        ReadCacheCleanupDisposition.signedOutCleanupPending,
      _ => ReadCacheCleanupDisposition.diskClosed,
    },
    code: code,
    clearResult: result,
  );

  Future<DiskClearResult> _wait(
    DiskBinding binding,
    ReadCacheCleanupOperation operation,
    Future<DiskClearResult> underlying,
    void Function() timeout, {
    bool Function(DiskClearResult)? succeeded,
  }) {
    final result = Completer<DiskClearResult>();
    final cancel = _schedule(barrierLimit, () {
      timeout();
      reportCleanup(
        binding,
        _cleanup(operation, _none, ReadCacheCleanupCode.barrierTimedOut),
      );
      result.complete(_none);
    });
    unawaited(
      underlying.then(
        (value) {
          if (result.isCompleted) return;
          cancel();
          if (!(succeeded?.call(value) ?? value.complete)) {
            reportCleanup(
              binding,
              _cleanup(operation, value, ReadCacheCleanupCode.cleanupFailed),
            );
          }
          result.complete(value);
        },
        onError: (Object _, StackTrace _) {
          if (result.isCompleted) return;
          cancel();
          reportCleanup(
            binding,
            _cleanup(operation, _none, ReadCacheCleanupCode.cleanupFailed),
          );
          result.complete(_none);
        },
      ),
    );
    return result.future;
  }

  DiskInvalidationFence invalidate(DiskInvalidation invalidation) {
    final binding = invalidation.binding;
    final account = _account(binding.accountKey);
    final fence = _Fence();
    if (invalidation.kind == DiskInvalidationKind.account) {
      final barrier = clear(binding, ReadCacheCleanupOperation.signOut);
      fence.finish(barrier, quiesced);
      return fence;
    }
    account.invalidations.add(invalidation);
    account.indexRevision++;
    bool matches(ProjectedDiskEntry entry) => _matches(entry, invalidation);
    for (final work in account.pending.toList()) {
      if (matches(work.entry)) {
        account.pending.remove(work);
        _drop(account, work);
      }
    }
    for (final work in account.inFlight) {
      if (matches(work.entry)) work.lease.revoke();
    }
    for (final record in account.entries.values) {
      if (matches(record.entry)) {
        account.unindexed[record.entry.canonicalKey]?.revoke();
      }
    }
    // A read may have passed its disk await. Reject all active reads rather than
    // guess which body it will contain; subsequent unrelated reads stay allowed.
    for (final lease in account.reads) {
      lease.revoke();
    }
    // A full-clear fence already owns the marker. Join it without introducing
    // a scope intent that could outlive the completed clear.
    final preferencePending = _domain.preferenceChanges > 0;
    final intent = preferencePending
        ? null
        : account.cleanup
        ? account.intent
        : (account.intent ??= _Intent(
            _marker(ReadCacheClearReason.scopeInvalidation),
            ++account.revision,
            full: false,
          ));
    if (intent != null && !intent.full) intent.users++;
    final proveEmpty = !account.indexTrusted && !_ready(binding);
    final markerReady = intent != null && !intent.full && !proveEmpty
        ? _persist(account, intent)
        : null;
    final operation = invalidation.kind == DiskInvalidationKind.privacy
        ? ReadCacheCleanupOperation.privacyRead
        : ReadCacheCleanupOperation.mutation;
    var scopeSucceeded = false;
    final raw = _serial(account, () async {
      try {
        if (!configured || !fence.isCurrent) return _none;
        if (preferencePending && !account.cleanup) {
          // Settings owns the sweep until this serial section starts. Do not
          // dispatch a marker write behind its final inventory proof.
          final full = _fullIntent(account, ReadCacheClearReason.accountClear);
          return await _clearNow(account, full, hadWork: false);
        }
        if (account.cleanup) {
          if (account.clearComplete && account.intent == null) {
            account.invalidations.remove(invalidation);
            return const DiskClearResult(
              keyGoneConfirmed: true,
              directoryGoneConfirmed: true,
              markerDurable: false,
              complete: true,
            );
          }
          final full = account.intent;
          if (full == null || !full.full || !full.valid) return _none;
          return await _clearNow(account, full, hadWork: true);
        }
        if (intent == null ||
            intent.full ||
            !intent.valid ||
            account.intent != intent) {
          return _none;
        }
        if (proveEmpty) await account.markerTail;
        if (proveEmpty &&
            await _empty(account, await _keys!.readInventory(), false)) {
          if (!fence.isCurrent ||
              account.intent != intent ||
              !intent.valid ||
              account.cleanup ||
              account.pending.isNotEmpty ||
              account.inFlight.isNotEmpty ||
              account.reads.isNotEmpty) {
            return _none;
          }
          intent.users--;
          if (intent.users == 0) account.intent = null;
          scopeSucceeded = true;
          account.invalidations.remove(invalidation);
          return const DiskClearResult(
            keyGoneConfirmed: true,
            directoryGoneConfirmed: true,
            markerDurable: false,
            complete: true,
          );
        }
        final durable = await (markerReady ?? _persist(account, intent));
        if (!durable || !account.indexTrusted) {
          final full = _fullIntent(account, ReadCacheClearReason.accountClear);
          return await _clearNow(account, full, hadWork: true);
        }
        final key = await _keys!.readKey(account.key);
        if (!key.isFound) {
          final full = _fullIntent(account, ReadCacheClearReason.accountClear);
          return await _clearNow(account, full, hadWork: true);
        }
        account.keyBytes = key.value;
        for (final record in account.entries.values.toList()) {
          if (!matches(record.entry)) continue;
          await _files!.evict(account.key, key.value, record.index.fileName);
          account.entries.remove(record.entry.canonicalKey);
          account.unindexed.remove(record.entry.canonicalKey);
        }
        bool current() =>
            fence.isCurrent && account.intent == intent && !account.cleanup;
        if (!current()) return _none;
        if (!await _commitIndex(account, current)) return _none;
        if (!current()) return _none;
        intent.users--;
        if (intent.users == 0 && !await _removeIntent(account, intent)) {
          return _none;
        }
        scopeSucceeded = true;
        account.invalidations.remove(invalidation);
        // These are account-clear facts, not a false claim that retained data
        // or its key is gone. A scoped barrier signals success by resolving;
        // failure rejects with readCacheCleanup. Its full-clear fallback must
        // instead prove complete. The adapter must preserve that distinction.
        return DiskClearResult(
          keyGoneConfirmed: false,
          directoryGoneConfirmed: false,
          markerDurable: intent.durable,
          complete: false,
        );
      } on Object {
        final full = _fullIntent(account, ReadCacheClearReason.accountClear);
        return await _clearNow(account, full, hadWork: true);
      }
    });
    final waited = _wait(binding, operation, raw, () {
      fence.revoke();
      intent?.valid = false;
      _fullIntent(account, ReadCacheClearReason.accountClear);
    }, succeeded: (value) => scopeSucceeded || value.complete);
    final barrier = waited.then((result) {
      if (scopeSucceeded || result.complete) return result;
      if (!account.cleanup) {
        _fullIntent(account, ReadCacheClearReason.accountClear);
      }
      throw ApiFailure.readCacheCleanup(
        _notices[binding]?.failure.cleanup ??
            _cleanup(operation, result, ReadCacheCleanupCode.cleanupFailed),
      );
    });
    fence.finish(barrier, quiesced);
    return fence;
  }

  /// Reads a complete inventory before either orphan sweep. Ordinary unknown
  /// settings/storage never authorize filesystem work. The caller owns the
  /// session decision and retries with a new revision when membership changes.
  Future<bool> recover(
    ReadCacheStartupDecision decision, {
    required Set<String> accountKeys,
  }) async {
    final revision = ++_domain.startupRevision;
    _domain.recovered = false;
    if (!configured || !decision.readable || _domain.preferenceChanges > 0) {
      return false;
    }
    final setting = await _settings!.read();
    if (revision != _domain.startupRevision ||
        setting == ReadCacheSettingsState.unavailable) {
      return false;
    }
    final inventory = await _keys!.readInventory();
    if (revision != _domain.startupRevision ||
        inventory.status != ReadCacheStoreReadStatus.found) {
      return false;
    }
    _domain.setting = setting;
    for (final account in _domain.accounts.values) {
      account.epoch++;
      _dropQueue(account);
      account.state = ReadCacheDiskState.closed;
    }
    final retained =
        !decision.signOutPending &&
            setting == ReadCacheSettingsState.enabled &&
            accountKeys.contains(decision.resumeAccountKey)
        ? <String>{decision.resumeAccountKey!}
        : <String>{};
    final success = await _serial<bool>(null, () async {
      if (revision != _domain.startupRevision) return false;
      var ok = true;
      if (inventory.malformedNames.isNotEmpty) {
        try {
          await _files!.clearRoot();
          if ((await _files!.accountDirectoryNames()).isNotEmpty) return false;
          for (final name in inventory.malformedNames) {
            if (revision != _domain.startupRevision) return false;
            await _keys!.deleteInventoryName(name);
          }
        } on Object {
          return false;
        }
      }
      for (final key in {
        ...inventory.markers.keys,
        ...inventory.keys.keys.where((k) => !retained.contains(k)),
      }) {
        if (revision != _domain.startupRevision) return false;
        final account = _account(key);
        final intent = _fullIntent(account, ReadCacheClearReason.startup);
        final result = await _clearNow(account, intent, hadWork: true);
        if (result.complete) {
          account.cleanup = account.sessionFence != null;
          account.state = account.cleanup
              ? ReadCacheDiskState.cleaning
              : ReadCacheDiskState.closed;
        } else {
          ok = false;
        }
      }
      if (revision != _domain.startupRevision) return false;
      try {
        await _files!.clearAccountDirectoriesExcept(retained);
      } on ReadCacheFileException catch (error) {
        if (error.code != ReadCacheFileFailure.untrustedPath) return false;
        if (revision != _domain.startupRevision) return false;
        try {
          await _files!.clearRoot();
        } on Object {
          return false;
        }
      } on Object {
        return false;
      }
      try {
        final names = await _files!.accountDirectoryNames();
        final retainedNames = retained
            .map(ReadCacheCipher.accountDirectoryName)
            .toSet();
        if (names.any((name) => !retainedNames.contains(name))) return false;
      } on Object {
        return false;
      }
      final confirmed = await _keys!.readInventory();
      if (confirmed.status != ReadCacheStoreReadStatus.found ||
          confirmed.malformedNames.isNotEmpty ||
          confirmed.markers.isNotEmpty ||
          confirmed.keys.keys.any((k) => !retained.contains(k))) {
        return false;
      }
      return ok && revision == _domain.startupRevision;
    });
    if (!success || revision != _domain.startupRevision) return false;
    _domain.recovered = true;
    final active = _domain.active;
    if (active != null) {
      if (retained.contains(active.accountKey)) {
        await activate(active);
      } else {
        // A pre-scan activation cannot override the session's resume decision.
        // Fence delayed duplicates; a later session supplies a newer generation.
        revoke(active);
        _domain.active = null;
      }
    }
    return true;
  }

  Future<DiskClearResult> retryCleanup(
    DiskBinding binding,
    ReadCacheCleanupOperation operation,
  ) => clear(binding, operation);

  Future<bool> setEnabled(bool enabled) async {
    if (!configured) return false;
    _domain.preferenceChanges++;
    _domain.startupRevision++;
    _domain.recovered = false;
    _suspendAccounts();
    try {
      return await _storeEnabled(enabled);
    } finally {
      _domain.preferenceChanges--;
      _domain.recovered = false;
      _domain.startupRevision++;
    }
  }

  Future<bool> _storeEnabled(bool enabled) async {
    final stored = await _settings!.writeEnabled(enabled);
    if (!stored) _domain.setting = ReadCacheSettingsState.unavailable;
    if (stored) {
      _domain.setting = enabled
          ? ReadCacheSettingsState.enabled
          : ReadCacheSettingsState.disabled;
    }
    if (!enabled) {
      // Include accounts whose first key write is not in secure inventory yet.
      // Fence/persist before drain; inventory and the final proof share the I/O
      // section with that late write, so no success can race its completion.
      final intents = <String, _Intent>{};
      final markers = <String, Future<bool>>{};
      for (final account in _domain.accounts.values) {
        final intent = _fullIntent(account, ReadCacheClearReason.accountClear);
        intents[account.key] = intent;
        if (account.work > 0 || _domain.work > 0) {
          markers[account.key] = _persist(account, intent);
        }
      }
      final cleared = await _serial<bool>(null, () async {
        final inventory = await _keys!.readInventory();
        if (inventory.status != ReadCacheStoreReadStatus.found) return false;
        try {
          if (inventory.malformedNames.isNotEmpty) {
            await _files!.clearRoot();
            if ((await _files!.accountDirectoryNames()).isNotEmpty) {
              return false;
            }
            for (final name in inventory.malformedNames) {
              await _keys!.deleteInventoryName(name);
            }
          }
          for (final key in {
            ...intents.keys,
            ...inventory.keys.keys,
            ...inventory.markers.keys,
          }) {
            final account = _account(key);
            final intent =
                intents[key] ??
                _fullIntent(account, ReadCacheClearReason.accountClear);
            final result = await _clearNow(
              account,
              intent,
              hadWork: markers.containsKey(key),
              markerReady: markers[key],
            );
            if (!result.complete) return false;
            account.cleanup = account.sessionFence != null;
          }
          await _files!.clearAccountDirectoriesExcept({});
          final confirmed = await _keys!.readInventory();
          if (confirmed.status != ReadCacheStoreReadStatus.found ||
              confirmed.keys.isNotEmpty ||
              confirmed.markers.isNotEmpty ||
              confirmed.malformedNames.isNotEmpty ||
              (await _files!.accountDirectoryNames()).isNotEmpty) {
            return false;
          }
          for (final account in _domain.accounts.values) {
            account.state = stored
                ? ReadCacheDiskState.disabled
                : ReadCacheDiskState.unavailable;
          }
          return true;
        } on Object {
          return false;
        }
      });
      if (!cleared) return false;
    }
    // Re-enabling still requires a fresh startup decision and verified binding.
    return stored;
  }
}

const _none = DiskClearResult(
  keyGoneConfirmed: false,
  directoryGoneConfirmed: false,
  markerDurable: false,
  complete: false,
);

void Function() _timer(Duration delay, void Function() callback) {
  final timer = Timer(delay, callback);
  return timer.cancel;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var different = 0;
  for (var i = 0; i < a.length; i++) {
    different |= a[i] ^ b[i];
  }
  return different == 0;
}

ReadCacheIndexEntry _used(ReadCacheIndexEntry entry, DateTime now) =>
    ReadCacheIndexEntry(
      fileName: entry.fileName,
      sizeBytes: entry.sizeBytes,
      fetchedAt: entry.fetchedAt,
      lastUsedAt: now.toUtc(),
      cacheClass: entry.cacheClass,
      scopeTags: entry.scopeTags,
      issueIdentities: entry.issueIdentities,
    );

bool _matches(ProjectedDiskEntry entry, DiskInvalidation invalidation) {
  if (invalidation.kind == DiskInvalidationKind.account) return true;
  if (invalidation.kind == DiskInvalidationKind.mutation && entry.pinned) {
    return false;
  }
  if (invalidation.canonicalKey == entry.canonicalKey) return true;
  if (invalidation.scopeTags.contains('global') ||
      entry.scopeTags.any(invalidation.scopeTags.contains)) {
    return true;
  }
  if (entry.issueIdentities.any(invalidation.issueIdentities.contains)) {
    return true;
  }
  // Privacy also evicts project issue-list keys even when their current page
  // does not contain that issue. Identity matches above cover cross-scope links.
  try {
    final decoded = jsonDecode(entry.canonicalKey);
    if (decoded is List && decoded.length >= 3 && decoded[2] is String) {
      final path = decoded[2] as String;
      if (invalidation.path case final uri?) {
        if (path == uri.path || path.startsWith('${uri.path}/')) return true;
      }
      if (invalidation.kind == DiskInvalidationKind.privacy) {
        for (final issue in invalidation.issueIdentities) {
          if (path.endsWith('/projects/${issue.projectId}/issues')) return true;
        }
      }
    }
  } on Object {
    // Unknown key shape cannot be used as path evidence.
    return invalidation.path != null;
  }
  return false;
}

final class _Domain {
  final notices = <DiskBinding, ReadCacheNotice>{};
  final signedOut = <DiskBinding, ReadCacheNotice>{};
  final subscribers = <ReadCacheNoticeSink>{};
  final accounts = <String, _Account>{};
  Future<void> tail = Future.value();
  bool recovered = false, controlsInstalled = false, foreground = true;
  ReadCacheSettingsState setting = ReadCacheSettingsState.unavailable;
  DiskBinding? active;
  DiskBinding? latestVerified;
  int highestGeneration = -1, revokedThrough = -1, preferenceChanges = 0;
  int dropped = 0, startupRevision = 0, work = 0;
}

final class _Account {
  _Account(this.key);
  final String key;
  Future<void> markerTail = Future.value();
  ReadCacheDiskState state = ReadCacheDiskState.closed;
  int epoch = 0, revision = 0, work = 0, queuedBytes = 0, retryAttempt = 0;
  bool cleanup = false, indexTrusted = false;
  bool indexDirty = false, flushForced = false;
  bool clearComplete = false;
  DiskBinding? sessionFence;
  int indexRevision = 0;
  final invalidations = <DiskInvalidation>{};
  Uint8List? keyBytes;
  final pending = Queue<_Write>();
  final inFlight = <_Write>{};
  final unindexed = <String, _CommitLease>{};
  final reads = <_CommitLease>{};
  final entries = <String, _Record>{};
  _Intent? intent;
  Future<void>? flush;
  DateTime? batchDeadline;
  void Function()? cancelBatch, cancelRetry;
}

final class _Intent {
  _Intent(this.marker, this.revision, {required this.full});
  final ReadCacheClearMarker marker;
  final int revision;
  final bool full;
  bool durable = false, valid = true;
  int users = 0;
}

final class _CommitLease implements DiskCommitLease {
  _CommitLease(this._check);
  final bool Function() _check;
  bool _current = true;
  @override
  bool get isCurrent => _current && _check();
  @override
  void revoke() => _current = false;
}

final class _Write {
  _Write(this.entry, this.bytes, this.lease);
  final ProjectedDiskEntry entry;
  final int bytes;
  final _CommitLease lease;
}

final class _Record {
  _Record(this.entry, this.index);
  final ProjectedDiskEntry entry;
  final ReadCacheIndexEntry index;
}

final class _Fence implements DiskInvalidationFence {
  bool _current = true;
  late Future<DiskClearResult> _barrier;
  late Future<void> _quiesced;
  void finish(Future<DiskClearResult> barrier, Future<void> quiesced) {
    _barrier = barrier;
    _quiesced = quiesced;
  }

  @override
  bool get isCurrent => _current;
  @override
  Future<DiskClearResult> get barrier => _barrier;
  @override
  Future<void> get quiesced => _quiesced;
  @override
  void revoke() => _current = false;
}
