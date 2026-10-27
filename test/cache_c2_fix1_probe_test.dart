import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';

import 'support/fake_adapter.dart';

const _account = 'https://example.com/gitlab#7';
const _clear = DiskClearResult(
  keyGoneConfirmed: false,
  directoryGoneConfirmed: false,
  markerDurable: false,
  complete: false,
);
final _now = DateTime.utc(2026, 10, 27, 12);

final class _Fence implements DiskInvalidationFence {
  _Fence(this.barrier);
  @override
  final Future<DiskClearResult> barrier;
  @override
  Future<void> get quiesced => barrier.then((_) {}, onError: (Object _) {});
  bool revoked = false;
  @override
  bool get isCurrent => !revoked;
  @override
  void revoke() => revoked = true;
}

final class _Backend implements ReadCacheDiskBackend {
  final accepted = <(DiskWriteCandidate, ProjectedDiskEntry)>[];
  final events = <DiskInvalidation>[];
  Future<ProjectedDiskEntry?> Function(DiskLookup)? read;
  Completer<DiskClearResult>? hold;
  int lookups = 0;
  @override
  Future<ProjectedDiskEntry?> lookup(DiskLookup value) async {
    lookups++;
    return read?.call(value);
  }

  @override
  void accept(DiskWriteCandidate c, ProjectedDiskEntry e) =>
      accepted.add((c, e));
  @override
  DiskInvalidationFence invalidate(DiskInvalidation value) {
    events.add(value);
    final h = hold;
    return _Fence(h == null ? Future.value(_clear) : h.future);
  }

  @override
  Future<DiskClearResult> clear(
    DiskBinding b,
    ReadCacheCleanupOperation o,
  ) async => _clear;
  @override
  void revoke(DiskBinding binding) {}
  @override
  void reportCleanup(ReadCacheCleanupState state) {}
}

Map<String, Object?> _issue(int iid, {bool confidential = false}) => {
  'id': 100 + iid,
  'iid': iid,
  'project_id': 9,
  'title': 'Issue $iid',
  'confidential': confidential,
  'assignee': null,
  'milestone': null,
  'closed_at': null,
  'due_date': null,
  'references': {'short': '#$iid', 'relative': '#$iid', 'full': 'g/p#$iid'},
  'labels': <Object?>[],
};

GitLabApi _api(_Backend backend, FakeAdapter adapter, int generation) =>
    GitLabApi(
        instance: GitLabInstance.parse('https://example.com/gitlab'),
        token: 'synthetic-test-token',
        dio: Dio()..httpClientAdapter = adapter,
        readCacheClock: () => _now,
      )
      ..bindReadCache(_account, generation)
      ..attachReadCacheDiskBackend(backend);

