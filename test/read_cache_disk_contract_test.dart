import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';

const _binding = DiskBinding(accountKey: 'synthetic-account', generation: 7);
const _clearResult = DiskClearResult(
  keyGoneConfirmed: false,
  directoryGoneConfirmed: true,
  markerDurable: false,
  complete: false,
);

ProjectedDiskEntry _textEntry(
  String body, {
  String canonicalKey = 'projects/1',
}) {
  return ProjectedDiskEntry(
    accountKey: _binding.accountKey,
    canonicalKey: canonicalKey,
    cacheClass: ReadCacheDiskClass.detail,
    bodyKind: ReadCacheBodyKind.text,
    fetchedAt: DateTime.utc(2026, 10, 23),
    body: body,
    privacyEpoch: 2,
    issueIdentities: {const ReadCacheIssueIdentity(1, 2)},
    scopeVersions: const {'project:1': 3},
    scopeTags: const {'project:1'},
  );
}

void main() {
  test(
    'closed enums contain every contract value and flag combinations remain exact',
    () {
      expect(ReadCacheDiskClass.values.map((value) => value.name), [
        'projectMeta',
        'list',
        'detail',
        'thread',
        'pinned',
      ]);
      expect(ReadCacheBodyKind.values.map((value) => value.name), [
        'json',
        'page',
        'text',
        'terminalLog',
      ]);
      expect(ReadCacheProofLineage.values.map((value) => value.name), [
        'network',
        'disk',
      ]);
      expect(DiskInvalidationKind.values.map((value) => value.name), [
        'mutation',
        'privacy',
        'permission',
        'account',
      ]);
      expect(ReadCacheCleanupOperation.values.map((value) => value.name), [
        'mutation',
        'privacyRead',
        'accountRemoval',
        'signOut',
        'settingsClear',
        'startup',
      ]);
      expect(ReadCacheCleanupDisposition.values.map((value) => value.name), [
        'requestBlockedBeforeSend',
        'originalOutcomePreserved',
        'legalNetworkValueReturned',
        'accountRetained',
        'signedOutCleanupPending',
        'diskClosed',
      ]);
      expect(ReadCacheCleanupCode.values.map((value) => value.name), [
        'cleanupFailed',
        'barrierTimedOut',
      ]);

      var completes = 0;
      for (var bits = 0; bits < 16; bits++) {
        DiskClearResult build() => DiskClearResult(
          keyGoneConfirmed: bits & 1 != 0,
          directoryGoneConfirmed: bits & 2 != 0,
          markerDurable: bits & 4 != 0,
          complete: bits & 8 != 0,
        );
        // Complete only when both key and directory are confirmed gone; the
        // marker flag stays independent (a removal may keep its marker).
        if (bits & 8 != 0 && bits & 3 != 3) {
          expect(build, throwsA(isA<AssertionError>()), reason: '$bits');
          continue;
        }
        final result = build();
        expect(result.keyGoneConfirmed, bits & 1 != 0);
        expect(result.directoryGoneConfirmed, bits & 2 != 0);
        expect(result.markerDurable, bits & 4 != 0);
        expect(result.complete, bits & 8 != 0);
        if (result.complete) completes++;
      }
      expect(completes, 2);
    },
  );

  test('bindings compare by the same account and generation only', () {
    expect(
      _binding,
      const DiskBinding(accountKey: 'synthetic-account', generation: 7),
    );
    expect(
      _binding.hashCode,
      const DiskBinding(
        accountKey: 'synthetic-account',
        generation: 7,
      ).hashCode,
    );
    expect(
      _binding,
      isNot(const DiskBinding(accountKey: 'synthetic-account', generation: 8)),
    );
    expect(
      _binding,
      isNot(const DiskBinding(accountKey: 'other-account', generation: 7)),
    );
  });

  test(
    'DTO constructors snapshot mutable collections and expose immutable views',
    () {
      final versions = <String, int>{'project:1': 1};
      final tags = <String>{'project:1'};
      final identities = <ReadCacheIssueIdentity>{
        const ReadCacheIssueIdentity(1, 2),
      };
      final bytes = <int>[1, 2, 3];
      final lease = _Lease();

      final candidate = DiskWriteCandidate(
        binding: _binding,
        uri: Uri.parse('https://example.invalid/api/v4/projects/1'),
        logicalAccept: 'application/json',
        bodyKind: ReadCacheBodyKind.json,
        fetchedAt: DateTime.utc(2026, 10, 23),
        responseBytes: 8,
        lease: lease,
        cacheable: true,
        noStore: false,
        firstPage: true,
        scopeVersions: versions,
        scopeTags: tags,
      );
      final proof = ReadCachePublicIssueProof(
        binding: _binding,
        identity: const ReadCacheIssueIdentity(1, 2),
        fetchedAt: DateTime.utc(2026, 10, 23),
        lineage: ReadCacheProofLineage.network,
        singleIssue: true,
        confidential: false,
        privacyEpoch: 2,
        scopeVersions: versions,
      );
      final entry = ProjectedDiskEntry(
        accountKey: _binding.accountKey,
        canonicalKey: 'projects/1/issues/2',
        cacheClass: ReadCacheDiskClass.detail,
        bodyKind: ReadCacheBodyKind.json,
        fetchedAt: DateTime.utc(2026, 10, 23),
        body: const {'iid': 2},
        privacyEpoch: 2,
        issueIdentities: identities,
        scopeVersions: versions,
        scopeTags: tags,
      );
      final invalidation = DiskInvalidation(
        binding: _binding,
        kind: DiskInvalidationKind.privacy,
        scopeTags: tags,
        issueIdentities: identities,
      );
      final log = ReadCacheTerminalLog(
        projectId: 1,
        jobId: 3,
        finishedAt: DateTime.utc(2026, 10, 23),
        startOffset: 0,
        nextOffset: 3,
        totalBytes: 3,
        isEof: true,
        truncated: false,
        bytes: bytes,
      );

      versions['project:1'] = 99;
      tags.add('mutated');
      identities.add(const ReadCacheIssueIdentity(9, 9));
      bytes[0] = 99;

      expect(candidate.scopeVersions, {'project:1': 1});
      expect(candidate.scopeTags, {'project:1'});
      expect(proof.scopeVersions, {'project:1': 1});
      expect(entry.scopeVersions, {'project:1': 1});
      expect(entry.scopeTags, {'project:1'});
      expect(entry.issueIdentities, {const ReadCacheIssueIdentity(1, 2)});
      expect(invalidation.scopeTags, {'project:1'});
      expect(invalidation.issueIdentities, {
        const ReadCacheIssueIdentity(1, 2),
      });
      expect(log.bytes, [1, 2, 3]);

      expect(() => candidate.scopeVersions['x'] = 1, throwsUnsupportedError);
      expect(() => candidate.scopeTags.add('x'), throwsUnsupportedError);
      expect(() => entry.issueIdentities.clear(), throwsUnsupportedError);
      expect(() => log.bytes[0] = 4, throwsUnsupportedError);
    },
  );

  test('write candidate is control metadata and entry crosses separately', () {
    final backend = _Backend();
    final candidate = DiskWriteCandidate(
      binding: _binding,
      uri: Uri.parse('https://example.invalid/api/v4/projects/1/issues'),
      logicalAccept: 'application/json',
      bodyKind: ReadCacheBodyKind.page,
      fetchedAt: DateTime.utc(2026, 10, 23),
      responseBytes: 123,
      lease: backend.lease,
      cacheable: false,
      noStore: true,
      firstPage: false,
      typedPinned: true,
      privacyEpoch: 4,
    );
    final entry = ProjectedDiskEntry(
      accountKey: _binding.accountKey,
      canonicalKey: 'projects/1/issues',
      cacheClass: ReadCacheDiskClass.pinned,
      bodyKind: ReadCacheBodyKind.page,
      fetchedAt: DateTime.utc(2026, 10, 23),
      body: const [
        {'iid': 2},
      ],
      privacyEpoch: 4,
      issueIdentities: {const ReadCacheIssueIdentity(1, 2)},
    );

    backend.accept(candidate, entry);

    expect(backend.accepted.single.$1, same(candidate));
    expect(backend.accepted.single.$2, same(entry));
    expect(candidate.responseBytes, 123);
    expect(candidate.cacheable, isFalse);
    expect(candidate.noStore, isTrue);
    expect(candidate.firstPage, isFalse);
    expect(candidate.typedPinned, isTrue);
    expect(entry.body, const [
      {'iid': 2},
    ]);
  });

  test(
    'durable metadata excludes generation and has deterministic snapshots',
    () {
      final entry = ProjectedDiskEntry(
        accountKey: _binding.accountKey,
        canonicalKey: 'projects/1/issues?state=opened',
        cacheClass: ReadCacheDiskClass.list,
        bodyKind: ReadCacheBodyKind.page,
        fetchedAt: DateTime.utc(2026, 10, 23, 1, 2, 3),
        body: const [
          {'iid': 8},
        ],
        privacyEpoch: 4,
        issueIdentities: {
          const ReadCacheIssueIdentity(2, 8),
          const ReadCacheIssueIdentity(1, 9),
        },
        scopeVersions: const {'z': 2, 'a': 1},
        scopeTags: const {'z', 'a'},
      );

      expect(entry.metadata, {
        'schema': readCacheDiskSchemaVersion,
        'accountKey': 'synthetic-account',
        'canonicalKey': 'projects/1/issues?state=opened',
        'cacheClass': 'list',
        'bodyKind': 'page',
        'fetchedAt': '2026-10-23T01:02:03.000Z',
        'privacyEpoch': 4,
        'scopeTags': ['a', 'z'],
        'scopeVersions': {'a': 1, 'z': 2},
        'issueIdentities': [
          [1, 9],
          [2, 8],
        ],
      });
      expect(entry.metadata, isNot(contains('generation')));
      expect(jsonEncode(entry.metadata), isNot(contains('"generation"')));
    },
  );

  test(
    'serialized framing counts four-byte metadata, UTF-8 metadata and body',
    () {
      final entry = _textEntry('尾🙂');
      final metadataBytes = utf8.encode(jsonEncode(entry.metadata));
      final bodyBytes = utf8.encode('尾🙂');
      expect(entry.bodyBytes, bodyBytes);
      expect(
        entry.serializedLength,
        readCacheMetadataLengthBytes + metadataBytes.length + bodyBytes.length,
      );

      final empty = _textEntry('');
      final exactBodyLength = readCacheEntryLimit - empty.serializedLength;
      final exact = _textEntry('x' * exactBodyLength);
      expect(exact.serializedLength, readCacheEntryLimit);
      expect(exact.plaintextLimit, readCacheEntryLimit);

      final tooLarge = _textEntry('x' * (exactBodyLength + 1));
      expect(tooLarge.bodyBytes.length, lessThan(readCacheEntryLimit));
      expect(
        tooLarge.serializedLength,
        readCacheEntryLimit + 1,
        reason: 'metadata and framing are part of the plaintext cap',
      );
    },
  );

  test(
    'terminal log preserves valid UTF-8 tail offsets and serializes metadata',
    () {
      final full = utf8.encode('prefix\n尾🙂\n');
      final tail = utf8.encode('尾🙂\n');
      final start = full.length - tail.length;
      final log = ReadCacheTerminalLog(
        projectId: 11,
        jobId: 22,
        finishedAt: DateTime.utc(2026, 10, 23, 4, 5, 6),
        startOffset: start,
        nextOffset: full.length,
        totalBytes: full.length,
        isEof: true,
        truncated: true,
        bytes: tail,
      );
      final entry = ProjectedDiskEntry(
        accountKey: _binding.accountKey,
        canonicalKey: 'projects/11/jobs/22/trace',
        cacheClass: ReadCacheDiskClass.pinned,
        bodyKind: ReadCacheBodyKind.terminalLog,
        fetchedAt: DateTime.utc(2026, 10, 23, 4, 5, 7),
        body: log,
        privacyEpoch: 0,
        issueIdentities: const {},
      );

      expect(utf8.decode(entry.bodyBytes), '尾🙂\n');
      expect(entry.metadata['terminalLog'], {
        'projectId': 11,
        'jobId': 22,
        'finishedAt': '2026-10-23T04:05:06.000Z',
        'startOffset': start,
        'nextOffset': full.length,
        'totalBytes': full.length,
        'isEof': true,
        'truncated': true,
      });
      expect(entry.plaintextLimit, readCacheTerminalLogLimit);
      expect(
        entry.serializedLength,
        readCacheMetadataLengthBytes +
            utf8.encode(jsonEncode(entry.metadata)).length +
            tail.length,
      );

      ProjectedDiskEntry terminalEntry(List<int> bytes) {
        return ProjectedDiskEntry(
          accountKey: _binding.accountKey,
          canonicalKey: 'projects/11/jobs/22/trace',
          cacheClass: ReadCacheDiskClass.pinned,
          bodyKind: ReadCacheBodyKind.terminalLog,
          fetchedAt: DateTime.utc(2026, 10, 23, 4, 5, 7),
          body: ReadCacheTerminalLog(
            projectId: 11,
            jobId: 22,
            finishedAt: DateTime.utc(2026, 10, 23, 4, 5, 6),
            startOffset: 0,
            nextOffset: 0,
            totalBytes: 0,
            isEof: true,
            truncated: false,
            bytes: bytes,
          ),
          privacyEpoch: 0,
          issueIdentities: const {},
        );
      }

      final empty = terminalEntry(const []);
      final exactBodyLength =
          readCacheTerminalLogLimit - empty.serializedLength;
      final exact = terminalEntry(Uint8List(exactBodyLength));
      expect(exact.serializedLength, readCacheTerminalLogLimit);
      final tooLarge = terminalEntry(Uint8List(exactBodyLength + 1));
      expect(
        tooLarge.serializedLength,
        readCacheTerminalLogLimit + 1,
        reason: 'terminal metadata and framing share the 2 MiB cap',
      );
    },
  );

  test('startup decision readability requires every inventory source', () {
    ReadCacheStartupDecision decision({
      bool accounts = true,
      bool marker = true,
      bool active = true,
    }) => ReadCacheStartupDecision(
      operationTicket: 1,
      accountListRevision: 2,
      accountsReadable: accounts,
      signOutMarkerReadable: marker,
      lastActiveReadable: active,
      signOutPending: false,
      resumeAccountKey: null,
    );

    expect(decision().readable, isTrue);
    expect(decision(accounts: false).readable, isFalse);
    expect(decision(marker: false).readable, isFalse);
    expect(decision(active: false).readable, isFalse);
  });

  test(
    'backend fences synchronously, then exposes separate barrier and quiescence',
    () async {
      final backend = _Backend();
      final invalidation = DiskInvalidation(
        binding: _binding,
        kind: DiskInvalidationKind.mutation,
        scopeTags: const {'project:1'},
      );

      final fence = backend.invalidate(invalidation);
      expect(backend.invalidations, [same(invalidation)]);
      expect(fence.isCurrent, isTrue);

      backend.revoke(_binding);
      expect(backend.revoked, [_binding]);
      expect(backend.lease.isCurrent, isFalse);

      const state = ReadCacheCleanupState(
        operation: ReadCacheCleanupOperation.mutation,
        disposition: ReadCacheCleanupDisposition.originalOutcomePreserved,
        code: ReadCacheCleanupCode.cleanupFailed,
        clearResult: _clearResult,
      );
      backend.reportCleanup(state);
      expect(backend.reports, [same(state)]);

      var barrierDone = false;
      var quiescedDone = false;
      unawaited(fence.barrier.then((_) => barrierDone = true));
      unawaited(fence.quiesced.then((_) => quiescedDone = true));
      await Future<void>.delayed(Duration.zero);
      expect(barrierDone, isFalse);
      expect(quiescedDone, isFalse);

      backend.fence.barrierCompleter.complete(_clearResult);
      expect(await fence.barrier, same(_clearResult));
      expect(barrierDone, isTrue);
      expect(
        quiescedDone,
        isFalse,
        reason: 'durable barrier completion does not claim I/O quiescence',
      );

      fence.revoke();
      expect(fence.isCurrent, isFalse);
      backend.fence.quiescedCompleter.complete();
      await fence.quiesced;
      expect(quiescedDone, isTrue);
    },
  );
}

