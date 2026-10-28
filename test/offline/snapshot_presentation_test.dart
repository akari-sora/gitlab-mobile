import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/offline/git_object_id.dart';
import 'package:gitlab_mobile/core/offline/offline_repository_coordinator.dart';
import 'package:gitlab_mobile/core/offline/snapshot_reader.dart';
import 'package:gitlab_mobile/core/offline/snapshot_save.dart';
import 'package:gitlab_mobile/core/offline/snapshot_schema.dart';
import 'package:gitlab_mobile/core/offline/snapshot_store.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/core/repository_reader.dart';
import 'package:gitlab_mobile/features/offline/offline_repositories.dart';
import 'package:gitlab_mobile/shared/markdown_media_source.dart';

import 'coordinator_regression_test.dart' as fixture;

const _binding = DiskBinding(
  accountKey: 'https://example.test#1',
  generation: 1,
);
const _id = '0123456789abcdef0123456789abcdef';
const _sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _format = SnapshotObjectFormat.sha1;
final _date = DateTime.utc(2026, 10, 28);

final class PresentationHarness {
  PresentationHarness(
    this.root,
    this.keys,
    this.owner,
    this.record,
    this.store,
  );
  final Directory root;
  final fixture.MemoryKeys keys;
  final OfflineRepositoryCoordinator owner;
  final SnapshotRecord record;
  final SnapshotStore store;

  static Future<PresentationHarness> create({
    String attributes = '*.txt text eol=lf\n',
    int missing = 1,
    SnapshotEntryState omission = SnapshotEntryState.missing,
    bool attributesSaved = true,
  }) async {
    final scratch = Directory('.dart_tool/c3a2/presentation')
      ..createSync(recursive: true);
    final root = scratch.createTempSync('case.');
    final keys = fixture.MemoryKeys();
    final store = SnapshotStore(
      supportRoot: root,
      accountKey: _binding.accountKey,
      rootKey: Uint8List(32),
    );
    final owner = OfflineRepositoryCoordinator();
    owner.configure(
      keys: keys,
      supportRoot: () async => root,
      deleteDirectory: (_) async {},
    );
    final record = SnapshotRecord(
      id: _id,
      projectId: 42,
      projectPath: 'group/project',
      projectName: 'project',
      defaultBranch: 'main',
      refKind: SnapshotRefKind.branch,
      refName: 'main',
      sha: _sha,
      objectFormat: _format,
      subPath: 'docs',
      commitTitle: 'title',
      committedAt: _date,
      status: SnapshotStatus.complete,
      createdAt: _date,
      savedAt: _date,
      notSaved: {omission: missing},
    );
    final entries = <SnapshotTreeEntry>[];
    Future<void> add(
      String path,
      List<int> content,
      SnapshotContentKind kind, {
      bool saved = true,
    }) async {
      final id = gitBlobId(content, 'sha1');
      if (saved) {
        await store.writeBlob(_format, id, content, mayCommit: () => true);
      }
      entries.add(
        SnapshotTreeEntry(
          path: path,
          type: SnapshotEntryType.blob,
          mode: '100644',
          id: id,
          state: saved ? SnapshotEntryState.saved : SnapshotEntryState.missing,
          kind: saved ? kind : null,
          size: saved ? content.length : null,
        ),
      );
    }

    await add('docs/a.png', <int>[137, 80, 78, 71], SnapshotContentKind.image);
    await add('docs/icon.svg', utf8.encode('<svg/>'), SnapshotContentKind.text);
    await add('docs/plain.txt', utf8.encode('text'), SnapshotContentKind.text);
    await add(
      'docs/missing.png',
      <int>[1],
      SnapshotContentKind.image,
      saved: false,
    );
    await add(
      'docs/.gitattributes',
      utf8.encode(attributes),
      SnapshotContentKind.text,
      saved: attributesSaved,
    );
    await store.writeTree(
      SnapshotTree(
        snapshotId: _id,
        sha: _sha,
        subPath: 'docs',
        entries: entries,
      ),
      format: _format,
      complete: true,
      mayCommit: () => true,
    );
    await store.writeIndex(
      SnapshotIndex(
        accountKey: _binding.accountKey,
        lastValidatedAt: _date,
        consentAt: _date,
        lastProbeAt: _date,
        snapshots: [record],
      ),
      expectedRevision: store.revision,
      mayCommit: () => true,
    );
    owner.open(_binding, readOnly: true);
    return PresentationHarness(root, keys, owner, record, store);
  }

