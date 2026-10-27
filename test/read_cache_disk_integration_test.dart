import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/read_cache_cipher.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/core/read_cache_files.dart';
import 'package:gitlab_mobile/core/read_cache_projection.dart';
import 'package:gitlab_mobile/features/cache/read_cache_disk_backend.dart';
import 'package:gitlab_mobile/features/cache/read_cache_disk_coordinator.dart';
import 'package:gitlab_mobile/features/cache/read_cache_key_store.dart';
import 'package:gitlab_mobile/features/cache/read_cache_settings_store.dart';

import 'support/fake_adapter.dart';

final _instance = GitLabInstance.parse('https://cache.example/subpath');
final _account = '${_instance.key}#7';
final _now = DateTime.utc(2026, 10, 27, 12);
const _sha = '0123456789abcdef0123456789abcdef01234567';

void Function(ReadCacheFileCheckpoint) _pauseIndex(
  SendPort events,
  String release,
) => (step) {
  if (step != ReadCacheFileCheckpoint.beforeIndexRename) return;
  events.send('paused');
  final until = DateTime.now().add(const Duration(seconds: 15));
  while (!File(release).existsSync()) {
    if (DateTime.now().isAfter(until)) {
      throw StateError('pause expired');
    }
    sleep(const Duration(milliseconds: 1));
  }
};

final class _Lease implements DiskCommitLease {
  @override
  bool isCurrent = true;
  @override
  void revoke() => isCurrent = false;
}

final class _Storage implements ReadCacheSecureStorage {
  final values = <String, String>{};
  int keyWrites = 0;

  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (key.startsWith(ReadCacheKeyStore.keyPrefix)) keyWrites++;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<Map<String, String>> readAll() async => Map.of(values);
}

final class _Harness {
  _Harness({bool controlsInstalled = true}) {
    root = Directory.systemTemp.createTempSync('c2d1-integration-');
    keys = ReadCacheKeyStore(storage);
    files = ReadCacheFileStore(root: () async => root, clock: () => _now);
    coordinator = ReadCacheDiskCoordinator(
      keys: keys,
      files: files,
      settings: ReadCacheSettingsStore(storage),
      coordinationScope: Object(),
      controlsInstalled: controlsInstalled,
      clock: () => _now,
    );
  }

  final storage = _Storage();
  late final Directory root;
  late final ReadCacheKeyStore keys;
  late final ReadCacheFileStore files;
  late ReadCacheDiskCoordinator coordinator;
  final clients = <GitLabApi>[];

  Future<void> restart() async {
    for (final api in clients) {
      api.close();
    }
    clients.clear();
    await coordinator.quiesced;
    coordinator = ReadCacheDiskCoordinator(
      keys: keys,
      files: files,
      settings: ReadCacheSettingsStore(storage),
      coordinationScope: Object(),
      controlsInstalled: true,
      clock: () => _now,
    );
    await recover();
  }

  Future<void> recover() async {
    expect(
      await coordinator.recover(
        ReadCacheStartupDecision(
          operationTicket: 1,
          accountListRevision: 1,
          accountsReadable: true,
          signOutMarkerReadable: true,
          lastActiveReadable: true,
          signOutPending: false,
          resumeAccountKey: _account,
        ),
        accountKeys: {_account},
      ),
      isTrue,
    );
  }

  Future<GitLabApi> client(
    int generation,
    FakeAdapter adapter, {
    bool ready = true,
    FakeAdapter? tokenAdapter,
  }) async {
    final binding = DiskBinding(accountKey: _account, generation: generation);
    expect(await coordinator.activate(binding), ready);
    final api = GitLabApi(
      instance: _instance,
      token: tokenAdapter == null ? 'synthetic-test-token' : null,
      credential: tokenAdapter == null
          ? null
          : const OAuthCredential(
              accessToken: 'old',
              refreshToken: 'refresh',
              clientId: 'test',
            ),
      oauth: tokenAdapter == null
          ? null
          : OAuthTokenClient(
              instance: _instance,
              clientId: 'test',
              dio: Dio()..httpClientAdapter = tokenAdapter,
            ),
      dio: Dio()..httpClientAdapter = adapter,
      readCacheClock: () => _now,
    );
    api.bindReadCache(_account, generation);
    api.attachReadCacheDiskBackend(
      CoordinatedReadCacheDiskBackend(
        coordinator: coordinator,
        binding: binding,
      ),
    );
    clients.add(api);
    return api;
  }

  Future<ProjectedDiskEntry?> entry(Uri uri, String accept) async {
    final key = await keys.readKey(_account);
    expect(key.isFound, isTrue);
    final durable = readCacheDurableKey(
      binding: DiskBinding(accountKey: _account, generation: 1),
      instance: _instance,
      uri: uri,
      logicalAccept: accept,
    );
    expect(durable, isNotNull);
    return files.readEntry(_account, key.value, durable!);
  }