void main() {
  for (final revoked in ['project', 'list-request']) {
    test('network settlement rechecks $revoked revocation', () async {
      final backend = _Backend()..hold = Completer<DiskClearResult>();
      var listCalls = 0;
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/issues/4')) {
          return jsonResponse(_issue(4, confidential: true));
        }
        if (path.endsWith('/projects/9')) {
          return jsonResponse({'message': '404 Not found'}, status: 404);
        }
        if (path.endsWith('/projects/9/issues')) {
          listCalls++;
          if (revoked == 'list-request' && listCalls >= 2) {
            return jsonResponse({'message': '403 Forbidden'}, status: 403);
          }
          return jsonResponse([_issue(3)]);
        }
        return jsonResponse({'message': 'not found'}, status: 404);
      });
      final api = _api(backend, adapter, 1);
      addTearDown(api.close);

      // Hold an unrelated privacy invalidation so the network read must settle.
      unawaited(
        api
            .record(['projects', '9', 'issues', '4'])
            .then<void>((_) {}, onError: (Object _) {}),
      );
      for (var i = 0; i < 100 && backend.events.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(backend.events, isNotEmpty);
      final listing = api.cachedRecords(['projects', '9', 'issues']);
      for (var i = 0; i < 100 && listCalls == 0; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(listCalls, 1);
      var done = false;
      unawaited(
        listing.then<void>(
          (_) => done = true,
          onError: (Object _) => done = true,
        ),
      );
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(done, isFalse, reason: 'the list is waiting for disk settlement');

      final Future<Object> revoke = revoked == 'project'
          ? api
                .record(['projects', '9'])
                .then<Object>((v) => v, onError: (Object e) => e)
          : api
                .records(['projects', '9', 'issues'])
                .then<Object>((v) => v, onError: (Object e) => e);
      for (var i = 0; i < 100 && backend.events.length < 2; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(backend.events.length, greaterThanOrEqualTo(2));
      backend.hold!.complete(_clear);
      final first = await listing;
      final failure = await revoke;
      expect(first.lineage, CacheLineage.network);
      expect(
        failure,
        isA<ApiFailure>().having(
          (e) => e.kind,
          'kind',
          revoked == 'project' ? FailureKind.invisible : FailureKind.forbidden,
        ),
      );
      expect(backend.accepted, isEmpty);
      final before = listCalls;
      final again = await api
          .cachedRecords(['projects', '9', 'issues'])
          .then<Object>((v) => v, onError: (Object e) => e);
      expect(
        listCalls,
        before + 1,
        reason: 'revoked response must not be retained',
      );
      if (revoked == 'project') {
        expect(
          again,
          isA<CachedRead<Object?>>().having(
            (r) => r.lineage,
            'lineage',
            CacheLineage.network,
          ),
        );
      } else {
        expect(
          again,
          isA<ApiFailure>().having(
            (e) => e.kind,
            'kind',
            FailureKind.forbidden,
          ),
        );
      }
    });
  }
  for (final change in ['confidential', '404']) {
    test('PROBE: $change on a listed issue during hydration settle', () async {
      // 1. A first client publishes the public list; capture its exact entry.
      final writer = _Backend();
      final a = _api(writer, FakeAdapter((_) => jsonResponse([_issue(3)])), 1);
      await a.cachedRecords(['projects', '9', 'issues']);
      final stored = writer.accepted.single.$2;
      a.close();

      // 2. A new generation hydrates that entry while an unrelated privacy
      // invalidation keeps settleDiskSafety() waiting.
      final backend = _Backend()
        ..read = ((lookup) async =>
            lookup.canonicalKey == stored.canonicalKey ? stored : null)
        ..hold = Completer<DiskClearResult>();
      final adapter = FakeAdapter((r) {
        if (r.uri.path.endsWith('/issues/4')) {
          return jsonResponse(_issue(4, confidential: true));
        }
        if (r.uri.path.endsWith('/issues/3')) {
          return change == '404'
              ? jsonResponse({'message': '404 Not found'}, status: 404)
              : jsonResponse(_issue(3, confidential: true));
        }
        return jsonResponse([_issue(3, confidential: true)]);
      });
      final b = _api(backend, adapter, 2);
      addTearDown(b.close);
      unawaited(
        b
            .record(['projects', '9', 'issues', '4'])
            .then((_) {}, onError: (Object _) {}),
      );
      for (var i = 0; i < 100 && backend.events.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(backend.events, isNotEmpty);
      final hydrating = b.cachedRecords(['projects', '9', 'issues']);
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      // 3. While hydration waits, the server says issue 3 is confidential/404.
      final change3 = b
          .record(['projects', '9', 'issues', '3'])
          .then<Object>((v) => v, onError: (Object e) => e);
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      backend.hold!.complete(_clear);
      final read = await hydrating;
      // ignore: avoid_print
      print(
        'PROBE $change: lineage=${read.lineage} stale=${read.stale} '
        'items=${read.value.items.map((e) => '${e['iid']}:${e['confidential']}').toList()} '
        'change3=${await change3 is Map ? 'value' : await change3}',
      );
      final again = await b.cachedRecords(['projects', '9', 'issues']);
      // ignore: avoid_print
      print(
        'PROBE $change again: lineage=${again.lineage} '
        'items=${again.value.items.map((e) => '${e['iid']}:${e['confidential']}').toList()}',
      );
      expect(
        read.lineage,
        isNot(CacheLineage.disk),
        reason: 'disk response must be discarded after a $change change',
      );
      expect(read.value.items.single['confidential'], isTrue);
      expect(again.value.items.single['confidential'], isTrue);
      expect(
        backend.events.any((e) => e.issueIdentities.any((id) => id.iid == 3)),
        isTrue,
      );
    });
  }

  test(
    'PROBE: in-flight list publishes issue 3 after its 404 disk deletion',
    () async {
      final backend = _Backend();
      final heldList = Completer<ResponseBody>();
      final adapter = FakeAdapter((r) {
        if (r.uri.path.endsWith('/issues/3')) {
          return jsonResponse({'message': '404 Not found'}, status: 404);
        }
        return heldList.future;
      });
      final api = _api(backend, adapter, 1);
      addTearDown(api.close);
      final list = api.cachedRecords(['projects', '9', 'issues']);
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      await expectLater(
        api.record(['projects', '9', 'issues', '3']),
        throwsA(anything),
      );
      final deletion = backend.events.lastWhere(
        (e) => e.kind == DiskInvalidationKind.permission,
      );
      // ignore: avoid_print
      print(
        'PROBE inflight: deletion identities=${deletion.issueIdentities} path=${deletion.path}',
      );
      heldList.complete(jsonResponse([_issue(3)]));
      await list;
      final published = backend.accepted
          .where(
            (a) => a.$2.issueIdentities.any(
              (id) => id.projectId == 9 && id.iid == 3,
            ),
          )
          .toList();
      // ignore: avoid_print
      print(
        'PROBE inflight: accepted after deletion=${published.length} leaseCurrent=${published.map((p) => p.$1.lease.isCurrent).toList()}',
      );
      expect(
        published,
        isEmpty,
        reason: 'list fetched before the 404 must not republish issue 3',
      );
    },
  );

  test('PROBE: closed client returns a value after privacy settle', () async {
    final backend = _Backend()..hold = Completer<DiskClearResult>();
    final api = _api(
      backend,
      FakeAdapter((_) => jsonResponse(_issue(3, confidential: true))),
      1,
    );
    final pending = api
        .record(['projects', '9', 'issues', '3'])
        .then<Object>((v) => v, onError: (Object e) => e);
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    api.close();
    backend.hold!.complete(_clear);
    final outcome = await pending;
    expect(
      outcome,
      isA<ApiFailure>().having((e) => e.kind, 'kind', FailureKind.cancelled),
    );
  });

  for (final cacheable in [false, true]) {
    test(
      'closed client cancels cached ${cacheable ? 'network' : 'uncached'} read after privacy settle',
      () async {
        final backend = _Backend()..hold = Completer<DiskClearResult>();
        final api = _api(
          backend,
          FakeAdapter((_) => jsonResponse(_issue(3, confidential: true))),
          1,
        );
        final path = cacheable ? ['projects', '9', 'issues', '3'] : ['unknown'];
        final pending = api
            .cachedRecord(path)
            .then<Object>((v) => v, onError: (Object e) => e);
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(backend.events, isNotEmpty);
        api.close();
        backend.hold!.complete(_clear);
        expect(
          await pending,
          isA<ApiFailure>().having(
            (e) => e.kind,
            'kind',
            FailureKind.cancelled,
          ),
        );
      },
    );
  }

  for (final age in [const Duration(minutes: 11), const Duration(days: 8)]) {
    test('disk lookup respects seven-day lifetime at $age', () async {
      final writer = _Backend();
      final first = _api(
        writer,
        FakeAdapter((_) => jsonResponse([_issue(3)])),
        1,
      );
      await first.cachedRecords(['projects', '9', 'issues']);
      final original = writer.accepted.single.$2;
      first.close();
      final stored = ProjectedDiskEntry(
        accountKey: original.accountKey,
        canonicalKey: original.canonicalKey,
        cacheClass: original.cacheClass,
        bodyKind: original.bodyKind,
        fetchedAt: _now.subtract(age),
        body: original.body,
        privacyEpoch: original.privacyEpoch,
        issueIdentities: original.issueIdentities,
        scopeVersions: original.scopeVersions,
        scopeTags: original.scopeTags,
      );
      final backend = _Backend()..read = (lookup) async => stored;
      final adapter = FakeAdapter((_) => jsonResponse([_issue(4)]));
      final api = _api(backend, adapter, 2);
      addTearDown(api.close);
      final result = await api.cachedRecords(['projects', '9', 'issues']);
      if (age < const Duration(days: 7)) {
        expect(result.lineage, CacheLineage.disk);
        expect(result.stale, isTrue);
        expect(result.fetchedAt, stored.fetchedAt);
        expect(adapter.requests, isEmpty);
      } else {
        expect(result.lineage, CacheLineage.network);
        expect(adapter.requests, hasLength(1));
      }
    });
  }

  test('closed client cancels hydration after privacy settle', () async {
    final writer = _Backend();
    final original = _api(
      writer,
      FakeAdapter((_) => jsonResponse([_issue(3)])),
      1,
    );
    await original.cachedRecords(['projects', '9', 'issues']);
    final stored = writer.accepted.single.$2;
    original.close();
    final backend = _Backend()
      ..read = ((lookup) async => stored)
      ..hold = Completer<DiskClearResult>();
    final api = _api(
      backend,
      FakeAdapter((_) => jsonResponse(_issue(4, confidential: true))),
      2,
    );
    unawaited(
      api
          .record(['projects', '9', 'issues', '4'])
          .then<void>((_) {}, onError: (Object _) {}),
    );
    for (var i = 0; i < 100 && backend.events.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(backend.events, isNotEmpty);
    final pending = api
        .cachedRecords(['projects', '9', 'issues'])
        .then<Object>((v) => v, onError: (Object e) => e);
    for (var i = 0; i < 100 && backend.lookups == 0; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(backend.lookups, 1);
    await Future<void>.delayed(Duration.zero);
    api.close();
    backend.hold!.complete(_clear);
    expect(
      await pending,
      isA<ApiFailure>().having((e) => e.kind, 'kind', FailureKind.cancelled),
    );
  });

  for (final damage in ['projection', 'identity', 'account', 'key']) {
    test('invalid disk $damage removes the exact entry', () async {
      final writer = _Backend();
      final first = _api(
        writer,
        FakeAdapter((_) => jsonResponse([_issue(3)])),
        1,
      );
      await first.cachedRecords(['projects', '9', 'issues']);
      final original = writer.accepted.single.$2;
      first.close();
      final stored = ProjectedDiskEntry(
        accountKey: damage == 'account'
            ? 'foreign-account'
            : original.accountKey,
        canonicalKey: damage == 'key' ? 'foreign-key' : original.canonicalKey,
        cacheClass: original.cacheClass,
        bodyKind: original.bodyKind,
        fetchedAt: original.fetchedAt,
        body: damage == 'projection'
            ? {
                'items': ['invalid'],
                'next': null,
              }
            : original.body,
        privacyEpoch: original.privacyEpoch,
        issueIdentities: damage == 'identity' ? {} : original.issueIdentities,
        scopeVersions: original.scopeVersions,
        scopeTags: original.scopeTags,
      );
      final backend = _Backend()..read = (lookup) async => stored;
      final adapter = FakeAdapter((_) => jsonResponse([_issue(4)]));
      final api = _api(backend, adapter, 2);
      addTearDown(api.close);
      final result = await api.cachedRecords(['projects', '9', 'issues']);
      expect(result.lineage, CacheLineage.network);
      expect(
        backend.events.any((e) => e.canonicalKey == original.canonicalKey),
        isTrue,
      );
    });
  }

  test('invalid old lookup cannot delete a newer publication', () async {
    final writer = _Backend();
    final first = _api(
      writer,
      FakeAdapter((_) => jsonResponse([_issue(3)])),
      1,
    );
    await first.cachedRecords(['projects', '9', 'issues']);
    final old = writer.accepted.single.$2;
    first.close();
    final invalid = ProjectedDiskEntry(
      accountKey: old.accountKey,
      canonicalKey: old.canonicalKey,
      cacheClass: old.cacheClass,
      bodyKind: old.bodyKind,
      fetchedAt: old.fetchedAt,
      body: {
        'items': ['invalid'],
        'next': null,
      },
      privacyEpoch: old.privacyEpoch,
      issueIdentities: old.issueIdentities,
    );
    final held = Completer<ProjectedDiskEntry?>();
    final backend = _Backend()..read = (lookup) => held.future;
    final api = _api(backend, FakeAdapter((_) => jsonResponse([_issue(4)])), 2);
    addTearDown(api.close);
    final pending = api.cachedRecords(['projects', '9', 'issues']);
    for (var i = 0; i < 100 && backend.lookups == 0; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(backend.lookups, 1);
    final newer = await api.cachedRecords([
      'projects',
      '9',
      'issues',
    ], fresh: true);
    expect(newer.lineage, CacheLineage.network);
    expect(backend.accepted, hasLength(1));
    held.complete(invalid);
    final result = await pending;
    expect(result.value.items.single['iid'], 4);
    expect(
      backend.events.where((e) => e.canonicalKey == old.canonicalKey),
      isEmpty,
    );
  });
}
