part of 'gitlab_api.dart';

enum CacheLineage { network, memory, disk }

/// A dropped admission has no value. Superseded values must not be published.
final class CachedRead<T> {
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
  });
  final Object value;
  final DateTime fetchedAt;
  final int responseBytes;
}

typedef ReadCacheSource =
    Future<CacheDiskEntry?> Function(Uri uri, String accept);

enum _ReadClass { projectMeta, ref, pinned, list, detail, thread, volatile }

extension CachedReadApi on GitLabApi {
  /// Called once, after /user verification and the session generation advances.
  void bindReadCache(String accountKey, int generation) =>
      _cache.bind(accountKey, generation);
  bool get isReadCacheBound => _cache.enabled;
  String? get readCacheAccountKey => _cache.accountKey;
  int? get readCacheGeneration => _cache.generation;

  Future<CachedRead<Json>> cachedRecord(
    List<String> path, {
    Map<String, String> query = const {},
    bool fresh = false,
    Duration? maxAge,
    bool allowDisk = true,
    bool background = false,
  }) {
    final uri = _cache.canonical(instance.api(path, query));
    final policy = _cache.classify(uri, page: false);
    return _cache.read<Json>(
      uri,
      policy,
      () async {
        final response = await _read(uri);
        try {
          final value = objectJson(jsonDecode(utf8.decode(response.bytes)));
          _cache.observe(uri, value);
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
  const _PendingRead(this.uri, this.scope, this.pinned, this.future);
  final Uri uri;
  final String scope;
  final bool pinned;
  final Future<Object> future;
}

final class _ReadAdmission {
  final ready = Completer<bool>();
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
  final aliases = <String, String>{};
  final confirmed = <String, bool>{};
  final confidentialIssues = <String, bool>{};
  final supersededFresh = <String, int>{};
  final publicationTickets = <String, Object>{};
  final sourceWriteTimes = <String, DateTime>{};
  final sourceRevocations = <String, DateTime>{};
  DateTime? sourceAccountRevokedAt;
  int revocationSequence = 0;
  final foregroundQueue = <_ReadAdmission>[];
  final backgroundQueue = <_ReadAdmission>[];
  Completer<void> changed = Completer<void>();
  int bytes = 0, foreground = 0, background = 0, epoch = 0;
  int? verifiedUserId;
  String? accountKey;
  int? generation;
  bool boundOnce = false, enabled = false;
  DateTime? lastWriteStart;

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
    if (revoke) epoch++;
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

  Uri canonical(Uri uri) {
    final segments = path(uri);
    if (segments.length >= 2 && segments[0] == 'projects') {
      segments[1] = aliases[segments[1]] ?? segments[1];
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
      final id = aliases[p[1]] ?? p[1];
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

  void observe(Uri uri, Json json) {
    final p = path(uri);
    if (p.length == 1 && p.first == 'user' && json['id'] is int) {
      verifiedUserId = json['id'] as int;
      if (enabled && accountKey != '${api.instance.key}#$verifiedUserId') {
        enabled = false;
        clear();
      }
    }
    observeProjectAlias(uri, json);
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
      if (fullPath is String) aliases[fullPath] = id;
      if (int.tryParse(p[1]) == null) aliases[p[1]] = id;
    }
  }

  void observePrivacy(Uri uri, Json json) {
    final p = path(canonical(uri));
    final issueEndpoint =
        p.first == 'issues' || (p.length >= 3 && p[2] == 'issues');
    if (!issueEndpoint || json['confidential'] is! bool) return;
    final project =
        json['project_id'] ??
        (p.length >= 3 && p.first == 'projects' ? int.tryParse(p[1]) : null);
    final iid = json['iid'] ?? (p.length == 4 ? int.tryParse(p[3]) : null);
    if (project is! int || iid is! int) return;
    final identity = '$project:$iid';
    final previous = confidentialIssues.remove(identity);
    confidentialIssues[identity] = json['confidential'] as bool;
    while (confidentialIssues.length > 4096) {
      confidentialIssues.remove(confidentialIssues.keys.first);
    }
    if (json['confidential'] != true || previous == true) return;
    // The authorized current response remains displayable. Revoke older
    // publications and list snapshots that can contain its former visibility.
    revoke(api.instance.api(['projects', '$project', 'issues', '$iid']), 403);
    for (final scope in ['userLists', 'groupWorkItems']) {
      versions[scope] = (versions[scope] ?? 0) + 1;
      sourceWriteTimes[scope] = api._readCacheClock();
    }
    evictWhere(
      (_, scope, _) => scope == 'userLists' || scope == 'groupWorkItems',
    );
  }

  void observeLoadedPrivacy(Uri uri, Object value) {
    if (value is Json) observePrivacy(uri, value);
    if (value is ApiPage<Json>) {
      for (final item in value.items) {
        observePrivacy(uri, item);
      }
    }
  }

  _ReadClass? classify(Uri uri, {required bool page}) {
    final p = path(uri), q = uri.queryParameters;
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
    if (stamp['account'] != epoch) return false;
    final current = permissions(canonical(uri));
    return current.entries
        .where((e) => e.key != 'account' && e.key != 'sequence')
        .every((e) => e.value <= (stamp['sequence'] ?? 0));
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
      final revoked = sourceRevocations[jsonEncode(p.take(i).toList())];
      if (revoked != null && !fetchedAt.isAfter(revoked)) return false;
    }
    if (!pinned) {
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
    if (!api.instance.allowsApi(uri)) {
      throw const ApiFailure(FailureKind.unsupported);
    }
    final canCache = enabled && policy != null;
    final cacheKey = key(uri, accept);
    final pinned = policy == _ReadClass.pinned;
    final readScope = scope(uri);
    final permission = permissions(uri);
    final lookupVersion = snapshot(readScope, pinned);
    bool usable(_ReadEntry entry) {
      final age = api._readCacheClock().difference(entry.fetchedAt);
      return (allowDisk || entry.lineage != CacheLineage.disk) &&
          age >= Duration.zero &&
          age < retention(entry.policy) &&
          (maxAge == null || age < maxAge);
    }

    CachedRead<T> result(_ReadEntry entry) {
      final value = entry.value as T;
      validate?.call(value);
      return CachedRead(
        value: value,
        fetchedAt: entry.fetchedAt,
        lineage: entry.lineage == CacheLineage.disk
            ? CacheLineage.disk
            : CacheLineage.memory,
        stale:
            !pinned &&
            api._readCacheClock().difference(entry.fetchedAt) >=
                freshness(entry.policy),
      );
    }

    if (canCache && !fresh && (pinned || !active(readScope))) {
      final cached = entries.remove(cacheKey);
      if (cached != null) {
        bytes -= cached.cost;
        final age = api._readCacheClock().difference(cached.fetchedAt);
        if (age >= Duration.zero && age < retention(cached.policy)) {
          entries[cacheKey] = cached;
          bytes += cached.cost;
          if (usable(cached)) return result(cached);
        }
      }
      final source = api._readCacheSource;
      if (allowDisk && source != null) {
        final hydrationTicket = Object();
        publicationTickets[cacheKey] = hydrationTicket;
        final CacheDiskEntry? hydrated;
        try {
          hydrated = await source(uri, accept);
        } catch (_) {
          if (identical(publicationTickets[cacheKey], hydrationTicket)) {
            publicationTickets.remove(cacheKey);
          }
          rethrow;
        }
        final ownsHydration = identical(
          publicationTickets[cacheKey],
          hydrationTicket,
        );
        if (ownsHydration) publicationTickets.remove(cacheKey);
        if (!permitted(permission, uri) || api._closed) {
          throw const ApiFailure(FailureKind.cancelled);
        }
        final newer = entries[cacheKey];
        if (!ownsHydration && newer != null && usable(newer)) {
          return result(newer);
        }
        if (ownsHydration &&
            hydrated != null &&
            hydrated.value is T &&
            hydrated.responseBytes >= 0 &&
            hydrated.responseBytes <= entryLimit) {
          final value = _freezeCached(hydrated.value) as T;
          // Only project aliases are learned from disk; SHA confirmation
          // remains restricted to trusted network response types.
          final p = path(uri);
          if (value is Json && p.length == 2 && p.first == 'projects') {
            observeProjectAlias(uri, value);
          }
          final canonicalUri = canonical(uri);
          final entry = _ReadEntry(
            canonicalUri,
            value,
            hydrated.fetchedAt,
            CacheLineage.disk,
            policy,
            scope(canonicalUri),
            hydrated.responseBytes * 4,
          );
          if (usable(entry) &&
              sourceAllowed(canonicalUri, hydrated.fetchedAt, pinned) &&
              stable(lookupVersion) &&
              (pinned || !active(readScope))) {
            validate?.call(value);
            store(key(canonicalUri, accept), entry);
            return result(entry);
          }
        }
      }
      final inFlight = pending[cacheKey];
      if (inFlight != null) {
        final shared = await inFlight.future as CachedRead<T>;
        // A disk-forbidden caller never joins a disk hydration result.
        if (allowDisk || shared.lineage != CacheLineage.disk) return shared;
      }
    }
    final ticket = Object();
    if (canCache) publicationTickets[cacheKey] = ticket;
    late final Future<CachedRead<T>> operation;
    operation = () async {
      var admitted = false;
      try {
        if (api._closed || !permitted(permission, uri)) {
          throw const ApiFailure(FailureKind.cancelled);
        }
        if (fresh && (supersededFresh[cacheKey] ?? 0) >= 2 && !pinned) {
          await waitForQuiet();
        }
        for (var attempt = 0; ; attempt++) {
          var waited = !canCache || pinned || await waitForWrites(readScope);
          admitted = await admit(background);
          if (!admitted) {
            if (api._closed) throw const ApiFailure(FailureKind.cancelled);
            return CachedRead<T>.dropped();
          }
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
          }
          if (api._closed || !permitted(permission, uri)) {
            throw const ApiFailure(FailureKind.cancelled);
          }
          final start = snapshot(readScope, !canCache || pinned);
          final loaded = await load();
          if (api._closed || !permitted(permission, uri)) {
            throw const ApiFailure(FailureKind.cancelled);
          }
          final consistent = stable(start) && (pinned || !active(readScope));
          if (canCache && !pinned && !consistent && waited && attempt == 0) {
            release(background);
            admitted = false;
            continue;
          }
          final invalid =
              canCache &&
              ((!pinned && !consistent && waited) ||
                  !identical(publicationTickets[cacheKey], ticket));
          final timedOut = !waited;
          final fetchedAt = api._readCacheClock();
          if (invalid) {
            supersededFresh[cacheKey] =
                (supersededFresh[cacheKey] ?? 0) + (fresh ? 1 : 0);
          } else if (!timedOut) {
            supersededFresh.remove(cacheKey);
          }
          final value = _freezeCached(loaded.value) as T;
          validate?.call(value);
          if (!invalid) observeLoadedPrivacy(uri, value);
          if (canCache &&
              !invalid &&
              !timedOut &&
              loaded.store &&
              loaded.bytes <= entryLimit) {
            final canonicalUri = canonical(uri);
            store(
              key(canonicalUri, accept),
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
          return CachedRead<T>(
            value: value,
            fetchedAt: fetchedAt,
            lineage: CacheLineage.network,
            stale: timedOut,
            superseded: invalid,
          );
        }
      } finally {
        if (admitted) release(background);
        if (identical(publicationTickets[cacheKey], ticket)) {
          publicationTickets.remove(cacheKey);
        }
        if (identical(pending[cacheKey]?.future, operation)) {
          pending.remove(cacheKey);
        }
      }
    }();
    if (canCache && !fresh) {
      pending[cacheKey] = _PendingRead(uri, readScope, pinned, operation);
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
      final id = aliases[p[1]] ?? p[1];
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
    for (final scope in scopes) {
      versions[scope] = (versions[scope] ?? 0) + 1;
      sourceWriteTimes[scope] = api._readCacheClock();
      writes[scope] = (writes[scope] ?? 0) + (starting ? 1 : -1);
    }
    if (starting) lastWriteStart = api._readCacheClock();
    evictWhere(
      (uri, scope, pinned) =>
          !pinned && (scopes.contains('global') || scopes.contains(scope)),
    );
    if (scopes.contains('global')) {
      aliases.clear();
    } else {
      aliases.removeWhere((_, id) => scopes.contains('project:$id'));
    }
    signal();
  }

  void revoke(Uri uri, int status, {bool terminal401 = true}) {
    if (status == 401) {
      if (terminal401) sourceAccountRevokedAt = api._readCacheClock();
      clear(revoke: terminal401);
      return;
    }
    if (status != 403 && status != 404) return;
    var p = path(canonical(uri));
    // A collection failure revokes that query, not every resource below
    // /projects or /groups. Only a project detail revokes its whole project.
    if (p.length == 1) {
      final request = requestRevocationKey(uri);
      api._readEpoch++;
      revocations[request] = ++revocationSequence;
      sourceRevocations[request] = api._readCacheClock();
      evictWhere((target, _, _) => requestRevocationKey(target) == request);
      signal();
      return;
    }
    if (p.length == 4 &&
        p[0] == 'projects' &&
        const {'issues', 'merge_requests'}.contains(p[2])) {
      p = p.take(4).toList();
    }
    api._readEpoch++;
    final revoked = jsonEncode(p);
    revocations[revoked] = ++revocationSequence;
    sourceRevocations[revoked] = api._readCacheClock();
    bool matches(Uri uri) {
      final target = path(canonical(uri));
      return target.length >= p.length &&
          List.generate(p.length, (i) => target[i] == p[i]).every((v) => v);
    }

    evictWhere((uri, _, _) => matches(uri));
    if (p.length == 2 && p.first == 'projects') {
      aliases.removeWhere((_, id) => id == p[1]);
    }
    signal();
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