  Future<void> dispose() async {
    for (final api in clients.reversed) {
      api.close();
    }
    await coordinator.quiesced;
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

Map<String, Object?> _issue({int project = 1, int iid = 2}) => {
  'id': 100 + iid,
  'iid': iid,
  'project_id': project,
  'title': 'Issue $iid',
  'confidential': false,
  'assignee': null,
  'milestone': null,
  'closed_at': null,
  'due_date': null,
  'references': {'short': '#$iid', 'relative': '#$iid', 'full': 'g/p#$iid'},
  'labels': [_label()],
  'private_token': 'must-strip',
};

Map<String, Object?> _mr() => {
  'id': 203,
  'iid': 3,
  'project_id': 1,
  'title': 'Merge request',
  'assignee': null,
  'milestone': null,
  'merged_at': null,
  'closed_at': null,
  'merge_user': null,
  'merge_when_pipeline_succeeds': true,
  'auto_merge_enabled': false,
  'references': {'short': '!3', 'relative': '!3', 'full': 'g/p!3'},
  'labels': [_label()],
  'private_token': 'must-strip',
};

Map<String, Object?> _label() => {
  'id': 5,
  'name': 'bug',
  'color': '#f00',
  'text_color': '#FFFFFF',
  'description': 'must-strip',
  'extra': true,
};

Map<String, Object?> _note() => {
  'id': 5,
  'body': 'public note',
  'internal': false,
  'confidential': false,
  'private_token': 'must-strip',
};

final class _Case {
  const _Case(
    this.name,
    this.path,
    this.value, {
    this.page = false,
    this.query = const {},
    this.parentIssue = false,
    this.parentMr = false,
    this.sha = false,
    this.expectedIssues = const {},
  });
  final String name;
  final List<String> path;
  final Object value;
  final bool page, parentIssue, parentMr, sha;
  final Map<String, String> query;
  final Set<ReadCacheIssueIdentity> expectedIssues;
  Uri get uri =>
      _instance.api(path, page ? {'per_page': '30', ...query} : query);
}

final _cases = <_Case>[
  _Case('E01 project list', ['projects'], [projectJson(1)], page: true),
  _Case(
    'E01 project detail',
    ['projects', '1'],
    projectJson(1),
    query: const {'license': 'true'},
  ),
  _Case(
    'E02 issue list',
    ['issues'],
    [_issue()],
    page: true,
    query: const {'with_labels_details': 'true'},
    expectedIssues: {ReadCacheIssueIdentity(1, 2)},
  ),
  _Case(
    'E03 issue',
    ['projects', '1', 'issues', '2'],
    _issue(),
    expectedIssues: {ReadCacheIssueIdentity(1, 2)},
  ),
  _Case(
    'E04 issue note',
    ['projects', '1', 'issues', '2', 'notes', '5'],
    _note(),
    parentIssue: true,
    expectedIssues: {ReadCacheIssueIdentity(1, 2)},
  ),
  _Case(
    'E05 issue discussion',
    ['projects', '1', 'issues', '2', 'discussions', 'thread'],
    {
      'id': 'thread',
      'individual_note': false,
      'notes': [_note()],
    },
    parentIssue: true,
    expectedIssues: {ReadCacheIssueIdentity(1, 2)},
  ),
  _Case(
    'E06 emoji',
    ['projects', '1', 'issues', '2', 'award_emoji'],
    [
      {
        'id': 1,
        'name': 'thumbsup',
        'user': {'id': 1, 'username': 'user1', 'name': 'User 1'},
      },
    ],
    page: true,
    parentIssue: true,
    expectedIssues: {ReadCacheIssueIdentity(1, 2)},
  ),
  _Case(
    'E07 related MR',
    ['projects', '1', 'issues', '2', 'related_merge_requests'],
    [
      {
        ..._mr(),
        'issues': [_issue(project: 2, iid: 7)],
      },
    ],
    page: true,
    parentIssue: true,
    expectedIssues: {
      ReadCacheIssueIdentity(1, 2),
      ReadCacheIssueIdentity(2, 7),
    },
  ),
  _Case(
    'E08 links',
    ['projects', '1', 'issues', '2', 'links'],
    [
      {
        ..._issue(project: 2, iid: 8),
        'issue_link_id': 4,
        'link_type': 'relates_to',
      },
    ],
    page: true,
    parentIssue: true,
    expectedIssues: {
      ReadCacheIssueIdentity(1, 2),
      ReadCacheIssueIdentity(2, 8),
    },
  ),
  _Case(
    'E09 MR list',
    ['merge_requests'],
    [_mr()],
    page: true,
    query: const {'with_labels_details': 'true'},
  ),
  _Case('E10 MR', ['projects', '1', 'merge_requests', '3'], _mr()),
  _Case(
    'E11 approvals',
    ['projects', '1', 'merge_requests', '3', 'approvals'],
    {
      'id': 203,
      'iid': 3,
      'project_id': 1,
      'approvals_required': 1,
      'approvals_left': 1,
      'approved_by': <Object>[],
    },
    parentMr: true,
  ),
  _Case('E12 MR note', [
    'projects',
    '1',
    'merge_requests',
    '3',
    'notes',
    '5',
  ], _note()),
  _Case(
    'E13 MR discussion',
    ['projects', '1', 'merge_requests', '3', 'discussions', 'thread'],
    {
      'id': 'thread',
      'individual_note': false,
      'notes': [_note()],
    },
  ),
  _Case(
    'E14 pipeline',
    ['projects', '1', 'pipelines', '6'],
    {'id': 6, 'project_id': 1, 'status': 'success', 'name': null},
  ),
  _Case(
    'E15 job',
    ['projects', '1', 'jobs', '9'],
    {'id': 9, 'name': 'test', 'status': 'success'},
  ),
  _Case(
    'E16 tree',
    ['projects', '1', 'repository', 'tree'],
    [
      {
        'id': _sha,
        'name': 'README.md',
        'type': 'blob',
        'path': 'README.md',
        'mode': '100644',
        'extra': 'must-strip',
      },
    ],
    page: true,
    sha: true,
    query: const {'ref': _sha},
  ),
  _Case(
    'E17 file metadata',
    ['projects', '1', 'repository', 'files', 'README.md'],
    {
      'file_name': 'README.md',
      'file_path': 'README.md',
      'size': 2,
      'encoding': 'base64',
      'content': 'b2s=',
      'ref': _sha,
      'download_url': 'must-strip',
    },
    sha: true,
    query: const {'ref': _sha},
  ),
];

Map<String, Object?> _expectedIssue({int project = 1, int iid = 2}) => {
  'id': 100 + iid,
  'iid': iid,
  'project_id': project,
  'title': 'Issue $iid',
  'confidential': false,
  'assignee': null,
  'milestone': null,
  'closed_at': null,
  'due_date': null,
  'references': {'short': '#$iid', 'relative': '#$iid', 'full': 'g/p#$iid'},
  'labels': [
    {'id': 5, 'name': 'bug', 'color': '#f00', 'text_color': '#FFFFFF'},
  ],
};

Map<String, Object?> _expectedMr() => {
  'id': 203,
  'iid': 3,
  'project_id': 1,
  'title': 'Merge request',
  'assignee': null,
  'milestone': null,
  'merged_at': null,
  'closed_at': null,
  'merge_user': null,
  'merge_when_pipeline_succeeds': true,
  'auto_merge_enabled': false,
  'references': {'short': '!3', 'relative': '!3', 'full': 'g/p!3'},
  'labels': [
    {'id': 5, 'name': 'bug', 'color': '#f00', 'text_color': '#FFFFFF'},
  ],
};

Map<String, Object?> _expectedNote() => {
  'id': 5,
  'body': 'public note',
  'internal': false,
  'confidential': false,
};

Object _expectedBody(_Case c) {
  final value = switch (c.name) {
    'E01 project list' => [projectJson(1)],
    'E01 project detail' => projectJson(1),
    'E02 issue list' => [_expectedIssue()],
    'E03 issue' => _expectedIssue(),
    'E04 issue note' || 'E12 MR note' => _expectedNote(),
    'E05 issue discussion' || 'E13 MR discussion' => {
      'id': 'thread',
      'individual_note': false,
      'notes': [_expectedNote()],
    },
    'E06 emoji' => [
      {
        'id': 1,
        'name': 'thumbsup',
        'user': {'id': 1, 'username': 'user1', 'name': 'User 1'},
      },
    ],
    'E07 related MR' => [
      {
        ..._expectedMr(),
        'issues': [_expectedIssue(project: 2, iid: 7)],
      },
    ],
    'E08 links' => [
      {
        ..._expectedIssue(project: 2, iid: 8),
        'issue_link_id': 4,
        'link_type': 'relates_to',
      },
    ],
    'E09 MR list' => [_expectedMr()],
    'E10 MR' => _expectedMr(),
    'E11 approvals' => {
      'id': 203,
      'iid': 3,
      'project_id': 1,
      'approvals_required': 1,
      'approvals_left': 1,
      'approved_by': <Object>[],
    },
    'E14 pipeline' => {
      'id': 6,
      'project_id': 1,
      'status': 'success',
      'name': null,
    },
    'E15 job' => {'id': 9, 'name': 'test', 'status': 'success'},
    'E16 tree' => [
      {
        'id': _sha,
        'name': 'README.md',
        'type': 'blob',
        'path': 'README.md',
        'mode': '100644',
      },
    ],
    'E17 file metadata' => {
      'file_name': 'README.md',
      'file_path': 'README.md',
      'size': 2,
      'encoding': 'base64',
      'content': 'b2s=',
      'ref': _sha,
    },
    _ => throw StateError('Unknown fixture ${c.name}'),
  };
  return c.page ? {'items': value, 'next': null} : value;
}

Future<void> _prerequisites(GitLabApi api, _Case c) async {
  if (c.parentIssue) {
    await api.cachedRecord(['projects', '1', 'issues', '2'], allowDisk: false);
  }
  if (c.parentMr) {
    await api.cachedRecord([
      'projects',
      '1',
      'merge_requests',
      '3',
    ], allowDisk: false);
  }
  if (c.sha) {
    await api.record(['projects', '1', 'repository', 'branches', 'main']);
  }
}

Future<CachedRead<Object>> _read(
  GitLabApi api,
  _Case c, {
  bool fresh = false,
}) async {
  if (c.page) {
    final result = await api.cachedRecords(
      c.path,
      query: c.query,
      fresh: fresh,
    );
    return result;
  }
  final result = await api.cachedRecord(c.path, query: c.query, fresh: fresh);
  return result;
}

FakeAdapter _adapter(
  _Case c, {
  Object? Function()? body,
  bool noStore = false,
}) => FakeAdapter((request) {
  if (request.uri.path.endsWith('/repository/branches/main')) {
    return jsonResponse({
      'commit': {'id': _sha},
    });
  }
  if (c.parentIssue && request.uri.path.endsWith('/projects/1/issues/2')) {
    return jsonResponse(_issue());
  }
  if (c.parentMr && request.uri.path.endsWith('/projects/1/merge_requests/3')) {
    return jsonResponse(_mr());
  }
  return jsonResponse(
    body?.call() ?? c.value,
    headers: noStore
        ? {
            'cache-control': ['no-store'],
          }
        : const {},
  );
});

void main() {
  for (final c in _cases) {
    test(
      '${c.name}: network -> encrypted entry -> new-generation hydrate',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await h.recover();
        final firstAdapter = _adapter(c);
        final first = await h.client(1, firstAdapter);
        await _prerequisites(first, c);
        final network = await _read(first, c);
        expect(network.lineage, CacheLineage.network);
        await h.coordinator.flush(
          DiskBinding(accountKey: _account, generation: 1),
        );
        final entry = await h.entry(c.uri, 'application/json');
        expect(entry, isNotNull, reason: c.name);
        expect(entry!.issueIdentities, c.expectedIssues);
        expect(
          entry.body,
          _expectedBody(c),
          reason: '${c.name}: exact projection',
        );
        expect(entry.fetchedAt, _now);
        expect(jsonEncode(entry.body), isNot(contains('must-strip')));
        final key = (await h.keys.readKey(_account)).value!;
        final fileName = await const ReadCacheCipher().entryFileName(
          key,
          entry.canonicalKey,
        );
        final index = await h.files.readIndex(_account, key);
        expect(index, isNotNull);
        final indexed = index!.entries.singleWhere(
          (item) => item.fileName == fileName,
        );
        expect(indexed.issueIdentities, c.expectedIssues);
        final ciphertext = File(
          '${h.root.path}/read_cache/'
          '${ReadCacheCipher.accountDirectoryName(_account)}/$fileName',
        ).readAsBytesSync();
        expect(
          utf8.decode(ciphertext, allowMalformed: true),
          isNot(contains('Merge request')),
        );

        final secondAdapter = _adapter(c);
        final second = await h.client(2, secondAdapter);
        await _prerequisites(second, c);
        await h.coordinator.flush(
          DiskBinding(accountKey: _account, generation: 2),
        );
        final control = await h.coordinator.lookup(
          DiskLookup(
            binding: DiskBinding(accountKey: _account, generation: 2),
            canonicalKey: entry.canonicalKey,
            lease: _Lease(),
          ),
        );
        expect(control, isNotNull, reason: '${c.name}: coordinator lookup');
        final before = secondAdapter.requests.length;
        final hydrated = await _read(second, c);
        expect(hydrated.lineage, CacheLineage.disk, reason: c.name);
        expect(hydrated.fetchedAt, network.fetchedAt);
        expect(hydrated.stale, !c.sha, reason: c.name);
        expect(secondAdapter.requests.length, before, reason: c.name);
        expect(h.coordinator.stats.queuedEntries, 0);
      },
    );
  }

  for (final mr in [false, true]) {
    for (final labels in <List<Object?>>[
      [_label()],
      ['bug', 'urgent'],
    ]) {
      test(
        '${mr ? 'E09 MR' : 'E02 issue'} detailed request hydrates '
        '${labels.first is String ? 'string' : 'object'} labels and nulls',
        () async {
          final h = _Harness();
          addTearDown(h.dispose);
          await h.recover();
          final row = (mr ? _mr() : _issue())..['labels'] = labels;
          final c = _Case(
            'labels',
            [mr ? 'merge_requests' : 'issues'],
            [row],
            page: true,
            query: const {'with_labels_details': 'true'},
          );
          final first = await h.client(1, _adapter(c));
          await _read(first, c);
          await h.coordinator.flush(
            DiskBinding(accountKey: _account, generation: 1),
          );
          final entry = await h.entry(c.uri, 'application/json');
          expect(entry, isNotNull);
          final item = ((entry!.body as Map)['items'] as List).single as Map;
          expect(
            item['labels'],
            labels.first is String
                ? labels
                : [
                    {
                      'id': 5,
                      'name': 'bug',
                      'color': '#f00',
                      'text_color': '#FFFFFF',
                    },
                  ],
          );
          expect(item['assignee'], isNull);
          expect(item['milestone'], isNull);
          if (mr) {
            expect(item['merge_user'], isNull);
            expect(item['merged_at'], isNull);
            expect(item['merge_when_pipeline_succeeds'], isTrue);
            expect(item['auto_merge_enabled'], isFalse);
          } else {
            expect(item['closed_at'], isNull);
            expect(item['due_date'], isNull);
          }
          expect(item['references'], row['references']);
          final adapter = _adapter(c);
          final second = await h.client(2, adapter);
          final hydrated = await _read(second, c);
          expect(hydrated.lineage, CacheLineage.disk);
          expect(hydrated.stale, isTrue);
          expect(adapter.requests, isEmpty);
          final page = hydrated.value as ApiPage<Json>;
          expect(page.items.single, item);
        },
      );
    }

    for (final invalid in <Object?>[
      ['bug', _label()],
      [_label(), null],
      [
        {'id': 5, 'name': 'bug', 'text_color': '#FFFFFF'},
      ],
      [
        {..._label(), 'color': 123},
      ],
    ]) {
      test('${mr ? 'E09 MR' : 'E02 issue'} rejects invalid labels and '
          'removes the earlier disk value', () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await h.recover();
        final row = mr ? _mr() : _issue();
        final c = _Case(
          'labels',
          [mr ? 'merge_requests' : 'issues'],
          [row],
          page: true,
          query: const {'with_labels_details': 'true'},
        );
        final first = await h.client(1, _adapter(c));
        await _read(first, c);
        final binding = DiskBinding(accountKey: _account, generation: 1);
        await h.coordinator.flush(binding);
        expect(await h.entry(c.uri, 'application/json'), isNotNull);

        row['labels'] = invalid;
        expect(
          (await _read(first, c, fresh: true)).lineage,
          CacheLineage.network,
        );
        await h.coordinator.quiesced;
        await h.coordinator.flush(binding);
        expect(await h.entry(c.uri, 'application/json'), isNull);
      });
    }
  }

