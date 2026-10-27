part of 'gitlab_api.dart';

final Type _jsonPageType = ApiPage<Json>;

enum CacheLineage { network, memory, disk }

/// A dropped admission has no value. Superseded values must not be published.
final class CachedRead<T> {
  /// Carries a caller's send fence through cached loader closures unchanged.
  static Future<R> run<R>(
    Future<R> Function() body, {
    required bool Function() mayStart,
    bool waitForQuiet = false,
  }) {
    final outer = Zone.current[#cachedReadMayStart] as bool Function()?;
    return runZoned(
      body,
      zoneValues: <Object?, Object?>{
        #cachedReadMayStart: () => (outer?.call() ?? true) && mayStart(),
        #cachedReadWaitForQuiet:
            waitForQuiet || Zone.current[#cachedReadWaitForQuiet] == true,
      },
    );
  }

  const CachedRead({
    required T value,
    required DateTime fetchedAt,
    required this.lineage,
    this.stale = false,
    this.superseded = false,
  }) : _value = value,
       _fetchedAt = fetchedAt,
       dropped = false;

  const CachedRead.dropped()
    : _value = null,
      _fetchedAt = null,
      lineage = CacheLineage.network,
      stale = false,
      superseded = false,
      dropped = true;

  final T? _value;
  T get value {
    if (dropped) throw StateError('Dropped cache read has no value');
    return _value as T;
  }

  final DateTime? _fetchedAt;
  DateTime get fetchedAt {
    if (dropped) throw StateError('Dropped cache read has no timestamp');
    return _fetchedAt!;
  }

  final CacheLineage lineage;
  final bool stale, superseded, dropped;
}

/// C1a only supplies the read seam; no persistent store is installed.
final class CacheDiskEntry {
  const CacheDiskEntry({
    required this.value,
    required this.fetchedAt,
    required this.responseBytes,
    this.issueIdentities = const {},
  });
  final Object value;
  final DateTime fetchedAt;
  final int responseBytes;
  final Set<ReadCacheIssueIdentity> issueIdentities;
}

/// Receives the caller-form REST URI, including unresolved project aliases,
/// rather than the cache's numeric publication key. A persistent source must
/// choose and verify its own canonical index key (and the Accept variant).
typedef ReadCacheSource =
    Future<CacheDiskEntry?> Function(Uri uri, String accept);

enum _ReadClass { projectMeta, ref, pinned, list, detail, thread, volatile }

extension CachedReadApi on GitLabApi {
  /// The session attaches after verification/binding. The coordinator keeps
  /// startup, controls and activation gates; attaching does not open them.
  void attachReadCacheDiskBackend(ReadCacheDiskBackend backend) {
    if (!_cache.enabled || _cache.diskBackend != null) {
      throw StateError('Read cache must be bound exactly once before attach');
    }
    _cache.diskBackend = backend;
  }

  /// Called once, after /user verification and the session generation advances.
  void bindReadCache(String accountKey, int generation) =>
      _cache.bind(accountKey, generation);
  bool get isReadCacheBound => _cache.enabled;
  String? get readCacheAccountKey => _cache.accountKey;
  int? get readCacheGeneration => _cache.generation;

  /// Bounded state sizes, without resource identifiers or cached content.
  Map<String, int> get readCacheMetadataCounts => Map.unmodifiable({
    'aliases': _cache.aliases.length,
    'versions': _cache.versions.length,
    'writes': _cache.writes.length,
    'revocations': _cache.revocations.length,
    'sourceWrites': _cache.sourceWriteTimes.length,
    'sourceRevocations': _cache.sourceRevocations.length,
    'sourcePrivacyRevocations': _cache.sourcePrivacyRevocations.length,
    'publications': _cache.publicationTickets.length,
    'superseded': _cache.supersededFresh.length,
  });

  Future<CachedRead<Json>> cachedRecord(
    List<String> path, {
    Map<String, String> query = const {},
    bool fresh = false,
    Duration? maxAge,
    bool allowDisk = true,
    bool background = false,
  }) {
    final uri = _cache.canonical(
      instance.api(path, query),
      resolveAlias: false,
    );
    final policy = _cache.classify(uri, page: false);
    return _cache.read<Json>(
      uri,
      policy,
      () async {
        final response = await _read(uri);
        try {
          final value = objectJson(jsonDecode(utf8.decode(response.bytes)));
          _cache.observe(uri, value, learnAlias: false);
          return _LoadedRead(
            _freezeJson(value),
            response.bytes.length,
            _cacheTtl(response.headers, const Duration(minutes: 30)) >
                Duration.zero,
          );
        } on FormatException {
          throw const ApiFailure(FailureKind.invalidResponse);
        }
      },
      fresh: fresh,
      maxAge: maxAge,
      allowDisk: allowDisk,
      background: background,
    );
  }

  Future<CachedRead<ApiPage<Json>>> cachedRecords(
    List<String> path, {
    Map<String, String> query = const {},
    Uri? next,
    bool fresh = false,
    Duration? maxAge,
    bool allowDisk = true,
    bool background = false,
  }) {
    final first = _cache.canonical(
      instance.api(path, {'per_page': '30', ...query}),
      resolveAlias: false,
    );
    _validateContinuation(first, next);
    if (next != null) {
      return records(
        _cache.path(first),
        query: first.queryParameters,
        next: next,
      ).then(
        (page) => CachedRead(
          value: _freezeCached(page) as ApiPage<Json>,
          fetchedAt: _readCacheClock(),
          lineage: CacheLineage.network,
        ),
      );
    }
    final uri = first;
    final policy = _cache.classify(uri, page: true);
    return _cache.read<ApiPage<Json>>(
      uri,
      policy,
      () async {
        final response = await _read(uri);
        try {
          final decoded = jsonDecode(utf8.decode(response.bytes));
          if (decoded is! List<dynamic>) {
            throw const FormatException('Expected list');
          }
          final items = decoded
              .map((item) {
                final json = objectJson(item);
                if (path.length == 1 && path.first == 'projects') {
                  Project.fromJson(json);
                }
                _cache.observe(uri, json);
                return _freezeJson(json);
              })
              .toList(growable: false);
          final following = nextPageUri(
            instance: instance,
            current: uri,
            headers: response.headers.map,
          );
          _validateContinuation(first, following);
          return _LoadedRead(
            ApiPage<Json>(List.unmodifiable(items), next: following),
            response.bytes.length,
            _cacheTtl(response.headers, const Duration(minutes: 30)) >
                Duration.zero,
          );
        } on FormatException {
          throw const ApiFailure(FailureKind.invalidResponse);
        }
      },
      fresh: fresh,
      maxAge: maxAge,
      allowDisk: allowDisk,
      background: background,
      validate: (page) => _validateContinuation(first, page.next),
    );
  }
}

Object? _freezeValue(Object? value) {
  if (value is Map<String, dynamic>) return _freezeJson(value);
  if (value is List) return List<Object?>.unmodifiable(value.map(_freezeValue));
  return value;
}

Json _freezeJson(Json value) => Map<String, dynamic>.unmodifiable(
  value.map((key, value) => MapEntry(key, _freezeValue(value))),
);

final class _LoadedRead<T extends Object> {
  const _LoadedRead(this.value, this.bytes, this.store);
  final T value;
  final int bytes;
  final bool store;
}

final class _ReadEntry {
  const _ReadEntry(
    this.uri,
    this.value,
    this.fetchedAt,
    this.lineage,
    this.policy,
    this.scope,
    this.cost,
  );
  final Uri uri;
  final Object value;
  final DateTime fetchedAt;
  final CacheLineage lineage;
  final _ReadClass policy;
  final String scope;
  final int cost;
}

final class _PendingRead {
  const _PendingRead(
    this.uri,
    this.scope,
    this.pinned,
    this.background,
    this.future,
  );
  final Uri uri;
  final String scope;
  final bool pinned, background;
  final Future<Object> future;
}

final class _ReadAdmission {
  final ready = Completer<bool>();
}

final class _ReadDiskLease implements DiskCommitLease {
  _ReadDiskLease(this.check);
  final bool Function() check;
  bool _revoked = false;
  @override
  bool get isCurrent => !_revoked && check();
  @override
  void revoke() => _revoked = true;
}

/// All cache state belongs to one API instance. Writes fence mutable scopes;
/// permission revocation uses a separate fence that also covers pinned data.
final class _ReadCache {
  _ReadCache(this.api);
  final GitLabApi api;
  final entries = <String, _ReadEntry>{};
  final pending = <String, _PendingRead>{};
  final versions = <String, int>{};
  final writes = <String, int>{};
  final revocations = <String, int>{};
  final aliases = <String, ({String id, DateTime expiresAt})>{};
  final confirmed = <String, bool>{};
  final confidentialIssues =
      <
        String,
        ({bool confidential, CacheLineage lineage, DateTime fetchedAt})
      >{};
  bool publicIssueMarkerEvicted = false;
  final supersededFresh = <String, int>{};
  final publicationTickets = <String, int>{};
  final activePublications = <int>{};
  int publicationSequence = 0, publicationFloor = 0;
  final closing = StreamController<void>.broadcast(sync: true);
  final sourceWriteTimes = <String, DateTime>{};
  final sourceRevocations = <String, DateTime>{};
  final sourcePrivacyRevocations = <String, DateTime>{};
  DateTime? sourceAccountRevokedAt;
  static const metadataLimit = 4096;
  int revocationSequence = 0, revocationFloor = 0, versionSequence = 0;
  DateTime? sourceMutableWrittenAt;
  final foregroundQueue = <_ReadAdmission>[];
  final backgroundQueue = <_ReadAdmission>[];
  Completer<void> changed = Completer<void>();
  int bytes = 0, foreground = 0, background = 0, epoch = 0;
  int? verifiedUserId;
  String? accountKey;
  int? generation;
  bool boundOnce = false, enabled = false;
  DateTime? lastWriteStart;
  ReadCacheDiskBackend? diskBackend;
  final diskRevisions = <String, int>{};
  final diskSafety = <Future<void>>{};
  int privacyEpoch = 0;

  DiskBinding? get diskBinding =>
      enabled && accountKey != null && generation != null
      ? DiskBinding(accountKey: accountKey!, generation: generation!)
      : null;

  static const unknownClear = DiskClearResult(
    keyGoneConfirmed: false,
    directoryGoneConfirmed: false,
    markerDurable: false,
    complete: false,
  );

  void reportCleanup(ReadCacheCleanupState state) {
    try {
      diskBackend?.reportCleanup(state);
    } on Object {
      // A subscriber cannot replace a transport result.
    }
  }

  Future<void> awaitDiskBarrier(
    DiskInvalidationFence fence, {
    required ReadCacheCleanupOperation operation,
    required ReadCacheCleanupDisposition disposition,
    bool beforeSend = false,
  }) async {
    final cancelled = Completer<DiskClearResult>();
    final subscription = closing.stream.listen((_) {
      if (beforeSend && !cancelled.isCompleted) {
        cancelled.completeError(const ApiFailure(FailureKind.cancelled));
      }
    });
    try {
      if (beforeSend && api._closed) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      await Future.any([
        fence.barrier,
        if (beforeSend) cancelled.future,
      ]).timeout(const Duration(seconds: 5));
      if (beforeSend && api._closed) {
        throw const ApiFailure(FailureKind.cancelled);
      }
    } on Object catch (error) {
      fence.revoke();
      if (beforeSend && api._closed) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      final previous = error is ApiFailure ? error.cleanup : null;
      final state = ReadCacheCleanupState(
        operation: operation,
        disposition: disposition,
        code: error is TimeoutException
            ? ReadCacheCleanupCode.barrierTimedOut
            : previous?.code ?? ReadCacheCleanupCode.cleanupFailed,
        clearResult: previous?.clearResult ?? unknownClear,
      );
      reportCleanup(state);
      if (beforeSend) throw ApiFailure.readCacheCleanup(state);
    } finally {
      await subscription.cancel();
    }
  }

  DiskInvalidationFence? mutationDiskBarrier(
    Set<String> scopes, {
    required bool beforeSend,
  }) {
    final binding = diskBinding;
    if (binding == null) return null;
    try {
      return diskBackend?.invalidate(
        DiskInvalidation(
          binding: binding,
          kind: DiskInvalidationKind.mutation,
          scopeTags: scopes,
        ),
      );
    } on Object catch (error) {
      if (beforeSend && api._closed) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      final previous = error is ApiFailure ? error.cleanup : null;
      final state = ReadCacheCleanupState(
        operation: ReadCacheCleanupOperation.mutation,
        disposition: beforeSend
            ? ReadCacheCleanupDisposition.requestBlockedBeforeSend
            : ReadCacheCleanupDisposition.originalOutcomePreserved,
        code: previous?.code ?? ReadCacheCleanupCode.cleanupFailed,
        clearResult: previous?.clearResult ?? unknownClear,
      );
      reportCleanup(state);
      if (beforeSend) throw ApiFailure.readCacheCleanup(state);
      return null;
    }
  }

  void invalidateDisk(DiskInvalidation invalidation) {
    final backend = diskBackend;
    if (backend == null) return;
    final operation = invalidation.kind == DiskInvalidationKind.privacy
        ? ReadCacheCleanupOperation.privacyRead
        : ReadCacheCleanupOperation.startup;
    final disposition = invalidation.kind == DiskInvalidationKind.privacy
        ? ReadCacheCleanupDisposition.legalNetworkValueReturned
        : ReadCacheCleanupDisposition.diskClosed;
    final DiskInvalidationFence fence;
    try {
      fence = backend.invalidate(invalidation);
    } on Object catch (error) {
      final previous = error is ApiFailure ? error.cleanup : null;
      reportCleanup(
        ReadCacheCleanupState(
          operation: operation,
          disposition: disposition,
          code: previous?.code ?? ReadCacheCleanupCode.cleanupFailed,
          clearResult: previous?.clearResult ?? unknownClear,
        ),
      );
      return;
    }
    late final Future<void> work;
    work = awaitDiskBarrier(
      fence,
      operation: operation,
      disposition: disposition,
    ).whenComplete(() => diskSafety.remove(work));
    diskSafety.add(work);
  }

  Future<void> settleDiskSafety() async {
    while (diskSafety.isNotEmpty) {
      await Future.wait(List.of(diskSafety));
    }
  }

  void discardDiskKey(Uri uri, String accept) {
    final binding = diskBinding;
    if (binding == null || diskBackend == null || api._closed) return;
    final key = readCacheDurableKey(
      binding: binding,
      instance: api.instance,
      uri: uri,
      logicalAccept: accept,
      verifiedProjectAliases: projectionContext().verifiedProjectAliases,
    );
    if (key == null) return;
    invalidateDisk(
      DiskInvalidation(
        binding: binding,
        kind: DiskInvalidationKind.permission,
        canonicalKey: key,
      ),
    );
  }

  ReadCacheProjectionContext projectionContext() {
    final binding = diskBinding!;
    final current = <String, int>{'global': 0, ...versions};
    for (final entry in entries.values) {
      current.putIfAbsent(entry.scope, () => 0);
    }
    final proofs = <ReadCachePublicIssueProof>[];
    for (final entry in entries.values) {
      final p = path(entry.uri);
      final value = entry.value;
      if (p.length == 4 &&
          p[0] == 'projects' &&
          p[2] == 'issues' &&
          entry.lineage == CacheLineage.network &&
          value is Json &&
          value['confidential'] == false &&
          value['project_id'] is int &&
          value['iid'] is int) {
        proofs.add(
          ReadCachePublicIssueProof(
            binding: binding,
            identity: ReadCacheIssueIdentity(
              value['project_id'] as int,
              value['iid'] as int,
            ),
            fetchedAt: entry.fetchedAt,
            lineage: ReadCacheProofLineage.network,
            singleIssue: true,
            confidential: false,
            privacyEpoch: privacyEpoch,
            scopeVersions: snapshot(entry.scope, false),
          ),
        );
      }
    }
    return ReadCacheProjectionContext(
      instance: api.instance,
      binding: binding,
      now: api._readCacheClock(),
      privacyEpoch: privacyEpoch,
      scopeVersions: current,
      publicIssues: proofs,
      confidentialIssues: {
        for (final entry in confidentialIssues.entries)
          if (entry.value.confidential)
            ReadCacheIssueIdentity(
              int.parse(entry.key.split(':')[0]),
              int.parse(entry.key.split(':')[1]),
            ),
      },
      confirmedShas: confirmed.keys.toSet(),
      verifiedProjectAliases: {
        for (final entry in aliases.entries)
          if (api._readCacheClock().isBefore(entry.value.expiresAt))
            entry.key: int.parse(entry.value.id),
      },
      verifiedMergeRequestIds: {
        for (final entry in entries.values)
          if (entry.lineage == CacheLineage.network &&
              entry.value is Json &&
              path(entry.uri).length == 4 &&
              path(entry.uri)[2] == 'merge_requests' &&
              (entry.value as Json)['id'] is int)
            (int.parse(path(entry.uri)[1]), int.parse(path(entry.uri)[3])):
                (entry.value as Json)['id'] as int,
      },
    );
  }

  ReadCacheBodyKind? bodyKind<T>() => T == String
      ? ReadCacheBodyKind.text
      : T == _jsonPageType
      ? ReadCacheBodyKind.page
      : T == Json
      ? ReadCacheBodyKind.json
      : null;

  DiskWriteCandidate candidate(
    Uri uri,
    String accept,
    ReadCacheBodyKind kind,
    DateTime fetchedAt,
    int bytes,
    DiskCommitLease lease,
    Map<String, int> stamp, {
    bool store = true,
    Uri? next,
  }) => DiskWriteCandidate(
    binding: diskBinding!,
    uri: uri,
    logicalAccept: accept,
    bodyKind: kind,
    fetchedAt: fetchedAt,
    responseBytes: bytes,
    lease: lease,
    cacheable: true,
    noStore: !store,
    firstPage: !uri.queryParameters.keys.any(paginationKeys.contains),
    privacyEpoch: privacyEpoch,
    scopeVersions: stamp,
    scopeTags: stamp.keys.toSet(),
    next: next,
  );

  Object diskProjectionInput(Object raw) {
    // D2 omits malformed colour strings from an otherwise valid label. The
    // network schema requires that field, so replay its omission marker only
    // while revalidating projected disk data. Never relax network admission.
    var nodes = 0;
    Object? copy(Object? value, int depth, {bool labelDetails = false}) {
      if (++nodes > readCacheMaxValueNodes || depth > readCacheMaxDepth) {
        throw const FormatException();
      }
      if (value is List<Object?>) {
        if (value.length > readCacheMaxArrayLength) {
          throw const FormatException();
        }
        return [
          for (final item in value)
            copy(item, depth + 1, labelDetails: labelDetails),
        ];
      }
      if (value is Map<String, Object?>) {
        return <String, Object?>{
          for (final entry in value.entries)
            entry.key: copy(
              entry.value,
              depth + 1,
              labelDetails: entry.key == 'labels',
            ),
          if (labelDetails && !value.containsKey('color')) 'color': '',
        };
      }
      if (value == null || value is String || value is num || value is bool) {
        return value;
      }
      throw const FormatException();
    }

    return copy(raw, 1)!;
  }

  Future<CacheDiskEntry?> lookupDisk<T>(
    Uri uri,
    String accept,
    Map<String, int> permission,
    Map<String, int> stamp, {
    required void Function() rejectedPrivacy,
    required bool Function() canDiscard,
  }) async {
    final backend = diskBackend;
    if (backend == null) return api._readCacheSource?.call(uri, accept);
    final binding = diskBinding;
    final kind = bodyKind<T>();
    if (binding == null || kind == null) return null;
    final context = projectionContext();
    final key = readCacheDurableKey(
      binding: binding,
      instance: api.instance,
      uri: uri,
      logicalAccept: accept,
      verifiedProjectAliases: context.verifiedProjectAliases,
    );
    if (key == null) return null;
    final lease = _ReadDiskLease(
      () =>
          diskBinding == binding &&
          !api._closed &&
          permitted(permission, uri) &&
          stable(stamp),
    );
    Future<void> discardInvalidEntry() async {
      if (!lease.isCurrent ||
          !canDiscard() ||
          diskBinding != binding ||
          api._closed) {
        return;
      }
      invalidateDisk(
        DiskInvalidation(
          binding: binding,
          kind: DiskInvalidationKind.permission,
          canonicalKey: key,
        ),
      );
      await settleDiskSafety();
      if (api._closed) throw const ApiFailure(FailureKind.cancelled);
    }

    try {
      final entry = await backend.lookup(
        DiskLookup(
          binding: binding,
          canonicalKey: key,
          bodyKind: kind,
          lease: lease,
        ),
      );
      if (entry == null || !lease.isCurrent) return null;
      if (entry.canonicalKey != key || entry.accountKey != binding.accountKey) {
        await discardInvalidEntry();
        return null;
      }
      if (entry.bodyKind != kind) {
        await discardInvalidEntry();
        return null;
      }
      Object raw = entry.body;
      Uri? next;
      if (kind == ReadCacheBodyKind.page) {
        if (raw is! Map<String, Object?> || raw['items'] is! List<Object?>) {
          await discardInvalidEntry();
          return null;
        }
        final rawNext = raw['next'];
        if (rawNext != null && rawNext is! String) {
          await discardInvalidEntry();
          return null;
        }
        next = rawNext == null ? null : Uri.tryParse(rawNext as String);
        if (rawNext != null && next == null) {
          await discardInvalidEntry();
          return null;
        }
        try {
          api._validateContinuation(uri, next);
        } on ApiFailure {
          await discardInvalidEntry();
          return null;
        }
        raw = raw['items']!;
      }
      if (!observeRawPrivacy(
        uri,
        raw,
        lineage: CacheLineage.disk,
        fetchedAt: entry.fetchedAt,
      )) {
        rejectedPrivacy();
        await settleDiskSafety();
        return null;
      }
      final Object projectionInput;
      try {
        projectionInput = diskProjectionInput(raw);
      } on FormatException {
        await discardInvalidEntry();
        return null;
      }
      final current = projectionContext();
      final projected = projectReadCacheResponse(
        candidate(
          uri,
          accept,
          kind,
          entry.fetchedAt,
          entry.serializedLength,
          lease,
          stamp,
          next: next,
        ),
        projectionInput,
        ReadCacheProjectionContext(
          instance: current.instance,
          binding: binding,
          now: current.now,
          privacyEpoch: privacyEpoch,
          scopeVersions: {
            ...current.scopeVersions,
            for (final name in stamp.keys) name: versions[name] ?? 0,
          },
          publicIssues: current.publicIssues,
          confidentialIssues: current.confidentialIssues,
          confirmedShas: current.confirmedShas,
          verifiedProjectAliases: current.verifiedProjectAliases,
          verifiedMergeRequestIds: current.verifiedMergeRequestIds,
        ),
      );
      if (projected == null ||
          projected.cacheClass != entry.cacheClass ||
          projected.issueIdentities.length != entry.issueIdentities.length ||
          !projected.issueIdentities.containsAll(entry.issueIdentities)) {
        await discardInvalidEntry();
        return null;
      }
      final Object value = kind == ReadCacheBodyKind.page
          ? ApiPage<Json>(
              List.unmodifiable(
                ((projected.body as Json)['items'] as List<Object?>).map(
                  objectJson,
                ),
              ),
              next: next,
            )
          : projected.body;
      return CacheDiskEntry(
        value: value,
        fetchedAt: entry.fetchedAt,
        responseBytes: entry.serializedLength,
        issueIdentities: entry.issueIdentities,
      );
    } finally {
      lease.revoke();
    }
  }

  void publishDisk<T extends Object>(
    Uri uri,
    String accept,
    T value,
    DateTime fetchedAt,
    int bytes,
    bool store,
    int ticket,
    Map<String, int> permission,
    Map<String, int> stamp,
  ) {
    final backend = diskBackend;
    final binding = diskBinding;
    final kind = bodyKind<T>();
    if (backend == null || binding == null || kind == null) return;
    final finalKey = key(uri, accept);
    diskRevisions[finalKey] = ticket;
    while (diskRevisions.length > metadataLimit) {
      diskRevisions.remove(diskRevisions.keys.first);
    }
    final context = projectionContext();
    // Required scopes with version zero are still explicit evidence.
    final versionsNow = {...context.scopeVersions, ...stamp};
    final publicationContext = ReadCacheProjectionContext(
      instance: context.instance,
      binding: binding,
      now: context.now,
      privacyEpoch: privacyEpoch,
      scopeVersions: versionsNow,
      publicIssues: context.publicIssues,
      confidentialIssues: context.confidentialIssues,
      confirmedShas: context.confirmedShas,
      verifiedProjectAliases: context.verifiedProjectAliases,
      verifiedMergeRequestIds: context.verifiedMergeRequestIds,
    );
    final raw = value is ApiPage<Json> ? value.items : value;
    final next = value is ApiPage<Json> ? value.next : null;
    ProjectedDiskEntry? projected;
    final lease = _ReadDiskLease(
      () =>
          diskBinding == binding &&
          !api._closed &&
          diskRevisions[finalKey] == ticket &&
          permitted(permission, uri) &&
          stable(stamp) &&
          (projected == null ||
              issuePermissionsAllowed(projected.issueIdentities, permission)) &&
          (!stamp.containsKey('global') || !active(scope(uri))) &&
          (projected?.issueIdentities.every(
                (id) =>
                    confidentialIssues['${id.projectId}:${id.iid}']
                        ?.confidential !=
                    true,
              ) ??
              true) &&
          // Child resources require a still-fresh same-client network parent at
          // commit, even if a queue delay consumed its remaining freshness.
          (!(path(uri).length > 4 && path(uri)[2] == 'issues') ||
              projectionContext().freshPublicIssue(
                ReadCacheIssueIdentity(
                  int.parse(path(uri)[1]),
                  int.parse(path(uri)[3]),
                ),
              )),
    );
    final event = candidate(
      uri,
      accept,
      kind,
      fetchedAt,
      bytes,
      lease,
      stamp,
      store: store,
      next: next,
    );
    final entry = projected = projectReadCacheResponse(
      event,
      raw,
      publicationContext,
    );
    if (entry == null) {
      lease.revoke();
      final durable = readCacheDurableKey(
        binding: binding,
        instance: api.instance,
        uri: uri,
        logicalAccept: accept,
        verifiedProjectAliases: context.verifiedProjectAliases,
      );
      if (durable != null) {
        invalidateDisk(
          DiskInvalidation(
            binding: binding,
            kind: DiskInvalidationKind.permission,
            canonicalKey: durable,
          ),
        );
      }
      return;
    }
    if (!issuePermissionsAllowed(entry.issueIdentities, permission)) {
      lease.revoke();
      return;
    }
    if (lease.isCurrent) backend.accept(event, entry);
  }

  void bind(String key, int value) {
    final prefix = '${api.instance.key}#';
    final id = key.startsWith(prefix)
        ? int.tryParse(key.substring(prefix.length))
        : null;
    final valid =
        !api._closed &&
        !boundOnce &&
        value >= 0 &&
        id != null &&
        id > 0 &&
        key == '$prefix$id' &&
        (verifiedUserId == null || verifiedUserId == id);
    clear();
    boundOnce = true;
    enabled = valid;
    accountKey = valid ? key : null;
    generation = valid ? value : null;
  }

  void signal() {
    final old = changed;
    changed = Completer<void>();
    old.complete();
  }

  void clear({bool revoke = true}) {
    if (revoke) {
      diskRevisions.clear();
      epoch++;
      revocations.clear();
      for (final time in sourceRevocations.values) {
        retainSourceRevocation(time);
      }
      sourceRevocations.clear();
      for (final time in sourcePrivacyRevocations.values) {
        retainSourceWrite(time);
      }
      sourcePrivacyRevocations.clear();
      versions.clear();
      versions['global'] = ++versionSequence;
      for (final time in sourceWriteTimes.values) {
        retainSourceWrite(time);
      }
      sourceWriteTimes.clear();
      confidentialIssues.clear();
      publicIssueMarkerEvicted = false;
    }
    api._readEpoch++;
    entries.clear();
    pending.clear();
    aliases.clear();
    confirmed.clear();
    supersededFresh.clear();
    if (revoke) publicationTickets.clear();
    bytes = 0;
    signal();
  }

  void close() {
    if (closing.isClosed) return;
    final binding = diskBinding;
    if (binding != null) diskBackend?.revoke(binding);
    closing.add(null);
    unawaited(closing.close());
    enabled = false;
    clear();
    for (final admission in [...foregroundQueue, ...backgroundQueue]) {
      admission.ready.complete(false);
    }
    foregroundQueue.clear();
    backgroundQueue.clear();
  }

  List<String> path(Uri uri) => uri.pathSegments
      .skip(api.instance.api(['_']).pathSegments.length - 1)
      .toList(growable: false);

  String? alias(String path) {
    final name = path.toLowerCase();
    final value = aliases[name];
    if (value == null) return null;
    if (!api._readCacheClock().isBefore(value.expiresAt)) {
      aliases.remove(name);
      return null;
    }
    return value.id;
  }

  Uri canonical(Uri uri, {bool resolveAlias = true}) {
    final segments = path(uri);
    if (segments.length >= 2 && segments[0] == 'projects') {
      if (resolveAlias) segments[1] = alias(segments[1]) ?? segments[1];
    }
    final query = <String, String>{...uri.queryParameters};
    if (segments.length == 2 && segments[0] == 'projects') {
      query['license'] = 'true';
    }
    return api.instance.api(segments, query.isEmpty ? null : query);
  }

  String key(Uri uri, String accept) {
    final names = uri.queryParameters.keys.toList()..sort();
    return jsonEncode([
      accountKey,
      generation,
      'GET',
      uri.path,
      [
        for (final name in names) [name, uri.queryParameters[name]],
      ],
      accept,
    ]);
  }

  String scope(Uri uri) {
    final p = path(uri);
    if (p.isEmpty) return 'default';
    if (p.first == 'projects' && p.length >= 2) {
      final id = alias(p[1]) ?? p[1];
      return int.tryParse(id) != null ? 'project:$id' : 'default';
    }
    if (p.first == 'groups' &&
        p.length >= 3 &&
        const {'issues', 'merge_requests'}.contains(p[2])) {
      return 'groupWorkItems';
    }
    if (p.first == 'groups' ||
        p.first == 'projects' ||
        (p.first == 'users' && p.last == 'starred_projects')) {
      return 'projectLists';
    }
    if (const {
          'issues',
          'merge_requests',
          'todos',
          'events',
        }.contains(p.first) ||
        (p.first == 'users' && p.last == 'events')) {
      return 'userLists';
    }
    return 'default';
  }

  bool isConfirmed(String sha) {
    final normalized = sha.toLowerCase();
    if (!_fullSha.hasMatch(normalized) || !confirmed.containsKey(normalized)) {
      return false;
    }
    confirmed.remove(normalized);
    confirmed[normalized] = true;
    return true;
  }

  void confirm(Object? sha) {
    if (sha is! String || !_fullSha.hasMatch(sha.toLowerCase())) return;
    final normalized = sha.toLowerCase();
    confirmed.remove(normalized);
    confirmed[normalized] = true;
    while (confirmed.length > 4096) {
      confirmed.remove(confirmed.keys.first);
    }
  }

  void observe(Uri uri, Json json, {bool learnAlias = true}) {
    api._observeErasedJob(uri, json);
    final p = path(uri);
    if (p.length == 1 && p.first == 'user' && json['id'] is int) {
      verifiedUserId = json['id'] as int;
      if (enabled && accountKey != '${api.instance.key}#$verifiedUserId') {
        enabled = false;
        clear();
      }
    }
    if (learnAlias) observeProjectAlias(uri, json);
    if (p.length >= 4 && p[0] == 'projects' && p[2] == 'repository') {
      if (p[3] == 'branches') {
        final commit = json['commit'];
        if (commit is Map<String, dynamic>) confirm(commit['id']);
      }
      if (p[3] == 'commits' && p.length == 5) confirm(json['id']);
    }
    if (p.length >= 3 && p[0] == 'projects' && p[2] == 'merge_requests') {
      confirm(json['sha']);
      final refs = json['diff_refs'];
      if (refs is Map<String, dynamic>) {
        for (final name in ['base_sha', 'head_sha', 'start_sha']) {
          confirm(refs[name]);
        }
      }
    }
  }

  void observeProjectAlias(Uri uri, Json json) {
    final p = path(uri);
    if (p.length == 2 && p.first == 'projects' && json['id'] is int) {
      final id = '${json['id']}';
      final fullPath = json['path_with_namespace'];
      void remember(String name) {
        aliases.remove(name.toLowerCase());
        aliases[name.toLowerCase()] = (
          id: id,
          expiresAt: api._readCacheClock().add(const Duration(minutes: 30)),
        );
        while (aliases.length > 4096) {
          aliases.remove(aliases.keys.first);
        }
      }

      if (fullPath is String) remember(fullPath);
      if (int.tryParse(p[1]) == null) remember(p[1]);
    }
  }

  void observePrivacy(
    Uri uri,
    Json json, {
    CacheLineage lineage = CacheLineage.network,
    DateTime? fetchedAt,
  }) {
    final p = path(canonical(uri));
    final issueEndpoint =
        p.isNotEmpty &&
        (p.first == 'issues' || (p.length >= 3 && p[2] == 'issues'));
    if (json['confidential'] is! bool) return;
    final project =
        json['project_id'] ??
        (issueEndpoint && p.length >= 3 && p.first == 'projects'
            ? int.tryParse(p[1])
            : null);
    final iid =
        json['iid'] ??
        (issueEndpoint && p.length == 4 ? int.tryParse(p[3]) : null);
    if (project is! int || iid is! int || project <= 0 || iid <= 0) return;
    final identity = '$project:$iid';
    final previous = confidentialIssues[identity];
    final observedAt = fetchedAt ?? api._readCacheClock();
    if (previous != null &&
        (observedAt.isBefore(previous.fetchedAt) ||
            (observedAt.isAtSameMomentAs(previous.fetchedAt) &&
                lineage == CacheLineage.disk &&
                previous.lineage == CacheLineage.network))) {
      return;
    }
    if (lineage == CacheLineage.disk &&
        previous?.confidential == true &&
        json['confidential'] == false) {
      return;
    }
    confidentialIssues.remove(identity);
    confidentialIssues[identity] = (
      confidential: json['confidential'] as bool,
      lineage: lineage,
      fetchedAt: observedAt,
    );
    while (confidentialIssues.length > 4096) {
      final forgotten = confidentialIssues.keys.first;
      if (confidentialIssues.remove(forgotten)?.confidential == false) {
        publicIssueMarkerEvicted = true;
      }
    }
    if (json['confidential'] == true) {
      privacyEpoch++;
      final binding = diskBinding;
      if (binding != null) {
        invalidateDisk(
          DiskInvalidation(
            binding: binding,
            kind: DiskInvalidationKind.privacy,
            issueIdentities: {ReadCacheIssueIdentity(project, iid)},
          ),
        );
      }
    }
    // Once a public marker was forgotten, an unknown confidential issue may
    // be a former public issue. Defer invalidation until that observation.
    if (json['confidential'] != true ||
        !(previous?.confidential == false ||
            (previous == null && publicIssueMarkerEvicted))) {
      return;
    }
    invalidateIssuePrivacy('$project', '$iid');
  }

  void invalidateIssuePrivacy(String project, String iid) {
    // Current authorized responses remain displayable. A known or possible
    // public-to-confidential change retires its subtree and list visibility.
    revoke(
      api.instance.api(['projects', project, 'issues', iid]),
      403,
      privacy: true,
    );
    for (final scope in ['userLists', 'groupWorkItems']) {
      versions[scope] = ++versionSequence;
      sourceWriteTimes[scope] = api._readCacheClock();
    }
    boundMetadata();
    evictWhere(
      (_, scope, _) => scope == 'userLists' || scope == 'groupWorkItems',
    );
  }

  bool observeLoadedPrivacy(
    Uri uri,
    Object value, {
    CacheLineage lineage = CacheLineage.network,
    DateTime? fetchedAt,
    Set<ReadCacheIssueIdentity>? issueIdentities,
  }) {
    return observeRawPrivacy(
      uri,
      value is ApiPage<Json> ? value.items : value,
      lineage: lineage,
      fetchedAt: fetchedAt,
      issueIdentities: issueIdentities,
    );
  }

  /// Scan before projection removes unknown fields, including issue identities
  /// in project lists, related MRs and cross-project links. The projector remains
  /// the sole authority for admitting a complete response to disk.
  bool observeRawPrivacy(
    Uri uri,
    Object root, {
    CacheLineage lineage = CacheLineage.network,
    DateTime? fetchedAt,
    Set<ReadCacheIssueIdentity>? issueIdentities,
  }) {
    var valid = true;
    var nodes = 0;
    final at = fetchedAt ?? api._readCacheClock();
    final p = path(canonical(uri));
    final directIssue =
        root is Json &&
        p.length == 4 &&
        p.first == 'projects' &&
        p[2] == 'issues';
    final issueCollection =
        root is List<Object?> &&
        p.length == 3 &&
        p.first == 'projects' &&
        p[2] == 'issues';
    void walk(Object? value, int depth) {
      if (++nodes > readCacheMaxValueNodes || depth > readCacheMaxDepth) {
        valid = false;
        return;
      }
      if (value is List<Object?>) {
        if (value.length > readCacheMaxArrayLength) {
          valid = false;
          return;
        }
        for (final item in value) {
          walk(item, depth + 1);
        }
      } else if (value is Json) {
        // Only the direct issue or collection rows inherit URI identity.
        // Nested notes and issue child resources are not their parent issue.
        final inferProject =
            (directIssue && depth == 1) || (issueCollection && depth == 2);
        final project =
            value['project_id'] ?? (inferProject ? int.tryParse(p[1]) : null);
        final iid =
            value['iid'] ??
            (directIssue && depth == 1 ? int.tryParse(p[3]) : null);
        final confidential = value['confidential'];
        if (project is int && project > 0 && iid is int && iid > 0) {
          issueIdentities?.add(ReadCacheIssueIdentity(project, iid));
        }
        if (project is int &&
            project > 0 &&
            iid is int &&
            iid > 0 &&
            confidential is bool) {
          final previous = confidentialIssues['$project:$iid'];
          final conflicts =
              lineage == CacheLineage.disk &&
              ((previous != null &&
                      previous.confidential != confidential &&
                      (!at.isAfter(previous.fetchedAt) ||
                          previous.confidential)) ||
                  confidential);
          if (conflicts) {
            valid = false;
            privacyEpoch++;
            invalidateIssuePrivacy('$project', '$iid');
            final binding = diskBinding;
            if (binding != null) {
              invalidateDisk(
                DiskInvalidation(
                  binding: binding,
                  kind: DiskInvalidationKind.privacy,
                  issueIdentities: {ReadCacheIssueIdentity(project, iid)},
                ),
              );
            }
          } else {
            observePrivacy(uri, value, lineage: lineage, fetchedAt: at);
          }
        }
        for (final child in value.values) {
          walk(child, depth + 1);
        }
      }
    }

    walk(root, 1);
    return valid;
  }

  _ReadClass? classify(Uri uri, {required bool page}) {
    final p = path(uri), q = uri.queryParameters;
    // Only project detail can resolve a full path into a cacheable numeric id.
    if (p.length > 2 && p.first == 'projects' && int.tryParse(p[1]) == null) {
      return null;
    }
    if (q.keys.any(paginationKeys.contains)) return null;
    if (q.containsKey('search') || p.contains('search')) {
      return _ReadClass.volatile;
    }
    if (p.isEmpty) return null;
    if (const {'todos', 'events'}.contains(p.first) ||
        (p.first == 'users' && p.last == 'events')) {
      return _ReadClass.volatile;
    }
    if (const {'issues', 'merge_requests'}.contains(p.first)) {
      return page ? _ReadClass.list : null;
    }
    if (p.first == 'groups') {
      if (p.length <= 2) return page ? _ReadClass.list : _ReadClass.projectMeta;
      if (const {
        'projects',
        'subgroups',
        'descendant_groups',
        'issues',
        'merge_requests',
      }.contains(p[2])) {
        return page ? _ReadClass.list : null;
      }
    }
    if (p.first == 'users' && p.last == 'starred_projects') {
      return _ReadClass.list;
    }
    if (p.first != 'projects') return null;
    if (p.length == 1) return page ? _ReadClass.list : null;
    if (p.length == 2) return page ? null : _ReadClass.projectMeta;
    if (!page &&
        p.length == 6 &&
        p[2] == 'merge_requests' &&
        p[4] == 'versions' &&
        int.tryParse(p[5]) != null) {
      return _ReadClass.pinned;
    }
    if (p[2] == 'repository') {
      if (p.length < 4) return null;
      if (const {'branches', 'tags'}.contains(p[3])) return _ReadClass.ref;
      if (const {'tree', 'files'}.contains(p[3])) {
        return isConfirmed(q['ref'] ?? '') ? _ReadClass.pinned : null;
      }
      if (p[3] == 'commits') return page ? _ReadClass.list : _ReadClass.detail;
      return null;
    }
    if (p.any(
      const {
        'notes',
        'discussions',
        'award_emoji',
        'approvals',
        'related_merge_requests',
        'links',
        'versions',
      }.contains,
    )) {
      return _ReadClass.thread;
    }
    if (const {
      'issues',
      'merge_requests',
      'pipelines',
      'jobs',
    }.contains(p[2])) {
      return p.length == 3 || page ? _ReadClass.list : _ReadClass.detail;
    }
    if (const {
      'starrers',
      'forks',
      'members',
      'labels',
      'milestones',
      'releases',
    }.contains(p[2])) {
      return page ? _ReadClass.list : _ReadClass.detail;
    }
    return null;
  }

  Duration freshness(_ReadClass policy) => switch (policy) {
    _ReadClass.projectMeta => const Duration(minutes: 5),
    _ReadClass.ref ||
    _ReadClass.list ||
    _ReadClass.volatile => const Duration(seconds: 60),
    _ReadClass.detail || _ReadClass.thread => const Duration(seconds: 30),
    _ReadClass.pinned => const Duration(days: 7),
  };
  Duration retention(_ReadClass policy) => switch (policy) {
    _ReadClass.projectMeta => const Duration(minutes: 30),
    _ReadClass.volatile => const Duration(seconds: 60),
    _ReadClass.pinned => const Duration(days: 7),
    _ => const Duration(minutes: 10),
  };

  Map<String, int> snapshot(String scope, bool pinned) => pinned
      ? const {}
      : {'global': versions['global'] ?? 0, scope: versions[scope] ?? 0};
  bool stable(Map<String, int> snapshot) => snapshot.entries.every(
    (entry) => (versions[entry.key] ?? 0) == entry.value,
  );
  bool active(String scope) =>
      (writes['global'] ?? 0) > 0 || (writes[scope] ?? 0) > 0;
  String requestRevocationKey(Uri uri) => 'request:${key(canonical(uri), '*')}';
  Map<String, int> permissions(Uri uri) {
    final p = path(uri);
    return {
      'account': epoch,
      'sequence': revocationSequence,
      requestRevocationKey(uri): revocations[requestRevocationKey(uri)] ?? 0,
      for (var i = 1; i <= p.length; i++)
        jsonEncode(p.take(i).toList()):
            revocations[jsonEncode(p.take(i).toList())] ?? 0,
    };
  }

  bool permitted(Map<String, int> stamp, Uri uri) {
    if (stamp['account'] != epoch ||
        (stamp['sequence'] ?? 0) < revocationFloor) {
      return false;
    }
    final current = permissions(canonical(uri));
    return current.entries
        .where((e) => e.key != 'account' && e.key != 'sequence')
        .every((e) => e.value <= (stamp['sequence'] ?? 0));
  }

  bool issuePermissionsAllowed(
    Set<ReadCacheIssueIdentity> identities,
    Map<String, int> stamp, {
    DateTime? fetchedAt,
  }) {
    if (stamp['account'] != epoch ||
        (stamp['sequence'] ?? 0) < revocationFloor) {
      return false;
    }
    for (final id in identities) {
      final identity = jsonEncode([
        'projects',
        '${id.projectId}',
        'issues',
        '${id.iid}',
      ]);
      final revokedAt = sourceRevocations[identity];
      if (revokedAt != null &&
          (revocations[identity] ?? 0) > (stamp['sequence'] ?? 0)) {
        return false;
      }
      if (fetchedAt != null &&
          revokedAt != null &&
          !fetchedAt.isAfter(revokedAt)) {
        return false;
      }
    }
    return true;
  }

  bool sourceAllowed(Uri uri, DateTime fetchedAt, bool pinned) {
    final account = sourceAccountRevokedAt;
    if (account != null && !fetchedAt.isAfter(account)) return false;
    final requestRevoked = sourceRevocations[requestRevocationKey(uri)];
    if (requestRevoked != null && !fetchedAt.isAfter(requestRevoked)) {
      return false;
    }
    final p = path(canonical(uri));
    for (var i = 1; i <= p.length; i++) {
      final prefix = jsonEncode(p.take(i).toList());
      final revoked = sourceRevocations[prefix];
      if (revoked != null && !fetchedAt.isAfter(revoked)) return false;
      final privacy = sourcePrivacyRevocations[prefix];
      if (privacy != null && !fetchedAt.isAfter(privacy)) return false;
    }
    if (!pinned) {
      final compacted = sourceMutableWrittenAt;
      if (compacted != null && !fetchedAt.isAfter(compacted)) return false;
      for (final name in ['global', scope(uri)]) {
        final written = sourceWriteTimes[name];
        if (written != null && !fetchedAt.isAfter(written)) return false;
      }
    }
    return true;
  }

  Future<bool> admit(bool isBackground) async {
    if (api._closed) return false;
    if (isBackground ? background < 4 : foreground < 16) {
      if (isBackground) {
        background++;
      } else {
        foreground++;
      }
      return true;
    }
    final admission = _ReadAdmission();
    final queue = isBackground ? backgroundQueue : foregroundQueue;
    if (isBackground && queue.length == 32) {
      queue.removeAt(0).ready.complete(false);
    }
    queue.add(admission);
    return admission.ready.future;
  }

  void release(bool isBackground) {
    final queue = isBackground ? backgroundQueue : foregroundQueue;
    if (queue.isNotEmpty && !api._closed) {
      queue.removeAt(0).ready.complete(true);
    } else if (isBackground) {
      background--;
    } else {
      foreground--;
    }
  }

  Future<bool> waitForWrites(String scope) async {
    final deadline = api._readCacheClock().add(const Duration(seconds: 30));
    while (active(scope)) {
      final remaining = deadline.difference(api._readCacheClock());
      if (remaining <= Duration.zero) return false;
      try {
        await changed.future.timeout(remaining);
      } on TimeoutException {
        return false;
      }
      if (api._closed) throw const ApiFailure(FailureKind.cancelled);
    }
    return true;
  }

  Future<void> waitForQuiet() async {
    while (lastWriteStart != null) {
      final remaining = lastWriteStart!
          .add(const Duration(seconds: 1))
          .difference(api._readCacheClock());
      if (remaining <= Duration.zero) return;
      try {
        await changed.future.timeout(remaining);
      } on TimeoutException {
        return;
      }
      if (api._closed) throw const ApiFailure(FailureKind.cancelled);
    }
  }

  int claimPublication(String cacheKey, Uri uri, String accept) {
    final ticket = ++publicationSequence;
    activePublications.add(ticket);
    rememberPublication(cacheKey, ticket);
    rememberPublication(pathPublicationKey(uri, accept), ticket);
    for (final name in {cacheKey, pathPublicationKey(uri, accept)}) {
      diskRevisions.remove(name);
      diskRevisions[name] = ticket;
    }
    while (diskRevisions.length > metadataLimit) {
      diskRevisions.remove(diskRevisions.keys.first);
    }
    return ticket;
  }

  String pathPublicationKey(Uri uri, String accept, {Object? value}) {
    final p = path(uri);
    if (p.length == 2 && p.first == 'projects') {
      final fullPath = value is Json ? value['path_with_namespace'] : null;
      p[1] = (fullPath is String ? fullPath : p[1]).toLowerCase();
      uri = api.instance.api(p, uri.queryParameters);
    }
    return key(uri, accept);
  }

  void rememberPublication(String cacheKey, int ticket) {
    publicationTickets.remove(cacheKey);
    publicationTickets[cacheKey] = ticket;
    while (publicationTickets.length > 4096) {
      final removed = publicationTickets.remove(publicationTickets.keys.first)!;
      if (removed > publicationFloor) publicationFloor = removed;
    }
  }

  void finishPublication(int ticket) {
    activePublications.remove(ticket);
    if (activePublications.isEmpty) {
      publicationTickets.clear();
    } else {
      // A completed newer ticket still fences older unresolved aliases.
      final oldest = activePublications.first;
      publicationTickets.removeWhere((_, owner) => owner < oldest);
    }
  }

  Uri publicationUri(Uri uri, Object? value) {
    final p = path(uri);
    if (p.length == 2 &&
        p.first == 'projects' &&
        value is Json &&
        value['id'] is int) {
      return api.instance.api([
        'projects',
        '${value['id']}',
      ], uri.queryParameters);
    }
    return canonical(uri);
  }

  bool ownsPublication(
    String initialKey,
    Uri uri,
    String accept,
    int ticket, {
    Object? value,
  }) =>
      ticket > publicationFloor &&
      publicationTickets[initialKey] == ticket &&
      publicationTickets[pathPublicationKey(uri, accept)] == ticket &&
      (publicationTickets[key(publicationUri(uri, value), accept)] ?? ticket) <=
          ticket &&
      (publicationTickets[pathPublicationKey(uri, accept, value: value)] ??
              ticket) <=
          ticket;

  Future<CachedRead<T>> read<T extends Object>(
    Uri uri,
    _ReadClass? policy,
    Future<_LoadedRead<T>> Function() load, {
    bool fresh = false,
    Duration? maxAge,
    bool allowDisk = true,
    bool background = false,
    String accept = 'application/json',
    void Function(T)? validate,
    int entryLimit = 1024 * 1024,
  }) async {
    if (api._closed) throw const ApiFailure(FailureKind.cancelled);
    final mayStart = Zone.current[#cachedReadMayStart] as bool Function()?;
    final quiet = Zone.current[#cachedReadWaitForQuiet] == true;
    if (!api.instance.allowsApi(uri)) {
      throw const ApiFailure(FailureKind.unsupported);
    }
    final canCache = enabled && policy != null;
    if (!canCache) {
      if (mayStart?.call() == false) return CachedRead<T>.dropped();
      final loaded = await load();
      final value = _freezeCached(loaded.value) as T;
      observeLoadedPrivacy(uri, value);
      await settleDiskSafety();
      if (api._closed) throw const ApiFailure(FailureKind.cancelled);
      validate?.call(value);
      return CachedRead<T>(
        value: value,
        fetchedAt: api._readCacheClock(),
        lineage: CacheLineage.network,
      );
    }
    var cacheKey = key(publicationUri(uri, null), accept);
    final pinned = policy == _ReadClass.pinned;
    var readScope = scope(uri);
    var permission = permissions(uri);
    var lookupVersion = snapshot(readScope, pinned);
    final projectPath = path(uri);
    final projectDetail =
        projectPath.length == 2 && projectPath.first == 'projects';
    final requestedProjectId = projectDetail
        ? int.tryParse(projectPath[1])
        : null;
    var identityMismatch = false;
    bool servesProjectRequest(Object value) {
      if (!projectDetail) return true;
      final matches =
          value is Json &&
          (requestedProjectId != null
              ? value['id'] == requestedProjectId
              : value['path_with_namespace'] is String &&
                    (value['path_with_namespace'] as String).toLowerCase() ==
                        projectPath[1].toLowerCase());
      if (!matches) {
        aliases.remove(projectPath[1].toLowerCase());
        readScope = scope(uri);
        lookupVersion = snapshot(readScope, pinned);
        cacheKey = key(publicationUri(uri, null), accept);
        // A rejected identity falls through directly to the caller's URI.
        identityMismatch = true;
      }
      return matches;
    }

    String pendingKey() => projectDetail && requestedProjectId == null
        ? key(uri, accept)
        : cacheKey;

    bool usable(_ReadEntry entry) {
      final age = api._readCacheClock().difference(entry.fetchedAt);
      return (allowDisk || entry.lineage != CacheLineage.disk) &&
          age >= Duration.zero &&
          age <
              (entry.lineage == CacheLineage.disk
                  ? const Duration(days: 7)
                  : retention(entry.policy)) &&
          (maxAge == null || age < maxAge);
    }

    Future<CachedRead<T>> result(_ReadEntry entry) async {
      final value = entry.value as T;
      validate?.call(value);
      if (value is Json && api._observeErasedJob(entry.uri, value)) {
        await settleDiskSafety();
        if (api._closed ||
            !permitted(permission, uri) ||
            !permitted(permission, entry.uri)) {
          throw const ApiFailure(FailureKind.cancelled);
        }
      }
      return CachedRead(
        value: value,
        fetchedAt: entry.fetchedAt,
        lineage: entry.lineage == CacheLineage.disk
            ? CacheLineage.disk
            : CacheLineage.memory,
        stale:
            !pinned &&
            (entry.lineage == CacheLineage.disk ||
                api._readCacheClock().difference(entry.fetchedAt) >=
                    freshness(entry.policy)),
      );
    }

    if (canCache && !fresh && (pinned || !active(readScope))) {
      final cached = entries.remove(cacheKey);
      if (cached != null) {
        bytes -= cached.cost;
        final age = api._readCacheClock().difference(cached.fetchedAt);
        if (age >= Duration.zero &&
            age <
                (cached.lineage == CacheLineage.disk
                    ? const Duration(days: 7)
                    : retention(cached.policy))) {
          entries[cacheKey] = cached;
          bytes += cached.cost;
          if (usable(cached) && servesProjectRequest(cached.value)) {
            return result(cached);
          }
        }
      }
      final inFlight = pending[pendingKey()];
      if (!identityMismatch &&
          inFlight != null &&
          (background || !inFlight.background)) {
        final shared = await inFlight.future as CachedRead<T>;
        // A disk-forbidden caller never joins a disk hydration result.
        if ((allowDisk || shared.lineage != CacheLineage.disk) &&
            (shared.dropped || servesProjectRequest(shared.value))) {
          return shared;
        }
      }
      if (!identityMismatch &&
          allowDisk &&
          (diskBackend != null || api._readCacheSource != null)) {
        final hydrationTicket = claimPublication(cacheKey, uri, accept);
        var rejectedPrivacy = false;
        try {
          final cancelled = Completer<CacheDiskEntry?>();
          final subscription = closing.stream.listen((_) {
            cancelled.completeError(const ApiFailure(FailureKind.cancelled));
          });
          final CacheDiskEntry? hydrated;
          try {
            hydrated = await Future.any<CacheDiskEntry?>([
              lookupDisk<T>(
                uri,
                accept,
                permission,
                lookupVersion,
                rejectedPrivacy: () {
                  rejectedPrivacy = true;
                },
                canDiscard: () =>
                    ownsPublication(cacheKey, uri, accept, hydrationTicket),
              ),
              cancelled.future,
            ]);
          } on Object catch (error) {
            throw safeFailure(error);
          } finally {
            await subscription.cancel();
          }
          // A privacy rejection retires the old source. The replacement is a
          // new network read under the resulting fence, never the rejected body.
          if (rejectedPrivacy &&
              permission['account'] == epoch &&
              !api._closed) {
            permission = permissions(uri);
            lookupVersion = snapshot(readScope, pinned);
          }
          final ownsHydration = ownsPublication(
            cacheKey,
            uri,
            accept,
            hydrationTicket,
            value: hydrated?.value,
          );
          if (api._closed ||
              !permitted(permission, uri) ||
              (hydrated != null &&
                  !permitted(
                    permission,
                    publicationUri(uri, hydrated.value),
                  ))) {
            throw const ApiFailure(FailureKind.cancelled);
          }
          final newer = entries[cacheKey];
          if (!ownsHydration &&
              newer != null &&
              usable(newer) &&
              servesProjectRequest(newer.value)) {
            return await result(newer);
          }
          final servesHydrated =
              hydrated == null || servesProjectRequest(hydrated.value);
          if (!servesHydrated && ownsHydration && permitted(permission, uri)) {
            discardDiskKey(uri, accept);
            await settleDiskSafety();
            if (api._closed) throw const ApiFailure(FailureKind.cancelled);
          }
          if (!identityMismatch &&
              ownsHydration &&
              hydrated != null &&
              hydrated.value is T &&
              hydrated.responseBytes >= 0 &&
              hydrated.responseBytes <= entryLimit &&
              servesHydrated) {
            final value = _freezeCached(hydrated.value) as T;
            var privacyAllowed = observeRawPrivacy(
              uri,
              value is ApiPage<Json> ? value.items : value,
              lineage: CacheLineage.disk,
              fetchedAt: hydrated.fetchedAt,
            );
            await settleDiskSafety();
            if (api._closed) throw const ApiFailure(FailureKind.cancelled);
            privacyAllowed =
                observeRawPrivacy(
                  uri,
                  value is ApiPage<Json> ? value.items : value,
                  lineage: CacheLineage.disk,
                  fetchedAt: hydrated.fetchedAt,
                ) &&
                privacyAllowed;
            final issuePermissionAllowed = issuePermissionsAllowed(
              hydrated.issueIdentities,
              permission,
              fetchedAt: hydrated.fetchedAt,
            );
            if (!privacyAllowed || !issuePermissionAllowed) {
              if (!issuePermissionAllowed &&
                  ownsPublication(cacheKey, uri, accept, hydrationTicket) &&
                  permitted(permission, uri)) {
                discardDiskKey(uri, accept);
              }
              await settleDiskSafety();
              if (api._closed) throw const ApiFailure(FailureKind.cancelled);
            }
            if ((!privacyAllowed || !issuePermissionAllowed) &&
                permission['account'] == epoch &&
                !api._closed) {
              permission = permissions(uri);
              lookupVersion = snapshot(readScope, pinned);
            }
            // Only project aliases are learned from disk; SHA confirmation
            // remains restricted to trusted network response types.
            final p = path(uri);
            final canonicalUri = publicationUri(uri, value);
            final entry = _ReadEntry(
              canonicalUri,
              value,
              hydrated.fetchedAt,
              CacheLineage.disk,
              policy,
              scope(canonicalUri),
              hydrated.responseBytes * 4,
            );
            if (privacyAllowed &&
                issuePermissionAllowed &&
                permitted(permission, uri) &&
                permitted(permission, canonicalUri) &&
                ownsPublication(
                  cacheKey,
                  uri,
                  accept,
                  hydrationTicket,
                  value: value,
                ) &&
                usable(entry) &&
                sourceAllowed(canonicalUri, hydrated.fetchedAt, pinned) &&
                stable(lookupVersion) &&
                (pinned || !active(readScope))) {
              validate?.call(value);
              observeLoadedPrivacy(
                uri,
                value,
                lineage: CacheLineage.disk,
                fetchedAt: hydrated.fetchedAt,
              );
              if (value is Json && p.length == 2 && p.first == 'projects') {
                observeProjectAlias(uri, value);
              }
              rememberPublication(key(canonicalUri, accept), hydrationTicket);
              rememberPublication(
                pathPublicationKey(uri, accept, value: value),
                hydrationTicket,
              );
              store(key(canonicalUri, accept), entry);
              return await result(entry);
            }
          }
        } finally {
          finishPublication(hydrationTicket);
        }
      }
    }
    final inFlight = pending[pendingKey()];
    if (canCache &&
        !fresh &&
        !identityMismatch &&
        inFlight != null &&
        (background || !inFlight.background)) {
      final shared = await inFlight.future as CachedRead<T>;
      if ((allowDisk || shared.lineage != CacheLineage.disk) &&
          (shared.dropped || servesProjectRequest(shared.value))) {
        return shared;
      }
    }
    final ticket = canCache ? claimPublication(cacheKey, uri, accept) : 0;
    final networkPendingKey = pendingKey();
    late final Future<CachedRead<T>> operation;
    operation = () async {
      var admitted = false;
      try {
        if (api._closed || !permitted(permission, uri)) {
          throw const ApiFailure(FailureKind.cancelled);
        }
        if (fresh &&
            !pinned &&
            (quiet || (supersededFresh[cacheKey] ?? 0) >= 2)) {
          await waitForQuiet();
        }
        for (var attempt = 0; ; attempt++) {
          var waited = !canCache || pinned || await waitForWrites(readScope);
          admitted = await admit(background);
          if (!admitted) {
            if (api._closed) throw const ApiFailure(FailureKind.cancelled);
            return CachedRead<T>.dropped();
          }
          if (mayStart?.call() == false) return CachedRead<T>.dropped();
          // A write can start while this read is queued for a send slot.
          while (canCache && !pinned && waited && active(readScope)) {
            release(background);
            admitted = false;
            waited = await waitForWrites(readScope);
            admitted = await admit(background);
            if (!admitted) {
              if (api._closed) throw const ApiFailure(FailureKind.cancelled);
              return CachedRead<T>.dropped();
            }
            if (mayStart?.call() == false) return CachedRead<T>.dropped();
          }
          if (api._closed || !permitted(permission, uri)) {
            throw const ApiFailure(FailureKind.cancelled);
          }
          var start = snapshot(readScope, !canCache || pinned);
          final versionsAtSend = versionSequence;
          if (mayStart?.call() == false) return CachedRead<T>.dropped();
          final loaded = await load();
          if (api._closed ||
              !permitted(permission, uri) ||
              !permitted(permission, publicationUri(uri, loaded.value))) {
            throw const ApiFailure(FailureKind.cancelled);
          }
          final fetchedAt = api._readCacheClock();
          // A full-path project detail reveals its numeric scope only after
          // the network response. Retain both scopes and reject any write that
          // changed the resolved project while that request was in flight.
          final resolvedScope = scope(publicationUri(uri, loaded.value));
          if (!pinned && resolvedScope != readScope) {
            final resolvedVersion = versions[resolvedScope] ?? 0;
            start = {
              ...start,
              resolvedScope: resolvedVersion <= versionsAtSend
                  ? resolvedVersion
                  : -1,
            };
            readScope = resolvedScope;
          }
          final wasCurrent = stable(start) && (pinned || !active(readScope));
          final beforePrivacy = privacyEpoch;
          final observedIssues = <ReadCacheIssueIdentity>{};
          final privacyAllowed = observeLoadedPrivacy(
            uri,
            loaded.value,
            fetchedAt: fetchedAt,
            issueIdentities: observedIssues,
          );
          if (wasCurrent && privacyEpoch != beforePrivacy) {
            start = snapshot(readScope, !canCache || pinned);
          }
          await settleDiskSafety();
          if (api._closed) throw const ApiFailure(FailureKind.cancelled);
          final consistent = stable(start) && (pinned || !active(readScope));
          if (canCache && !pinned && !consistent && waited && attempt == 0) {
            release(background);
            admitted = false;
            continue;
          }
          final invalid = canCache && !pinned && !consistent && waited;
          final timedOut = !waited;
          if (invalid) {
            supersededFresh[cacheKey] =
                (supersededFresh[cacheKey] ?? 0) + (fresh ? 1 : 0);
            boundMetadata();
          } else if (!timedOut) {
            supersededFresh.remove(cacheKey);
          }
          final value = _freezeCached(loaded.value) as T;
          validate?.call(value);
          if (canCache &&
              !invalid &&
              !timedOut &&
              permitted(permission, uri) &&
              permitted(permission, publicationUri(uri, value)) &&
              ownsPublication(cacheKey, uri, accept, ticket, value: value)) {
            final canonicalUri = publicationUri(uri, value);
            if (value is Json) observeProjectAlias(uri, value);
            final finalKey = key(canonicalUri, accept);
            rememberPublication(finalKey, ticket);
            rememberPublication(
              pathPublicationKey(uri, accept, value: value),
              ticket,
            );
            // Memory admission cannot depend on disk projection succeeding.
            final issuePermissionAllowed =
                privacyAllowed &&
                issuePermissionsAllowed(observedIssues, permission);
            if (issuePermissionAllowed) {
              publishDisk<T>(
                canonicalUri,
                accept,
                value,
                fetchedAt,
                loaded.bytes,
                loaded.store && loaded.bytes <= entryLimit,
                ticket,
                permission,
                start,
              );
            }
            if (!issuePermissionAllowed ||
                !loaded.store ||
                loaded.bytes > entryLimit) {
              final removed = entries.remove(finalKey);
              if (removed != null) bytes -= removed.cost;
            } else {
              store(
                finalKey,
                _ReadEntry(
                  canonicalUri,
                  value,
                  fetchedAt,
                  CacheLineage.network,
                  policy,
                  scope(canonicalUri),
                  loaded.bytes * 4,
                ),
              );
            }
          }
          return CachedRead<T>(
            value: value,
            fetchedAt: fetchedAt,
            lineage: CacheLineage.network,
            stale: timedOut,
            superseded: invalid,
          );
        }
      } finally {
        finishPublication(ticket);
        if (admitted) release(background);
        if (identical(pending[networkPendingKey]?.future, operation)) {
          pending.remove(networkPendingKey);
        }
      }
    }();
    if (canCache && !fresh) {
      pending[networkPendingKey] = _PendingRead(
        uri,
        readScope,
        pinned,
        background,
        operation,
      );
    }
    return operation;
  }

  void store(String key, _ReadEntry entry) {
    final previous = entries.remove(key);
    if (previous != null) bytes -= previous.cost;
    entries[key] = entry;
    bytes += entry.cost;
    while (entries.length > GitLabApi.maxCachedReads ||
        bytes > GitLabApi.maxCachedReadBytes) {
      bytes -= entries.remove(entries.keys.first)!.cost;
    }
  }

  Set<String> affected(
    Uri uri,
    String method,
    Object? data, {
    bool graphMutation = false,
  }) {
    if (graphMutation || quickAction(data)) return {'global'};
    final p = path(uri);
    if (p.isEmpty) return {'global'};
    if (p.first == 'projects') {
      if (p.length == 1) return {'projectLists', 'default'};
      final id = alias(p[1]) ?? p[1];
      if (int.tryParse(id) == null) return {'global'};
      if (p.length >= 5 && p[2] == 'merge_requests' && p[4] == 'merge') {
        return {'global'};
      }
      final scopes = {'project:$id', 'default'};
      if (p.length == 2 || const {'fork', 'star', 'unstar'}.contains(p[2])) {
        scopes.add('projectLists');
        if (data is Map && data['forked_from_project'] is Map) {
          final from = data['forked_from_project'] as Map;
          if (from['id'] is int) scopes.add('project:${from['id']}');
        }
      } else if (const {'issues', 'merge_requests'}.contains(p[2])) {
        scopes.addAll({'userLists', 'groupWorkItems'});
      }
      return scopes;
    }
    if (p.first == 'todos') return {'userLists', 'default'};
    return {'global'};
  }

  bool quickAction(Object? body) {
    if (body is! Map) return false;
    return const ['body', 'description', 'note', 'title'].any((name) {
      final value = body[name];
      return value is String && RegExp(r'^/', multiLine: true).hasMatch(value);
    });
  }

  void write(Set<String> scopes, {required bool starting}) {
    api._readEpoch++;
    // Saturation degrades only mutable scopes to the existing global barrier.
    // The same set is held by _send until its matching completion.
    if (starting &&
        writes.length + scopes.where((s) => !writes.containsKey(s)).length >
            metadataLimit - 1) {
      scopes
        ..clear()
        ..add('global');
    }
    for (final scope in scopes) {
      versions[scope] = ++versionSequence;
      sourceWriteTimes[scope] = api._readCacheClock();
      final count = (writes[scope] ?? 0) + (starting ? 1 : -1);
      if (count == 0) {
        writes.remove(scope);
      } else {
        writes[scope] = count;
      }
    }
    boundMetadata();
    if (starting) lastWriteStart = api._readCacheClock();
    evictWhere(
      (uri, scope, pinned) =>
          !pinned && (scopes.contains('global') || scopes.contains(scope)),
    );
    if (scopes.contains('global')) {
      aliases.clear();
    } else {
      aliases.removeWhere((_, value) => scopes.contains('project:${value.id}'));
    }
    signal();
  }

  void revoke(
    Uri uri,
    int status, {
    bool terminal401 = true,
    bool privacy = false,
  }) {
    if (status == 401) {
      final binding = diskBinding;
      if (terminal401 && binding != null) {
        invalidateDisk(
          DiskInvalidation(
            binding: binding,
            kind: DiskInvalidationKind.account,
          ),
        );
      }
      if (terminal401) sourceAccountRevokedAt = api._readCacheClock();
      clear(revoke: terminal401);
      return;
    }
    if (status != 403 && status != 404) return;
    if (!api.instance.allowsApi(uri)) {
      if (!privacy) api._readEpoch++;
      return;
    }
    var p = path(canonical(uri));
    final binding = diskBinding;
    final collection =
        p.length == 1 ||
        (p.length == 3 &&
            p.first == 'groups' &&
            const {
              'projects',
              'subgroups',
              'descendant_groups',
              'issues',
              'merge_requests',
            }.contains(p[2])) ||
        (p.length == 3 &&
            p.first == 'projects' &&
            const {
              'issues',
              'merge_requests',
              'pipelines',
              'jobs',
              'labels',
              'milestones',
              'starrers',
              'forks',
              'members',
              'releases',
            }.contains(p[2]));
    if (binding != null && !privacy) {
      final context = projectionContext();
      invalidateDisk(
        DiskInvalidation(
          binding: binding,
          kind: DiskInvalidationKind.permission,
          path: collection ? null : canonical(uri),
          canonicalKey: collection
              ? readCacheDurableKey(
                  binding: binding,
                  instance: api.instance,
                  uri: canonical(uri),
                  logicalAccept: 'application/json',
                  verifiedProjectAliases: context.verifiedProjectAliases,
                )
              : null,
          issueIdentities:
              p.length == 4 &&
                  p.first == 'projects' &&
                  p[2] == 'issues' &&
                  int.tryParse(p[1]) != null &&
                  int.tryParse(p[3]) != null
              ? {ReadCacheIssueIdentity(int.parse(p[1]), int.parse(p[3]))}
              : const {},
        ),
      );
    }
    // V2: collection failures intentionally revoke only that query in memory.
    // Only a project detail revokes its whole project.
    if (collection) {
      final request = requestRevocationKey(uri);
      if (!privacy) api._readEpoch++;
      rememberRevocation(request, privacy: privacy);
      boundMetadata();
      evictWhere((target, _, _) => requestRevocationKey(target) == request);
      signal();
      return;
    }
    if (p.length == 4 &&
        p[0] == 'projects' &&
        const {'issues', 'merge_requests'}.contains(p[2])) {
      p = p.take(4).toList();
    }
    if (!privacy) api._readEpoch++;
    final revoked = jsonEncode(p);
    rememberRevocation(revoked, privacy: privacy);
    boundMetadata();
    bool matches(Uri uri) {
      final target = path(canonical(uri));
      return target.length >= p.length &&
          List.generate(p.length, (i) => target[i] == p[i]).every((v) => v);
    }

    evictWhere((uri, _, _) => matches(uri));
    if (p.length == 2 && p.first == 'projects') {
      aliases.removeWhere((_, value) => value.id == p[1]);
    }
    signal();
  }

  void rememberRevocation(String key, {required bool privacy}) {
    revocations.remove(key);
    revocations[key] = ++revocationSequence;
    // Privacy changes must never become account-wide pinned-data fences.
    final source = privacy ? sourcePrivacyRevocations : sourceRevocations;
    source.remove(key);
    source[key] = api._readCacheClock();
  }

  void retainSourceWrite(DateTime time) {
    if (sourceMutableWrittenAt == null ||
        time.isAfter(sourceMutableWrittenAt!)) {
      sourceMutableWrittenAt = time;
    }
  }

  void retainSourceRevocation(DateTime time) {
    if (sourceAccountRevokedAt == null ||
        time.isAfter(sourceAccountRevokedAt!)) {
      sourceAccountRevokedAt = time;
    }
  }

  void boundMetadata() {
    // Compact to monotonic fences instead of forgetting an invalidation. Only
    // mutable snapshots use the global version and write-time floors.
    if (versions.length > metadataLimit) {
      versions.clear();
      versions['global'] = ++versionSequence;
    }
    if (sourceWriteTimes.length > metadataLimit) {
      for (final time in sourceWriteTimes.values) {
        retainSourceWrite(time);
      }
      sourceWriteTimes.clear();
    }
    while (revocations.length > metadataLimit) {
      final removed = revocations.remove(revocations.keys.first)!;
      if (removed > revocationFloor) revocationFloor = removed;
    }
    while (sourceRevocations.length > metadataLimit) {
      retainSourceRevocation(
        sourceRevocations.remove(sourceRevocations.keys.first)!,
      );
    }
    while (sourcePrivacyRevocations.length > metadataLimit) {
      retainSourceWrite(
        sourcePrivacyRevocations.remove(sourcePrivacyRevocations.keys.first)!,
      );
    }
    while (supersededFresh.length > metadataLimit) {
      supersededFresh.remove(supersededFresh.keys.first);
    }
  }

  void evictWhere(bool Function(Uri, String, bool) test) {
    entries.removeWhere((_, entry) {
      if (!test(entry.uri, entry.scope, entry.policy == _ReadClass.pinned)) {
        return false;
      }
      bytes -= entry.cost;
      return true;
    });
    pending.removeWhere(
      (_, request) => test(request.uri, request.scope, request.pinned),
    );
  }
}

final _fullSha = RegExp(r'^([0-9a-f]{40}|[0-9a-f]{64})$');

Object _freezeCached(Object value) {
  if (value is Json) return _freezeJson(value);
  if (value is ApiPage<Json>) {
    return ApiPage<Json>(
      List.unmodifiable(value.items.map(_freezeJson)),
      next: value.next,
    );
  }
  return value;
}