  OfflineRepositories adapter() =>
      OfflineRepositories(binding: _binding, coordinator: owner);
  void close() => root.deleteSync(recursive: true);
}

MarkdownMediaSource source({
  String path = 'docs/a.png',
  String ref = _sha,
  String? project = '42',
  String? uri,
  MarkdownMediaSourceKind kind = MarkdownMediaSourceKind.repository,
}) => MarkdownMediaSource(
  kind: kind,
  project: project,
  path: path,
  ref: ref,
  uri: Uri.parse(uri ?? 'a.png'),
);

void main() {
  test('adapter exposes read-only metadata and rejects saving', () async {
    final h = await PresentationHarness.create();
    addTearDown(h.close);
    final adapter = h.adapter();
    addTearDown(adapter.dispose);
    await adapter.refresh();
    expect(adapter.state, OfflineRepositoryState.offlineReadOnly);
    expect(adapter.snapshots.single.id, _id);
    expect(adapter.consentAt, _date);
    expect(adapter.lastValidatedAt, _date);
    expect(adapter.lastProbeAt, _date);
    expect(adapter.usedBytes, greaterThan(0));
    expect(adapter.canSave, isFalse);
    expect(
      () => adapter.save(
        SnapshotSaveRequest(
          projectId: 42,
          projectPath: 'group/project',
          projectName: 'project',
          defaultBranch: 'main',
          refKind: SnapshotRefKind.branch,
          refName: 'main',
          consentAt: _date,
        ),
      ),
      throwsA(
        isA<SnapshotOperationException>().having(
          (e) => e.failure,
          'failure',
          SnapshotFailure.offlineCacheDisabled,
        ),
      ),
    );
    expect(
      await adapter.reader(adapter.snapshots.single).text('docs/plain.txt'),
      'text',
    );
  });

  test(
    'fence clears rows synchronously and late refresh cannot restore them',
    () async {
      final h = await PresentationHarness.create();
      addTearDown(h.close);
      final adapter = h.adapter();
      addTearDown(adapter.dispose);
      await adapter.refresh();
      expect(adapter.snapshots, hasLength(1));
      h.keys.readDelayed = false;
      h.keys.readGate = Completer<void>();
      h.keys.readStarted = Completer<void>();
      final lateRefresh = adapter.refresh();
      await h.keys.readStarted!.future;
      h.owner.fence(_binding.accountKey);
      expect(adapter.snapshots, isEmpty);
      expect(adapter.consentAt, isNull);
      h.keys.readGate!.complete();
      await lateRefresh;
      await Future<void>.delayed(Duration.zero);
      expect(adapter.snapshots, isEmpty);
      expect(adapter.state, OfflineRepositoryState.cleaning);
    },
  );

  test('disposing during queued refresh prevents later notification', () async {
    final h = await PresentationHarness.create();
    addTearDown(h.close);
    final adapter = h.adapter();
    await adapter.refresh();
    var notifications = 0;
    adapter.addListener(() => notifications++);
    h.keys.readDelayed = false;
    h.keys.readGate = Completer<void>();
    h.keys.readStarted = Completer<void>();
    final pending = adapter.refresh();
    await h.keys.readStarted!.future;
    adapter.dispose();
    final before = notifications;
    h.keys.readGate!.complete();
    await pending;
    await Future<void>.delayed(Duration.zero);
    expect(notifications, before);
  });

  test(
    'snapshot media reads only current saved images with no network fallback',
    () async {
      final h = await PresentationHarness.create();
      addTearDown(h.close);
      final adapter = h.adapter();
      addTearDown(adapter.dispose);
      await adapter.refresh();
      final reader = adapter.reader(adapter.snapshots.single);
      final media = SnapshotReaderMediaSource(
        reader: reader,
        projectPath: 'group/project',
        refName: 'main',
      );
      final loader = MarkdownMediaLoader.snapshot(media);
      addTearDown(loader.close);
      MarkdownMediaSource resolve(String value) => resolveMarkdownMedia(
        Uri.parse(value),
        base: Uri.parse(
          'https://example.test/group/project/-/blob/$_sha/docs/README.md',
        ),
        instance: GitLabInstance.parse('https://example.test'),
        projectId: 42,
        projectWeb: Uri.parse('https://example.test/group/project'),
      );
      expect(await loader.load(source()), <int>[137, 80, 78, 71]);
      expect(await loader.load(resolve('a.png')), <int>[137, 80, 78, 71]);
      expect(
        utf8.decode(
          await loader.load(source(path: 'docs/icon.svg', uri: 'icon.svg')),
        ),
        '<svg/>',
      );
      expect(
        await loader.load(
          source(
            ref: 'main',
            uri: 'https://example.test/group/project/-/raw/main/docs/a.png',
          ),
        ),
        <int>[137, 80, 78, 71],
      );
      expect(
        await loader.load(
          source(
            ref: 'main',
            uri: 'https://example.test/group/project/-/blob/main/docs/a.png?raw=true',
          ),
        ),
        <int>[137, 80, 78, 71],
      );
      for (final denied in <MarkdownMediaSource>[
        resolve('https://outside.test/a.png'),
        resolve('data:image/png;base64,AQ=='),
        resolve('https://example.test/group/project/uploads/abcdef/image.png'),
        source(
          kind: MarkdownMediaSourceKind.external,
          uri: 'https://outside.test/a.png',
        ),
        source(kind: MarkdownMediaSourceKind.upload),
        source(kind: MarkdownMediaSourceKind.data),
        source(project: '99'),
        source(ref: 'other'),
        source(path: 'other/a.png'),
        source(path: 'docs/missing.png'),
        source(path: 'docs/plain.txt'),
        source(
          ref: 'main',
          uri: 'https://other.test/group/project/-/raw/main/docs/a.png',
        ),
        source(
          ref: 'main',
          uri: 'https://example.test/other/project/-/raw/main/docs/a.png',
        ),
        source(
          ref: 'main',
          uri: 'https://example.test/group/project/-/raw/other/docs/a.png',
        ),
        source(
          ref: 'main',
          uri: 'https://example.test/group/project/-/invalid/main/docs/a.png',
        ),
        source(
          ref: 'main',
          uri: 'https://example.test/group/project/-/blob/main/docs/a.png',
        ),
      ]) {
        await expectLater(
          () => loader.load(denied),
          throwsA(isA<ApiFailure>()),
        );
      }
      expect(loader.blockedNetworkAttempts, 0);
      expect(
        () => SnapshotRepositoryReader(
          owner: const ReaderOwner(
            accountKey: 'https://example.test#2',
            generation: 1,
            instanceKey: 'https://example.test',
            projectId: 42,
            sha: _sha,
            subPath: 'docs',
            snapshotId: _id,
          ),
          coordinator: h.owner,
        ),
        throwsA(isA<SnapshotOperationException>()),
      );
      h.owner.fence(_binding.accountKey);
      await expectLater(
        () => loader.load(source()),
        throwsA(isA<SnapshotOperationException>()),
      );
      expect(loader.blockedNetworkAttempts, 0);
    },
  );

  test(
    'attribute hint requires omissions and saved root attributes with a known token',
    () async {
      for (final (attributes, missing, saved, omission, expected)
          in <(String, int, bool, SnapshotEntryState, bool)>[
            ('*.txt text eol=lf\n', 1, true, SnapshotEntryState.missing, true),
            ('*.txt filter=abc\n', 1, true, SnapshotEntryState.mismatch, true),
            ('*.txt custom\n', 1, true, SnapshotEntryState.missing, false),
            (
              '*.txt export-ignore\n',
              0,
              true,
              SnapshotEntryState.missing,
              false,
            ),
            ('*.txt ident\n', 1, false, SnapshotEntryState.missing, false),
          ]) {
        final h = await PresentationHarness.create(
          attributes: attributes,
          missing: missing,
          omission: omission,
          attributesSaved: saved,
        );
        final adapter = h.adapter();
        try {
          await adapter.refresh();
          expect(
            await adapter
                .reader(adapter.snapshots.single)
                .hasAttributeOmissions(),
            expected,
          );
        } finally {
          adapter.dispose();
          h.close();
        }
      }
    },
  );
}