  test('E16 typed tree writes to disk and hydrates a new client', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.recover();
    final treeCase = _cases.firstWhere((c) => c.name == 'E16 tree');
    final first = await h.client(1, _adapter(treeCase));
    await _prerequisites(first, treeCase);
    expect((await first.tree(1, _sha)).items.single.name, 'README.md');
    await h.coordinator.flush(DiskBinding(accountKey: _account, generation: 1));
    final uri = _instance.api(
      ['projects', '1', 'repository', 'tree'],
      {'ref': _sha, 'path': '', 'per_page': '50'},
    );
    expect(await h.entry(uri, 'application/json'), isNotNull);
    final adapter = _adapter(treeCase);
    final second = await h.client(2, adapter);
    await _prerequisites(second, treeCase);
    final before = adapter.requests.length;
    expect((await second.tree(1, _sha)).items.single.name, 'README.md');
    expect(adapter.requests.length, before);
  });

  test(
    'E17 JSON and text Accept variants hydrate distinct encrypted files',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      final fileCase = _cases.firstWhere((c) => c.name == 'E17 file metadata');
      FakeAdapter adapter() => FakeAdapter((request) {
        if (request.uri.path.endsWith('/repository/branches/main')) {
          return jsonResponse({
            'commit': {'id': _sha},
          });
        }
        if (request.method == 'HEAD') {
          return ResponseBody.fromString(
            '',
            200,
            headers: {
              'x-gitlab-size': ['2'],
            },
          );
        }
        if (request.uri.path.endsWith('/raw')) {
          return ResponseBody.fromString('ok', 200);
        }
        return jsonResponse(fileCase.value);
      });
      final first = await h.client(1, adapter());
      await _prerequisites(first, fileCase);
      expect((await _read(first, fileCase)).lineage, CacheLineage.network);
      expect(await first.textFile(1, _sha, 'README.md'), 'ok');
      await h.coordinator.flush(
        DiskBinding(accountKey: _account, generation: 1),
      );
      final jsonEntry = await h.entry(fileCase.uri, 'application/json');
      final textEntry = await h.entry(fileCase.uri, 'text/plain');
      expect(jsonEntry, isNotNull);
      expect(textEntry, isNotNull);
      expect(jsonEntry!.canonicalKey, isNot(textEntry!.canonicalKey));
      expect(textEntry.body, 'ok');
      expect(jsonEntry.bodyKind, ReadCacheBodyKind.json);
      expect(textEntry.bodyKind, ReadCacheBodyKind.text);

      final secondAdapter = adapter();
      final second = await h.client(2, secondAdapter);
      await _prerequisites(second, fileCase);
      final before = secondAdapter.requests.length;
      expect((await _read(second, fileCase)).lineage, CacheLineage.disk);
      expect(await second.textFile(1, _sha, 'README.md'), 'ok');
      expect(secondAdapter.requests.length, before);
    },
  );

  for (final noStore in [true, false]) {
    test(
      '${noStore ? 'no-store' : 'oversized response'} deletes exact old key',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await h.recover();
        final row = _issue();
        var reject = false;
        final c = _Case('issues', ['issues'], [row], page: true);
        final adapter = FakeAdapter(
          (request) => jsonResponse(
            [row],
            headers: reject && noStore
                ? {
                    'cache-control': ['private, NO-STORE'],
                  }
                : const {},
          ),
        );
        final api = await h.client(1, adapter);
        final binding = DiskBinding(accountKey: _account, generation: 1);
        await _read(api, c);
        await h.coordinator.flush(binding);
        expect(await h.entry(c.uri, 'application/json'), isNotNull);
        reject = true;
        if (!noStore) row['description'] = 'x' * (1024 * 1024 + 1);
        await _read(api, c, fresh: true);
        await h.coordinator.quiesced;
        await h.coordinator.flush(binding);
        expect(await h.entry(c.uri, 'application/json'), isNull);
      },
    );
  }

  test('privacy flip deletes identity across encrypted scopes', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.recover();
    var confidential = false;
    final cases = [
      _cases.firstWhere((c) => c.name == 'E02 issue list'),
      _cases.firstWhere((c) => c.name == 'E03 issue'),
      _cases.firstWhere((c) => c.name == 'E04 issue note'),
      _Case('group', ['groups', '3', 'issues'], [_issue()], page: true),
      _Case(
        'project list',
        ['projects', '1', 'issues'],
        [_issue()],
        page: true,
      ),
    ];
    final adapter = FakeAdapter((request) {
      final path = request.uri.path;
      if (path.endsWith('/notes/5')) return jsonResponse(_note());
      final row = _issue()..['confidential'] = confidential;
      if (path.endsWith('/issues/2')) return jsonResponse(row);
      return jsonResponse([row]);
    });
    final api = await h.client(1, adapter);
    final binding = DiskBinding(accountKey: _account, generation: 1);
    for (final c in cases) {
      await _read(api, c);
    }
    await h.coordinator.flush(binding);
    for (final c in cases) {
      expect(
        await h.entry(c.uri, 'application/json'),
        isNotNull,
        reason: c.name,
      );
    }
    confidential = true;
    await api.record(['projects', '1', 'issues', '2']);
    await h.coordinator.quiesced;
    await h.coordinator.flush(binding);
    for (final c in cases) {
      expect(await h.entry(c.uri, 'application/json'), isNull, reason: c.name);
    }
  });

  for (final status in [403, 404]) {
    test(
      'REST $status removes project disk entry but preserves another project',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await h.recover();
        var reject = false;
        final adapter = FakeAdapter((request) {
          if (request.uri.path.endsWith('/projects/1') && reject) {
            return jsonResponse({}, status: status);
          }
          return jsonResponse(
            projectJson(request.uri.path.endsWith('/projects/1') ? 1 : 2),
          );
        });
        final api = await h.client(1, adapter);
        final binding = DiskBinding(accountKey: _account, generation: 1);
        final a = _Case('a', ['projects', '1'], projectJson(1));
        final b = _Case('b', ['projects', '2'], projectJson(2));
        await _read(api, a);
        await _read(api, b);
        await h.coordinator.flush(binding);
        expect(await h.entry(a.uri, 'application/json'), isNotNull);
        expect(await h.entry(b.uri, 'application/json'), isNotNull);
        reject = true;
        await expectLater(
          _read(api, a, fresh: true),
          throwsA(
            isA<ApiFailure>().having(
              (e) => e.kind,
              'kind',
              status == 403 ? FailureKind.forbidden : FailureKind.invisible,
            ),
          ),
        );
        await h.coordinator.quiesced;
        await h.coordinator.flush(binding);
        expect(await h.entry(a.uri, 'application/json'), isNull);
        expect(await h.entry(b.uri, 'application/json'), isNotNull);
      },
    );
  }

  for (final route in ['currentUser', 'raw file', 'artifact', 'upload']) {
    test(
      'bound terminal 401 from $route removes key and account files',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await h.recover();
        var fail = false;
        final c = _cases.firstWhere((c) => c.name == 'E02 issue list');
        final adapter = FakeAdapter(
          (request) =>
              fail ? jsonResponse({}, status: 401) : jsonResponse(c.value),
        );
        final api = await h.client(1, adapter);
        final binding = DiskBinding(accountKey: _account, generation: 1);
        await _read(api, c);
        await h.coordinator.flush(binding);
        expect(await h.entry(c.uri, 'application/json'), isNotNull);
        fail = true;
        final sink = route == 'artifact' || route == 'upload'
            ? File('${h.root.path}/synthetic-download.tmp').openWrite()
            : null;
        final operation = switch (route) {
          'raw file' => api.rawFileBytes('1', 'main', 'a.txt'),
          'artifact' => api.downloadJobArtifacts(1, 9, sink: sink!),
          'upload' => api.downloadProjectUpload(
            1,
            'a' * 32,
            'test.txt',
            sink: sink!,
          ),
          _ => api.currentUser(),
        };
        await expectLater(
          operation,
          throwsA(
            isA<ApiFailure>().having(
              (e) => e.kind,
              'kind',
              FailureKind.unauthenticated,
            ),
          ),
        );
        await sink?.close();
        expect((await h.keys.readKey(_account)).isFound, isFalse);
        expect(
          Directory(
            '${h.root.path}/read_cache/${ReadCacheCipher.accountDirectoryName(_account)}',
          ).existsSync(),
          isFalse,
        );
      },
    );
  }

  test(
    'successful OAuth refresh preserves encrypted snapshot and hydrates it',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      final c = _cases.firstWhere((c) => c.name == 'E02 issue list');
      var issueCalls = 0;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/issues/9')) {
          issueCalls++;
          return issueCalls == 1
              ? jsonResponse({}, status: 401)
              : jsonResponse(_issue(iid: 9));
        }
        return jsonResponse(c.value);
      });
      final tokens = FakeAdapter(
        (_) => jsonResponse({
          'access_token': 'new',
          'refresh_token': 'new-refresh',
          'token_type': 'bearer',
        }),
      );
      final api = await h.client(1, adapter, tokenAdapter: tokens);
      final binding = DiskBinding(accountKey: _account, generation: 1);
      await _read(api, c);
      await h.coordinator.flush(binding);
      final entry = (await h.entry(c.uri, 'application/json'))!;
      final key = (await h.keys.readKey(_account)).value!;
      final name = await const ReadCacheCipher().entryFileName(
        key,
        entry.canonicalKey,
      );
      final file = File(
        '${h.root.path}/read_cache/${ReadCacheCipher.accountDirectoryName(_account)}/$name',
      );
      final bytes = file.readAsBytesSync();
      await api.record(['projects', '1', 'issues', '9']);
      await h.coordinator.quiesced;
      expect((await h.keys.readKey(_account)).value, key);
      expect(file.readAsBytesSync(), bytes);
      expect(tokens.requests, hasLength(1));
      final secondAdapter = _adapter(c);
      final second = await h.client(2, secondAdapter);
      expect((await _read(second, c)).lineage, CacheLineage.disk);
      expect(secondAdapter.requests, isEmpty);
    },
  );

  test(
    'pending publication is revoked by a confidential observation',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      var confidential = false;
      final c = _cases.firstWhere((c) => c.name == 'E02 issue list');
      final adapter = FakeAdapter((request) {
        final row = _issue()..['confidential'] = confidential;
        return jsonResponse(
          request.uri.path.endsWith('/issues/2') ? row : [row],
        );
      });
      final api = await h.client(1, adapter);
      final binding = DiskBinding(accountKey: _account, generation: 1);
      await _read(api, c);
      expect(h.coordinator.stats.queuedEntries, greaterThan(0));
      confidential = true;
      await api.record(['projects', '1', 'issues', '2']);
      await h.coordinator.quiesced;
      await h.coordinator.flush(binding);
      expect(await h.entry(c.uri, 'application/json'), isNull);
    },
  );

  for (final status in [200, 403, 503]) {
    test(
      'mutation $status durably deletes affected entries and retains unrelated project',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await h.recover();
        final a = _Case('issue a', ['projects', '1', 'issues', '2'], _issue());
        final b = _Case('issue b', [
          'projects',
          '2',
          'issues',
          '3',
        ], _issue(project: 2, iid: 3));
        final adapter = FakeAdapter((request) {
          if (request.method == 'PUT') {
            if (status == 503) {
              throw DioException(
                requestOptions: request,
                type: DioExceptionType.connectionError,
              );
            }
            return jsonResponse(_issue(), status: status);
          }
          return jsonResponse(
            request.uri.path.contains('/projects/1/') ? a.value : b.value,
          );
        });
        final api = await h.client(1, adapter);
        final binding = DiskBinding(accountKey: _account, generation: 1);
        await _read(api, a);
        await _read(api, b);
        await h.coordinator.flush(binding);
        expect(await h.entry(a.uri, 'application/json'), isNotNull);
        expect(await h.entry(b.uri, 'application/json'), isNotNull);
        if (status == 200) {
          await api.updateIssue(1, 2, {'title': 'changed'});
        } else {
          await expectLater(
            api.updateIssue(1, 2, {'title': 'changed'}),
            throwsA(
              isA<ApiFailure>().having(
                (e) => e.kind,
                'kind',
                status == 403
                    ? FailureKind.forbidden
                    : FailureKind.writeUncertain,
              ),
            ),
          );
        }
        await h.coordinator.quiesced;
        await h.restart();
        final secondAdapter = FakeAdapter(
          (request) => jsonResponse(
            request.uri.path.contains('/projects/1/') ? a.value : b.value,
          ),
        );
        final second = await h.client(2, secondAdapter);
        expect((await _read(second, b)).lineage, CacheLineage.disk);
        expect(secondAdapter.requests, isEmpty);
        expect((await _read(second, a)).lineage, CacheLineage.network);
        expect(secondAdapter.requests, hasLength(1));
      },
    );
  }

  test('corrupt index clears the whole account before mutation', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.recover();
    final c = _cases.firstWhere((c) => c.name == 'E03 issue');
    final first = await h.client(1, _adapter(c));
    await _read(first, c);
    await h.coordinator.flush(DiskBinding(accountKey: _account, generation: 1));
    expect(await h.entry(c.uri, 'application/json'), isNotNull);
    final index = File(
      '${h.root.path}/read_cache/${ReadCacheCipher.accountDirectoryName(_account)}/index.v1.bin',
    );
    index.writeAsBytesSync([1, 2, 3]);
    await h.restart();
    final adapter = FakeAdapter((request) => jsonResponse(_issue()));
    final second = await h.client(2, adapter);
    await second.updateIssue(1, 2, {'title': 'changed'});
    await h.coordinator.quiesced;
    expect((await h.keys.readKey(_account)).isFound, isFalse);
    expect(Directory(index.parent.path).existsSync(), isFalse);
  });

  test('privacy revokes an entry renamed before index commit', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.recover();
    final events = ReceivePort();
    addTearDown(events.close);
    final messages = StreamIterator<Object?>(events);
    final release = File('${h.root.path}/release');
    var confidential = false;
    final c = _cases.firstWhere((c) => c.name == 'E02 issue list');
    final adapter = FakeAdapter((request) {
      final row = _issue()..['confidential'] = confidential;
      return jsonResponse(request.uri.path.endsWith('/issues/2') ? row : [row]);
    });
    final api = await h.client(1, adapter);
    final binding = DiskBinding(accountKey: _account, generation: 1);
    await _read(api, c);
    h.coordinator.configure(
      keys: h.keys,
      settings: ReadCacheSettingsStore(h.storage),
      files: ReadCacheFileStore(
        root: () async => h.root,
        clock: () => _now,
        checkpoint: _pauseIndex(events.sendPort, release.path),
      ),
    );
    final flushing = h.coordinator.flush(binding);
    expect(
      await messages.moveNext().timeout(const Duration(seconds: 10)),
      isTrue,
    );
    expect(await h.entry(c.uri, 'application/json'), isNotNull);
    confidential = true;
    final privacy = api.record(['projects', '1', 'issues', '2']);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    release.createSync();
    await flushing;
    await privacy;
    await h.coordinator.quiesced;
    await messages.cancel();
    expect(await h.entry(c.uri, 'application/json'), isNull);
  });

  for (final status in [403, 404]) {
    test('GraphQL $status preserves encrypted REST data', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      final c = _cases.firstWhere((c) => c.name == 'E03 issue');
      final adapter = FakeAdapter(
        (request) => request.uri.path.endsWith('/api/graphql')
            ? jsonResponse({}, status: status)
            : jsonResponse(c.value),
      );
      final api = await h.client(1, adapter);
      await _read(api, c);
      await h.coordinator.flush(
        DiskBinding(accountKey: _account, generation: 1),
      );
      await expectLater(
        api.pipelineGraphPage(
          const Project(
            id: 1,
            name: 'P',
            path: 'g/p',
            visibility: 'private',
            defaultBranch: 'main',
          ),
          1,
        ),
        throwsA(
          isA<ApiFailure>().having(
            (e) => e.kind,
            'kind',
            status == 403 ? FailureKind.forbidden : FailureKind.invisible,
          ),
        ),
      );
      await h.coordinator.quiesced;
      expect(await h.entry(c.uri, 'application/json'), isNotNull);
    });
  }

  test(
    'GraphQL mutation deletes mutable disk data while preserving confirmed SHA',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      final issue = _cases.firstWhere((c) => c.name == 'E03 issue');
      final tree = _cases.firstWhere((c) => c.name == 'E16 tree');
      final until = DateTime.now().toUtc().add(const Duration(days: 1));
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/api/graphql')) {
          return jsonResponse({
            'data': {
              'todoSnooze': {
                'errors': <Object?>[],
                'todo': {
                  'id': 'gid://gitlab/Todo/1',
                  'snoozedUntil': until.toIso8601String(),
                },
              },
            },
          });
        }
        if (request.uri.path.endsWith('/repository/branches/main')) {
          return jsonResponse({
            'commit': {'id': _sha},
          });
        }
        return jsonResponse(
          request.uri.path.endsWith('/repository/tree')
              ? tree.value
              : issue.value,
        );
      });
      final api = await h.client(1, adapter);
      await _read(api, issue);
      await _prerequisites(api, tree);
      await _read(api, tree);
      await h.coordinator.flush(
        DiskBinding(accountKey: _account, generation: 1),
      );
      expect(await h.entry(issue.uri, 'application/json'), isNotNull);
      expect(await h.entry(tree.uri, 'application/json'), isNotNull);
      await api.snoozeTodo(1, until);
      await h.coordinator.quiesced;
      expect(await h.entry(issue.uri, 'application/json'), isNull);
      expect(await h.entry(tree.uri, 'application/json'), isNotNull);
    },
  );

  test(
    'full-path network project detail persists numeric alias across clients',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      final adapter = FakeAdapter(
        (request) => jsonResponse({
          ...projectJson(1),
          'path_with_namespace': 'team/original',
        }),
      );
      final api = await h.client(1, adapter);
      expect(
        (await api.cachedRecord(['projects', 'team/original'])).lineage,
        CacheLineage.network,
      );
      await h.coordinator.flush(
        DiskBinding(accountKey: _account, generation: 1),
      );
      final numeric = _Case('numeric', ['projects', '1'], projectJson(1));
      expect(await h.entry(numeric.uri, 'application/json'), isNotNull);
      await h.restart();
      final freshAdapter = FakeAdapter((_) => jsonResponse(projectJson(1)));
      final fresh = await h.client(2, freshAdapter);
      expect((await _read(fresh, numeric)).lineage, CacheLineage.disk);
      expect(freshAdapter.requests, isEmpty);
    },
  );

  test(
    'renamed project path cannot hydrate an old path as another project',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      var renamed = false;
      final adapter = FakeAdapter(
        (request) => jsonResponse({
          ...projectJson(1),
          'path_with_namespace': renamed ? 'team/new' : 'team/old',
        }),
      );
      final api = await h.client(1, adapter);
      await api.cachedRecord(['projects', 'team/old']);
      renamed = true;
      await api.cachedRecord(['projects', '1'], fresh: true);
      final old = await api.cachedRecord(['projects', 'team/old']);
      expect(old.lineage, CacheLineage.network);
      expect(old.value['path_with_namespace'], 'team/new');
    },
  );

  test('closed controls do not queue writes or create keys', () async {
    final h = _Harness(controlsInstalled: false);
    addTearDown(h.dispose);
    await h.recover();
    final c = _cases.firstWhere((c) => c.name == 'E02 issue list');
    final adapter = _adapter(c);
    final api = await h.client(1, adapter, ready: false);
    expect((await _read(api, c)).lineage, CacheLineage.network);
    await h.coordinator.quiesced;
    expect(h.coordinator.stats.queuedEntries, 0);
    expect(h.storage.keyWrites, 0);
    expect((await h.keys.readKey(_account)).isFound, isFalse);
  });
  test(
    'issue children need a fresh network public parent before disk publication',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      final c = _cases.firstWhere((c) => c.name == 'E04 issue note');
      final api = await h.client(1, _adapter(c));
      await _read(api, c);
      await h.coordinator.flush(
        DiskBinding(accountKey: _account, generation: 1),
      );
      expect(await h.entry(c.uri, 'application/json'), isNull);
      expect(h.coordinator.stats.queuedEntries, 0);
      await _prerequisites(api, c);
      await _read(api, c, fresh: true);
      await h.coordinator.flush(
        DiskBinding(accountKey: _account, generation: 1),
      );
      expect(await h.entry(c.uri, 'application/json'), isNotNull);
    },
  );

  test(
    'a nested unsafe discussion note deletes only the earlier exact entry',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      final c = _cases.firstWhere((c) => c.name == 'E05 issue discussion');
      var unsafe = false;
      final api = await h.client(
        1,
        FakeAdapter(
          (r) => jsonResponse(
            r.uri.path.endsWith('/issues/2')
                ? _issue()
                : r.uri.path.endsWith('/projects/3')
                ? projectJson(3)
                : {
                    'id': 'thread',
                    'individual_note': false,
                    'notes': [
                      _note(),
                      {..._note(), 'internal': unsafe},
                    ],
                  },
          ),
        ),
      );
      await _prerequisites(api, c);
      await _read(api, c);
      await api.cachedRecord(['projects', '3']);
      await h.coordinator.flush(
        DiskBinding(accountKey: _account, generation: 1),
      );
      expect(await h.entry(c.uri, 'application/json'), isNotNull);
      unsafe = true;
      await _read(api, c, fresh: true);
      await h.coordinator.quiesced;
      expect(await h.entry(c.uri, 'application/json'), isNull);
      expect(
        await h.entry(
          _instance.api(['projects', '3'], {'license': 'true'}),
          'application/json',
        ),
        isNotNull,
      );
    },
  );

  for (final rejection in ['first privacy', '403', '404']) {
    test(
      '$rejection deletes cross-project links, related MR and list identities',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await h.recover();
        final target = _issue(project: 2, iid: 7);
        final related = _cases.firstWhere((c) => c.name == 'E07 related MR');
        final cases = [
          related,
          _Case(
            'foreign linked',
            ['projects', '1', 'issues', '2', 'links'],
            [
              {...target, 'issue_link_id': 4, 'link_type': 'relates_to'},
            ],
            page: true,
            parentIssue: true,
          ),
          _Case('workspace', ['issues'], [target], page: true),
          _Case('group', ['groups', '9', 'issues'], [target], page: true),
          _Case('project', ['projects', '2', 'issues'], [target], page: true),
        ];
        final routes = {for (final c in cases) c.uri.path: c.value};
        final api = await h.client(
          1,
          FakeAdapter(
            (r) => jsonResponse(
              routes[r.uri.path] ??
                  (r.uri.path.endsWith('/projects/3')
                      ? projectJson(3)
                      : _issue()),
            ),
          ),
        );
        await api.cachedRecord(['projects', '1', 'issues', '2']);
        for (final c in cases) {
          await _read(api, c);
        }
        await api.cachedRecord(['projects', '3']);
        await h.coordinator.flush(
          DiskBinding(accountKey: _account, generation: 1),
        );
        for (final c in cases) {
          expect(
            await h.entry(c.uri, 'application/json'),
            isNotNull,
            reason: c.name,
          );
        }
        await h.restart();
        final fresh = await h.client(
          2,
          FakeAdapter(
            (_) => jsonResponse(
              {...target, 'confidential': true},
              status: rejection == 'first privacy' ? 200 : int.parse(rejection),
            ),
          ),
        );
        if (rejection == 'first privacy') {
          expect(
            (await fresh.record([
              'projects',
              '2',
              'issues',
              '7',
            ]))['confidential'],
            isTrue,
          );
        } else {
          await expectLater(
            fresh.record(['projects', '2', 'issues', '7']),
            throwsA(
              isA<ApiFailure>().having(
                (e) => e.kind,
                'kind',
                rejection == '403'
                    ? FailureKind.forbidden
                    : FailureKind.invisible,
              ),
            ),
          );
        }
        for (final c in cases) {
          expect(
            await h.entry(c.uri, 'application/json'),
            isNull,
            reason: c.name,
          );
        }
        expect(
          await h.entry(
            _instance.api(['projects', '3'], {'license': 'true'}),
            'application/json',
          ),
          isNotNull,
        );
      },
    );
  }
  for (final mr in [false, true]) {
    test(
      'C2-D2 ${mr ? 'E09' : 'E02'} omits invalid colour string and keeps the page',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await h.recover();
        final row = mr ? _mr() : _issue();
        row['labels'] = [
          {..._label(), 'color': 'invalid-colour'},
        ];
        final c = _Case(
          'invalid colour string',
          [mr ? 'merge_requests' : 'issues'],
          [row],
          page: true,
          query: const {'with_labels_details': 'true'},
        );
        final adapter = _adapter(c);
        final api = await h.client(1, adapter);
        await _read(api, c);
        expect(
          adapter.requests.single.uri.queryParameters['with_labels_details'],
          'true',
        );
        await h.coordinator.flush(
          DiskBinding(accountKey: _account, generation: 1),
        );
        final stored = (await h.entry(c.uri, 'application/json'))!;
        final saved = ((stored.body as Map)['items'] as List).single as Map;
        final label = (saved['labels'] as List).single as Map;
        expect(label, {'id': 5, 'name': 'bug', 'text_color': '#FFFFFF'});
        final freshAdapter = _adapter(c);
        final fresh = await h.client(2, freshAdapter);
        final value = await _read(fresh, c);
        expect(value.lineage, CacheLineage.disk);
        expect(value.stale, isTrue);
        expect(freshAdapter.requests, isEmpty);
      },
    );
  }

  test('C2-D4 added-line DiffNote survives encrypted hydration', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.recover();
    final position = {
      'position_type': 'text',
      'old_path': 'a.txt',
      'new_path': 'a.txt',
      'base_sha': _sha,
      'start_sha': _sha,
      'head_sha': _sha,
      'old_line': null,
      'new_line': 20,
      'line_range': {
        'start': {
          'line_code': 'a_20_1',
          'type': null,
          'old_line': null,
          'new_line': 1,
        },
        'end': {
          'line_code': 'a_20_20',
          'type': null,
          'old_line': null,
          'new_line': 20,
        },
      },
    };
    final c = _Case(
      'C2-D4 DiffNote',
      ['projects', '1', 'merge_requests', '3', 'discussions', 'thread'],
      {
        'id': 'thread',
        'individual_note': false,
        'notes': [
          {..._note(), 'position': position},
        ],
      },
    );
    final api = await h.client(1, _adapter(c));
    await _read(api, c);
    await h.coordinator.flush(DiskBinding(accountKey: _account, generation: 1));
    final stored = (await h.entry(c.uri, 'application/json'))!;
    expect((stored.body as Map)['notes'], [
      {..._expectedNote(), 'position': position},
    ]);
    final freshAdapter = _adapter(c);
    final fresh = await h.client(2, freshAdapter);
    final read = await _read(fresh, c);
    expect(read.lineage, CacheLineage.disk);
    expect(read.stale, isTrue);
    expect(read.value, stored.body);
    expect(freshAdapter.requests, isEmpty);
  });

  for (final (status, confidentialSibling, missingConfidential) in [
    (403, false, false),
    (404, false, false),
    (403, true, false),
    (404, true, false),
    (403, false, true),
    (404, false, true),
  ]) {
    test(
      'issue $status fences an in-flight list from republishing deleted encrypted data${confidentialSibling ? ' with a confidential sibling' : ''}${missingConfidential ? ' without a confidential field' : ''}',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await h.recover();
        final held = Completer<ResponseBody>();
        var holdList = false;
        final adapter = FakeAdapter((request) {
          if (request.uri.path.endsWith('/issues/2')) {
            return jsonResponse({}, status: status);
          }
          return holdList ? held.future : jsonResponse([_issue()]);
        });
        final api = await h.client(1, adapter);
        final binding = DiskBinding(accountKey: _account, generation: 1);
        final listUri = _instance.api(
          ['projects', '1', 'issues'],
          {'per_page': '30'},
        );
        await api.cachedRecords(['projects', '1', 'issues']);
        await h.coordinator.flush(binding);
        expect(await h.entry(listUri, 'application/json'), isNotNull);
        holdList = true;
        final pending = api.cachedRecords([
          'projects',
          '1',
          'issues',
        ], fresh: true);
        for (var i = 0; i < 20 && adapter.requests.length < 2; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(adapter.requests, hasLength(2));
        await expectLater(
          api.record(['projects', '1', 'issues', '2']),
          throwsA(isA<ApiFailure>()),
        );
        await h.coordinator.quiesced;
        expect(await h.entry(listUri, 'application/json'), isNull);
        final inFlightIssue = {..._issue()};
        if (missingConfidential) inFlightIssue.remove('confidential');
        held.complete(
          jsonResponse([
            inFlightIssue,
            if (confidentialSibling) {..._issue(iid: 3), 'confidential': true},
          ]),
        );
        await pending;
        await h.coordinator.flush(binding);
        await h.coordinator.quiesced;
        expect(await h.entry(listUri, 'application/json'), isNull);
        holdList = false;
        final priorRequests = adapter.requests.length;
        final retry = await api.cachedRecords(['projects', '1', 'issues']);
        expect(retry.lineage, CacheLineage.network);
        expect(adapter.requests, hasLength(priorRequests + 1));
      },
    );
  }

  test(
    'adapter rejects foreign bindings without changing stored account',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.recover();
      final api = await h.client(
        1,
        FakeAdapter((_) => jsonResponse([_issue()])),
      );
      final binding = DiskBinding(accountKey: _account, generation: 1);
      final foreign = DiskBinding(accountKey: _account, generation: 2);
      final adapter = CoordinatedReadCacheDiskBackend(
        coordinator: h.coordinator,
        binding: binding,
      );
      final uri = _instance.api(
        ['projects', '1', 'issues'],
        {'per_page': '30'},
      );
      await api.cachedRecords(['projects', '1', 'issues']);
      await h.coordinator.flush(binding);
      expect(await h.entry(uri, 'application/json'), isNotNull);
      expect(
        () => adapter.invalidate(
          DiskInvalidation(
            binding: foreign,
            kind: DiskInvalidationKind.account,
          ),
        ),
        throwsArgumentError,
      );
      adapter.revoke(foreign);
      await expectLater(
        adapter.clear(foreign, ReadCacheCleanupOperation.accountRemoval),
        throwsArgumentError,
      );
      expect(await h.entry(uri, 'application/json'), isNotNull);
      final reread = await api.cachedRecords(['projects', '1', 'issues']);
      expect(reread.lineage, CacheLineage.memory);
    },
  );
}