final class _Lease implements DiskCommitLease {
  @override
  bool isCurrent = true;

  @override
  void revoke() => isCurrent = false;
}

final class _Fence implements DiskInvalidationFence {
  final barrierCompleter = Completer<DiskClearResult>();
  final quiescedCompleter = Completer<void>();

  @override
  bool isCurrent = true;

  @override
  Future<DiskClearResult> get barrier => barrierCompleter.future;

  @override
  Future<void> get quiesced => quiescedCompleter.future;

  @override
  void revoke() => isCurrent = false;
}

final class _Backend implements ReadCacheDiskBackend {
  final accepted = <(DiskWriteCandidate, ProjectedDiskEntry)>[];
  final invalidations = <DiskInvalidation>[];
  final revoked = <DiskBinding>[];
  final reports = <ReadCacheCleanupState>[];
  final fence = _Fence();
  final lease = _Lease();

  @override
  void accept(DiskWriteCandidate candidate, ProjectedDiskEntry entry) {
    accepted.add((candidate, entry));
  }

  @override
  Future<DiskClearResult> clear(
    DiskBinding binding,
    ReadCacheCleanupOperation operation,
  ) async => _clearResult;

  @override
  DiskInvalidationFence invalidate(DiskInvalidation invalidation) {
    invalidations.add(invalidation);
    return fence;
  }

  @override
  Future<ProjectedDiskEntry?> lookup(DiskLookup lookup) async => null;

  @override
  void reportCleanup(ReadCacheCleanupState state) => reports.add(state);

  @override
  void revoke(DiskBinding binding) {
    revoked.add(binding);
    lease.revoke();
  }
}
