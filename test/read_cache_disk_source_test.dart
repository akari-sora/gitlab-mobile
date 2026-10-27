import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/core/read_cache_projection.dart';
import 'package:gitlab_mobile/core/request_meter.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/ai/ai_write_reread.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'package:gitlab_mobile/shared/theme.dart';

import 'ai/fx_coord_support.dart' show StackHarness;
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';

const _account = 'https://example.com/gitlab#7';
const _path = ['projects', '9', 'issues', '3'];
const _clear = DiskClearResult(
  keyGoneConfirmed: false,
  directoryGoneConfirmed: false,
  markerDurable: false,
  complete: false,
);
const _state = ReadCacheCleanupState(
  operation: ReadCacheCleanupOperation.mutation,
  disposition: ReadCacheCleanupDisposition.requestBlockedBeforeSend,
  code: ReadCacheCleanupCode.cleanupFailed,
  clearResult: _clear,
);

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
  final events = <DiskInvalidation>[];
  final notices = <ReadCacheCleanupState>[];
  final accepted = <(DiskWriteCandidate, ProjectedDiskEntry)>[];
  Future<ProjectedDiskEntry?> Function(DiskLookup)? read;
  DiskInvalidationFence Function(DiskInvalidation)? invalidating;
  int lookups = 0, revoked = 0;
  bool throwingListener = false;
  @override
  Future<ProjectedDiskEntry?> lookup(DiskLookup value) async {
    lookups++;
    return read?.call(value);
  }

  @override
  void accept(DiskWriteCandidate candidate, ProjectedDiskEntry entry) =>
      accepted.add((candidate, entry));
  @override
  DiskInvalidationFence invalidate(DiskInvalidation value) {
    events.add(value);
    return invalidating?.call(value) ?? _Fence(Future.value(_clear));
  }

  @override
  Future<DiskClearResult> clear(
    DiskBinding binding,
    ReadCacheCleanupOperation operation,
  ) async => _clear;
  @override
  void revoke(DiskBinding binding) {
    revoked++;
  }

  @override
  void reportCleanup(ReadCacheCleanupState state) {
    notices.add(state);
    if (throwingListener) throw StateError('synthetic subscriber');
  }
}

final class _FailureDio implements Dio {
  _FailureDio(this.failure, this.stack);
  final ApiFailure failure;
  final StackTrace stack;
  @override
  final BaseOptions options = BaseOptions();
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #requestUri) {
      return Future<Never>.error(failure, stack);
    }
    if (invocation.memberName == #close) return null;
    return super.noSuchMethod(invocation);
  }
}

GitLabApi _api(_Backend backend, FakeAdapter adapter) =>
    GitLabApi(
        instance: GitLabInstance.parse('https://example.com/gitlab'),
        token: 'synthetic-test-token',
        dio: Dio()..httpClientAdapter = adapter,
        readCacheClock: () => DateTime.utc(2026, 10, 27),
      )
      ..bindReadCache(_account, 1)
      ..attachReadCacheDiskBackend(backend);

Matcher _cleanup(
  ReadCacheCleanupCode code,
  ReadCacheCleanupDisposition disposition,
) => isA<ApiFailure>()
    .having((e) => e.kind, 'kind', FailureKind.readCacheCleanup)
    .having((e) => e.cleanup?.code, 'code', code)
    .having((e) => e.cleanup?.disposition, 'disposition', disposition);

void main() {
  test(
    'begin failure blocks HTTP/meter and pairs active count exactly once',
    () async {
      final backend = _Backend()
        ..invalidating = (_) =>
            _Fence(Future.error(const ApiFailure.readCacheCleanup(_state)));
      final adapter = FakeAdapter((_) => jsonResponse({'id': 1}));
      final api = _api(backend, adapter);
      addTearDown(api.close);
      final meter = RequestMeter();
      await expectLater(
        meter.runAsync(
          () => api.writeRecord('POST', _path, {'title': 'changed'}),
        ),
        throwsA(
          _cleanup(
            ReadCacheCleanupCode.cleanupFailed,
            ReadCacheCleanupDisposition.requestBlockedBeforeSend,
          ),
        ),
      );
      expect(adapter.requests, isEmpty);
      expect(meter.count, 0);
      expect(api.readCacheMetadataCounts['writes'], 0);
      expect(backend.events, hasLength(1));
      expect(backend.notices.single.clearResult, same(_clear));
    },
  );

  testWidgets(
    'begin barrier has exact 5 s limit; readers see active; late completion never sends',
    (tester) async {
      final held = Completer<DiskClearResult>();
      final fence = _Fence(held.future);
      final backend = _Backend()..invalidating = (_) => fence;
      final adapter = FakeAdapter((_) => jsonResponse({'id': 1}));
      final api = _api(backend, adapter);
      final meter = RequestMeter();
      Object? outcome;
      unawaited(
        meter
            .runAsync(
              () => api.writeRecord('POST', _path, {'title': 'changed'}),
            )
            .then<void>(
              (v) {
                outcome = v;
              },
              onError: (Object e) {
                outcome = e;
              },
            ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 4999));
      expect(outcome, isNull);
      expect(api.readCacheMetadataCounts['writes'], greaterThan(0));
      expect(adapter.requests, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(
        outcome,
        _cleanup(
          ReadCacheCleanupCode.barrierTimedOut,
          ReadCacheCleanupDisposition.requestBlockedBeforeSend,
        ),
      );
      expect(api.readCacheMetadataCounts['writes'], 0);
      expect(meter.count, 0);
      expect(fence.revoked, isTrue);
      held.complete(_clear);
      await tester.pump();
      expect(adapter.requests, isEmpty);
      api.close();
    },
  );

  testWidgets(
    'close while awaiting begin returns exact cancelled, no send, paired end',
    (tester) async {
      final held = Completer<DiskClearResult>();
      final backend = _Backend()..invalidating = (_) => _Fence(held.future);
      final adapter = FakeAdapter((_) => jsonResponse({'id': 1}));
      final api = _api(backend, adapter);
      Object? result;
      unawaited(
        api
            .writeRecord('POST', _path, {'title': 'changed'})
            .then<void>(
              (v) {
                result = v;
              },
              onError: (Object e) {
                result = e;
              },
            ),
      );
      await tester.pump();
      api.close();
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(
        result,
        isA<ApiFailure>().having((e) => e.kind, 'kind', FailureKind.cancelled),
      );
      expect(api.readCacheMetadataCounts['writes'], 0);
      expect(adapter.requests, isEmpty);
      held.complete(_clear);
      await tester.pump();
      expect(adapter.requests, isEmpty);
    },
  );

  for (final status in [200, 422, 429, 503, 0]) {
    for (final timeout in [false, true]) {
      testWidgets(
        'end ${timeout ? 'timeout' : 'failure'} preserves original outcome $status and isolates listener',
        (tester) async {
          var barriers = 0;
          final held = Completer<DiskClearResult>();
          final backend = _Backend()
            ..throwingListener = true
            ..invalidating = (_) => ++barriers == 1
                ? _Fence(Future.value(_clear))
                : _Fence(
                    timeout
                        ? held.future
                        : Future.error(
                            const ApiFailure.readCacheCleanup(_state),
                          ),
                  );
          final adapter = FakeAdapter((_) {
            if (status == 0) {
              throw const SocketException('synthetic disconnect');
            }
            return jsonResponse(
              {'id': 17, 'title': 'ack'},
              status: status,
              headers: status == 429
                  ? {
                      'retry-after': ['30'],
                    }
                  : {},
            );
          });
          final api = _api(backend, adapter);
          Object? result;
          // Real async Dio work finishes before entering the fake-clock end wait.
          await tester.runAsync(() async {
            unawaited(
              api
                  .writeRecord('POST', _path, {'title': 'changed'})
                  .then<void>(
                    (v) {
                      result = v;
                    },
                    onError: (Object e) {
                      result = e;
                    },
                  ),
            );
            final deadline = DateTime.now().add(const Duration(seconds: 3));
            while (barriers < 2 && DateTime.now().isBefore(deadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 1));
            }
          });
          // runAsync timers use real time; release the held fence with the exact
          // coordinator timeout failure to exercise preservation separately.
          await tester.runAsync(() async {
            if (timeout) {
              held.completeError(
                const ApiFailure.readCacheCleanup(
                  ReadCacheCleanupState(
                    operation: ReadCacheCleanupOperation.mutation,
                    disposition: ReadCacheCleanupDisposition.diskClosed,
                    code: ReadCacheCleanupCode.barrierTimedOut,
                    clearResult: _clear,
                  ),
                ),
              );
            }
            final deadline = DateTime.now().add(const Duration(seconds: 3));
            while (result == null && DateTime.now().isBefore(deadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 1));
            }
          });
          await tester.pump();
          if (status == 200) {
            expect(result, containsPair('id', 17));
          } else {
            expect(
              result,
              isA<ApiFailure>()
                  .having(
                    (e) => e.kind,
                    'kind',
                    status == 0
                        ? FailureKind.writeUncertain
                        : status == 422
                        ? FailureKind.validation
                        : status == 429
                        ? FailureKind.rateLimited
                        : FailureKind.server,
                  )
                  .having(
                    (e) => e.status,
                    'status',
                    status == 0 ? null : status,
                  ),
            );
            if (status == 429) {
              expect(
                (result as ApiFailure).retryAt,
                DateTime.utc(2026, 10, 27).add(const Duration(seconds: 30)),
              );
            }
          }
          expect(
            backend.notices.single.disposition,
            ReadCacheCleanupDisposition.originalOutcomePreserved,
          );
          expect(
            backend.notices.single.code,
            timeout
                ? ReadCacheCleanupCode.barrierTimedOut
                : ReadCacheCleanupCode.cleanupFailed,
          );
          expect(adapter.requests, hasLength(1));
          expect(api.readCacheMetadataCounts['writes'], 0);
          api.close();
        },
      );
    }
  }

  test(
    'privacy failure returns legal fresh network value; all four clear flags remain false',
    () async {
      final backend = _Backend()
        ..throwingListener = true
        ..invalidating = (_) =>
            _Fence(Future.error(const ApiFailure.readCacheCleanup(_state)));
      final api = _api(
        backend,
        FakeAdapter(
          (_) => jsonResponse({
            'id': 33,
            'project_id': 9,
            'iid': 3,
            'title': 'authorized',
            'confidential': true,
          }),
        ),
      );
      addTearDown(api.close);
      final value = await api.record(_path);
      expect(value['title'], 'authorized');
      expect(backend.accepted, isEmpty);
      expect(backend.events.single.kind, DiskInvalidationKind.privacy);
      final notice = backend.notices.single;
      expect(notice.operation, ReadCacheCleanupOperation.privacyRead);
      expect(
        notice.disposition,
        ReadCacheCleanupDisposition.legalNetworkValueReturned,
      );
      expect([
        notice.clearResult.keyGoneConfirmed,
        notice.clearResult.directoryGoneConfirmed,
        notice.clearResult.markerDurable,
        notice.clearResult.complete,
      ], everyElement(isFalse));
    },
  );

  test(
    'accepted lease survives ticket retirement and is revoked by a newer publication, writes and close',
    () async {
      final backend = _Backend();
      final api = _api(
        backend,
        FakeAdapter(
          (_) => jsonResponse({
            'id': 33,
            'project_id': 9,
            'iid': 3,
            'title': 'public',
            'confidential': false,
          }),
        ),
      );
      addTearDown(api.close);
      await api.cachedRecord(_path);
      final first = backend.accepted.single.$1.lease;
      expect(api.readCacheMetadataCounts['publications'], 0);
      expect(first.isCurrent, isTrue);
      await api.cachedRecord(_path, fresh: true);
      expect(first.isCurrent, isFalse);
      final second = backend.accepted.last.$1.lease;
      expect(second.isCurrent, isTrue);
      await api.writeRecord('POST', _path, {'title': 'new'});
      expect(second.isCurrent, isFalse);
      await api.cachedRecord(_path, fresh: true);
      final last = backend.accepted.last.$1.lease;
      api.close();
      expect(last.isCurrent, isFalse);
      expect(backend.revoked, 1);
    },
  );

  for (final failure in [
    StateError('synthetic'),
    const ApiFailure(FailureKind.cancelled),
    ApiFailure(
      FailureKind.rateLimited,
      status: 429,
      retryAt: DateTime.utc(2026, 10, 28),
    ),
  ]) {
    test(
      'unexpected source failure is exact safeFailure: ${failure.runtimeType}',
      () async {
        final backend = _Backend()..read = (_) => Future.error(failure);
        final adapter = FakeAdapter((_) => jsonResponse({}));
        final api = _api(backend, adapter);
        addTearDown(api.close);
        await expectLater(
          api.cachedRecord(_path),
          throwsA(
            failure is ApiFailure
                ? same(failure)
                : isA<ApiFailure>().having(
                    (e) => e.kind,
                    'kind',
                    FailureKind.invalidResponse,
                  ),
          ),
        );
        expect(adapter.requests, isEmpty);
      },
    );
  }

  for (final action in [
    'edit',
    'assignees',
    'reviewers',
    'labels',
    'remove label',
    'draft',
  ]) {
    testWidgets(
      'actual $action updated_at preflight sends GET while same disk lookup is held',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(412, 1200);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final fixture = WorkspaceFixture();
        fixture.issues[1] = {
          ...fixture.issue(1, 'Disk preflight issue'),
          'labels': ['a'],
        };
        final isMr = action == 'reviewers' || action == 'draft';
        final resource = isMr ? 'merge_requests' : 'issues';
        final id = isMr ? 12 : 1;
        final suffix = '/projects/42/$resource/$id';
        final held = Completer<ProjectedDiskEntry?>();
        final backend = _Backend();
        final api = _api(backend, fixture.adapter);
        addTearDown(api.close);
        addTearDown(fixture.api.close);
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            locale: const Locale('zh', 'TW'),
            supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: Scaffold(
              body: WorkItemPage(
                account: fixture.account,
                api: api,
                project: fixture.project,
                resource: resource,
                iid: id,
              ),
            ),
          ),
        );
        await settleNetworkWidgets(tester);
        var matchingLookups = 0;
        backend.read = (lookup) {
          if (lookup.canonicalKey.contains(suffix)) {
            matchingLookups++;
            return held.future;
          }
          return Future.value(null);
        };
        await tester.runAsync(() async {
          unawaited(
            api
                .cachedRecord([
                  'projects',
                  '42',
                  resource,
                  '$id',
                ], maxAge: Duration.zero)
                .then<void>((_) {}, onError: (Object _) {}),
          );
          await Future<void>.delayed(Duration.zero);
        });
        expect(matchingLookups, 1, reason: action);
        int reads() => fixture.adapter.requests
            .where((r) => r.method == 'GET' && r.uri.path.endsWith(suffix))
            .length;
        final before = reads();
        if (action == 'edit' || action == 'draft') {
          await tester.tap(find.byTooltip('更多操作'));
          await tester.pumpAndSettle();
          await tester.tap(find.text(action == 'edit' ? '編輯' : '標示為草稿'));
          await settleNetworkWidgets(tester);
          if (action == 'edit') {
            await tester.enterText(
              find.byKey(const ValueKey('editor-title')),
              'Updated title',
            );
            await tester.tap(find.byKey(const Key('editorSave')));
          }
        } else if (action == 'assignees' || action == 'reviewers') {
          final button = find.byKey(ValueKey('quick-edit-$action'));
          await tester.ensureVisible(button);
          await tester.pump();
          await tester.tap(button);
          await settleNetworkWidgets(tester);
          await tester.tap(find.byKey(const Key('editorSave')));
        } else if (action == 'labels') {
          final button = find.byKey(const ValueKey('quick-edit-labels'));
          await tester.ensureVisible(button);
          await tester.pump();
          await tester.tap(button);
          await settleNetworkWidgets(tester);
          await tester.tap(find.byKey(const Key('picker-done')));
        } else {
          final button = find.descendant(
            of: find.byKey(const ValueKey('label-chip-a')),
            matching: find.byIcon(Icons.close),
          );
          await tester.ensureVisible(button);
          await tester.pump();
          await tester.tap(button);
        }
        await pumpUntil(
          tester,
          () => reads() > before,
          description: '$action preflight GET',
        );
        expect(matchingLookups, 1, reason: action);
        expect(held.isCompleted, isFalse, reason: action);
        held.complete(null);
        await settleNetworkWidgets(tester);
        await tester.pumpWidget(const SizedBox());
        await settleNetworkWidgets(tester);
      },
    );
  }

  test(
    'currentUser, direct record, and AI write port bypass a held disk lookup',
    () async {
      final held = Completer<ProjectedDiskEntry?>();
      final backend = _Backend()..read = (_) => held.future;
      final adapter = FakeAdapter((r) {
        if (r.uri.path.endsWith('/user')) {
          return jsonResponse({'id': 7, 'username': 'synthetic'});
        }
        if (r.uri.path.endsWith('/projects/9')) {
          return jsonResponse(projectJson(9));
        }
        return jsonResponse({
          'id': 33,
          'iid': 3,
          'project_id': 9,
          'updated_at': '2026-10-27T00:00:00Z',
        });
      });
      final api = _api(backend, adapter);
      addTearDown(api.close);
      final disk = api.cachedRecord(_path);
      await Future<void>.delayed(Duration.zero);
      expect(backend.lookups, 1);
      await api.currentUser();
      expect((await api.record(_path))['updated_at'], '2026-10-27T00:00:00Z');
      final port = GitLabAiWritePort(api, accountKey: _account);
      final prepared = await port.prepare(
        AiWriteRequest(
          operationId: 'createNote',
          executionId: 'disk-preflight',
          scope: const AiWriteScope(
            accountKey: _account,
            grants: [AiScopeGrant(kind: AiScopeKind.project, projectId: 9)],
          ),
          arguments: const {
            'projectId': 9,
            'resource': 'issues',
            'iid': 3,
            'body': 'synthetic',
          },
        ),
      );
      expect(
        await port.commit(prepared, mayStart: () => true),
        isA<AiWriteSettled>(),
      );
      expect(backend.lookups, 1);
      expect(adapter.requests.where((r) => r.method == 'POST'), hasLength(1));
      held.complete(null);
      await disk;
    },
  );

  test(
    'synchronous begin invalidation exception blocks send as cleanup failure',
    () async {
      final backend = _Backend()
        ..invalidating = (_) => throw StateError('synthetic');
      final adapter = FakeAdapter((_) => jsonResponse({'id': 1}));
      final api = _api(backend, adapter);
      addTearDown(api.close);
      final meter = RequestMeter();
      await expectLater(
        meter.runAsync(() => api.writeRecord('POST', _path, {'title': 'x'})),
        throwsA(
          _cleanup(
            ReadCacheCleanupCode.cleanupFailed,
            ReadCacheCleanupDisposition.requestBlockedBeforeSend,
          ),
        ),
      );
      expect(meter.count, 0);
      expect(adapter.requests, isEmpty);
      expect(api.readCacheMetadataCounts['writes'], 0);
      expect(backend.notices.single.code, ReadCacheCleanupCode.cleanupFailed);
    },
  );

  test(
    'synchronous privacy invalidation exception reports notice and keeps legal value',
    () async {
      final backend = _Backend()
        ..invalidating = (_) => throw StateError('synthetic');
      final api = _api(
        backend,
        FakeAdapter(
          (_) => jsonResponse({
            'id': 33,
            'project_id': 9,
            'iid': 3,
            'confidential': true,
            'title': 'legal',
          }),
        ),
      );
      addTearDown(api.close);
      expect((await api.record(_path))['title'], 'legal');
      expect(backend.accepted, isEmpty);
      expect(
        backend.notices.single.operation,
        ReadCacheCleanupOperation.privacyRead,
      );
      expect(
        backend.notices.single.disposition,
        ReadCacheCleanupDisposition.legalNetworkValueReturned,
      );
      expect(backend.notices.single.code, ReadCacheCleanupCode.cleanupFailed);
    },
  );

  for (final omitted in ['project_id', 'iid']) {
    test(
      'direct issue privacy true uses path identity when $omitted is absent',
      () async {
        final backend = _Backend();
        final api = _api(
          backend,
          FakeAdapter(
            (_) => jsonResponse({
              'id': 33,
              if (omitted != 'project_id') 'project_id': 9,
              if (omitted != 'iid') 'iid': 3,
              'confidential': true,
            }),
          ),
        );
        addTearDown(api.close);
        expect((await api.record(_path))['confidential'], isTrue);
        final event = backend.events.singleWhere(
          (e) => e.kind == DiskInvalidationKind.privacy,
        );
        expect(event.issueIdentities, {const ReadCacheIssueIdentity(9, 3)});
      },
    );
  }

  test(
    'disk hydration returns only fields admitted by the projection',
    () async {
      final backend = _Backend()
        ..read = (lookup) async => ProjectedDiskEntry(
          accountKey: _account,
          canonicalKey: lookup.canonicalKey,
          cacheClass: ReadCacheDiskClass.detail,
          bodyKind: ReadCacheBodyKind.json,
          fetchedAt: DateTime.utc(2026, 10, 27),
          privacyEpoch: 0,
          issueIdentities: {const ReadCacheIssueIdentity(9, 3)},
          body: {
            'id': 33,
            'project_id': 9,
            'iid': 3,
            'title': 'safe',
            'confidential': false,
            'unexpected_secret': 'must not escape',
          },
        );
      final adapter = FakeAdapter((_) => jsonResponse({'id': 999}));
      final api = _api(backend, adapter);
      addTearDown(api.close);
      final result = await api.cachedRecord(_path);
      expect(result.lineage, CacheLineage.disk);
      expect(result.value['title'], 'safe');
      expect(result.value.containsKey('unexpected_secret'), isFalse);
      expect(adapter.requests, isEmpty);
    },
  );

  for (final collectionPath in [
    ['projects', '9', 'issues'],
    ['groups', '12', 'issues'],
  ]) {
    test(
      'collection 403 preserves a different query: $collectionPath',
      () async {
        final backend = _Backend();
        var reject = false;
        final adapter = FakeAdapter((r) {
          if (reject && r.uri.queryParameters['state'] == 'opened') {
            return jsonResponse({'message': 'forbidden'}, status: 403);
          }
          return jsonResponse(<Object?>[]);
        });
        final api = _api(backend, adapter);
        addTearDown(api.close);
        await api.cachedRecords(collectionPath, query: {'state': 'opened'});
        await api.cachedRecords(collectionPath, query: {'state': 'closed'});
        final before = adapter.requests.length;
        reject = true;
        await expectLater(
          api.cachedRecords(
            collectionPath,
            query: {'state': 'opened'},
            fresh: true,
          ),
          throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 403)),
        );
        final event = backend.events.lastWhere(
          (e) => e.kind == DiskInvalidationKind.permission,
        );
        final uri = api.instance.api(collectionPath, {
          'per_page': '30',
          'state': 'opened',
        });
        expect(
          event.canonicalKey,
          readCacheDurableKey(
            binding: const DiskBinding(accountKey: _account, generation: 1),
            instance: api.instance,
            uri: uri,
            logicalAccept: 'application/json',
          ),
        );
        expect(event.path, isNull);
        final other = await api.cachedRecords(
          collectionPath,
          query: {'state': 'closed'},
        );
        expect(other.lineage, CacheLineage.memory);
        expect(adapter.requests.length, before + 1);
      },
    );
  }

  test(
    'ai_write_reread issues real network reads while matching disk reads are held',
    () async {
      final held = Completer<ProjectedDiskEntry?>();
      final backend = _Backend()..read = (_) => held.future;
      final adapter = FakeAdapter((r) {
        if (r.uri.path.endsWith('/user')) {
          return jsonResponse({'id': 7, 'username': 'synthetic'});
        }
        if (r.uri.path.endsWith('/projects/9')) {
          return jsonResponse(projectJson(9));
        }
        return jsonResponse({
          'id': 33,
          'iid': 3,
          'project_id': 9,
          'state': 'closed',
        });
      });
      final api = _api(backend, adapter);
      addTearDown(api.close);
      final root = Directory.systemTemp.createTempSync('disk-reread-');
      addTearDown(() => root.deleteSync(recursive: true));
      final journal = AiWriteJournal(
        keys: MemoryAiJournalKeyStore(),
        applicationSupport: root,
        processId: 'disk-reread',
      );
      await journal.recoverAfterAccountsLoaded([_account]);
      await journal.ensureInitialized(_account);
      await journal.prepare(
        draft: AiJournalDraft(
          executionId: 'interrupted',
          accountKey: _account,
          conversationId: 'conversation',
          runId: 'run',
          operationId: 'updateIssue',
          writeKeys: {
            const AiConflictKey([_account, 'project:9', 'workItem', '3']),
          },
          payloadSha256: List.filled(64, 'c').join(),
          releaseName: '#3',
          instance: api.instance.key,
        ),
      );
      await journal.markDispatching(executionId: 'interrupted');
      await journal.finish(
        executionId: 'interrupted',
        terminal: AiJournalState.writeUncertain,
      );
      final pendingProject = api.cachedRecord(['projects', '9']);
      final pendingIssue = api.cachedRecord(_path);
      await Future<void>.delayed(Duration.zero);
      expect(backend.lookups, 2);
      final result = await rereadInterruptedWrite(
        journal: journal,
        accountKey: _account,
        executionId: 'interrupted',
        api: api,
      ).timeout(const Duration(seconds: 3));
      expect(result.observation.presence, AiRereadPresence.present);
      expect(result.observation.subject, AiRereadSubject.issue);
      expect(result.requests, 3);
      expect(adapter.requests.map((r) => r.uri.path).toList(), [
        '/gitlab/api/v4/user',
        '/gitlab/api/v4/projects/9',
        '/gitlab/api/v4/projects/9/issues/3',
      ]);
      expect(adapter.requests.every((r) => r.method == 'GET'), isTrue);
      expect(backend.lookups, 2);
      held.complete(null);
      await Future.wait([pendingProject, pendingIssue]);
    },
  );

  test(
    '_freshWrite uses network while its project disk read is held',
    () async {
      final harness = await StackHarness.create();
      addTearDown(harness.dispose);
      final api = harness.session.api!;
      final held = Completer<ProjectedDiskEntry?>();
      final backend = _Backend()..read = (_) => held.future;
      api.attachReadCacheDiskBackend(backend);
      final pending = api.cachedRecord(['projects', '42']);
      await Future<void>.delayed(Duration.zero);
      expect(backend.lookups, 1);
      final before = harness.server.adapter.requests.length;
      final freshness = await harness.controller
          .readWriteFreshnessForTesting(
            AiWriteRequest(
              operationId: 'updateWorkItemState',
              executionId: 'held-disk-freshness',
              scope: AiWriteScope(
                accountKey: harness.account,
                grants: const [
                  AiScopeGrant(kind: AiScopeKind.project, projectId: 42),
                ],
              ),
              arguments: const {'projectId': 42, 'iid': 5},
            ),
          )
          .timeout(const Duration(seconds: 3));
      expect(freshness.visibilityUnreadable, isFalse);
      final requests = harness.server.adapter.requests.skip(before).toList();
      expect(requests, hasLength(1));
      expect(requests.single.method, 'GET');
      expect(requests.single.uri.path, '/gitlab/api/v4/projects/42');
      expect(backend.lookups, 1);
      held.complete(null);
      await pending;
    },
  );

  testWidgets('C2-D1 actual five-second begin timeout persists failedCertain', (
    tester,
  ) async {
    final held = Completer<DiskClearResult>();
    final backend = _Backend()..invalidating = (_) => _Fence(held.future);
    final adapter = FakeAdapter(
      (r) => r.uri.path.endsWith('/user')
          ? jsonResponse({'id': 7, 'username': 'synthetic'})
          : r.uri.path.endsWith('/projects/9')
          ? jsonResponse(projectJson(9))
          : jsonResponse({'id': 33, 'iid': 3, 'project_id': 9}),
    );
    final api = _api(backend, adapter);
    final root = Directory.systemTemp.createTempSync('disk-timeout-journal-');
    final keys = MemoryAiJournalKeyStore();
    late AiWriteJournal journal;
    late GitLabAiWritePort port;
    late AiWritePrepared prepared;
    await tester.runAsync(() async {
      journal = AiWriteJournal(
        keys: keys,
        applicationSupport: root,
        processId: 'timeout-journal',
      );
      await journal.recoverAfterAccountsLoaded([_account]);
      await journal.ensureInitialized(_account);
      port = GitLabAiWritePort(api, accountKey: _account);
      prepared = await port.prepare(
        AiWriteRequest(
          operationId: 'createNote',
          executionId: 'timeout',
          scope: const AiWriteScope(
            accountKey: _account,
            grants: [AiScopeGrant(kind: AiScopeKind.project, projectId: 9)],
          ),
          arguments: const {
            'projectId': 9,
            'resource': 'issues',
            'iid': 3,
            'body': 'synthetic',
          },
        ),
      );
      await journal.prepare(
        draft: AiJournalDraft(
          executionId: 'timeout',
          accountKey: _account,
          conversationId: 'conversation',
          runId: 'run',
          operationId: 'createNote',
          writeKeys: prepared.writeKeys,
          dependencyKeys: prepared.dependencyKeys,
          payloadSha256: List.filled(64, 'a').join(),
          releaseName: 'synthetic',
        ),
      );
      await journal.markDispatching(executionId: 'timeout');
    });
    final before = adapter.requests.length;
    final meter = RequestMeter();
    AiWriteOutcome? outcome;
    unawaited(
      meter.runAsync(() => port.commit(prepared, mayStart: () => true)).then((
        v,
      ) {
        outcome = v;
      }),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 4999));
    expect(outcome, isNull);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(outcome, isA<AiWriteSettled>());
    final settled = outcome as AiWriteSettled;
    expect(settled.state, AiJournalState.failedCertain);
    expect(settled.resultCode, 'readCacheCleanup');
    expect(meter.count, 0);
    expect(adapter.requests.length, before);
    expect(backend.notices.single.code, ReadCacheCleanupCode.barrierTimedOut);
    held.complete(_clear);
    await tester.runAsync(() async {
      await journal.finish(executionId: 'timeout', terminal: settled.state);
      final reopened = AiWriteJournal(
        keys: keys,
        applicationSupport: root,
        processId: 'timeout-reopen',
      );
      await reopened.recoverAfterAccountsLoaded([_account]);
      expect(
        reopened.entries(_account).single.state,
        AiJournalState.failedCertain,
      );
    });
    api.close();
    root.deleteSync(recursive: true);
  });

  test(
    'C2-D1 blocked AI write persists failedCertain and permits a fresh retry execution',
    () async {
      final backend = _Backend()
        ..invalidating = (_) =>
            _Fence(Future.error(const ApiFailure.readCacheCleanup(_state)));
      final adapter = FakeAdapter(
        (r) => r.uri.path.endsWith('/user')
            ? jsonResponse({'id': 7, 'username': 'synthetic'})
            : r.uri.path.endsWith('/projects/9')
            ? jsonResponse(projectJson(9))
            : jsonResponse({'id': 33, 'iid': 3, 'project_id': 9}),
      );
      final api = _api(backend, adapter);
      addTearDown(api.close);
      final root = Directory.systemTemp.createTempSync(
        'read-cache-d1-journal-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final keys = MemoryAiJournalKeyStore();
      final journal = AiWriteJournal(
        keys: keys,
        applicationSupport: root,
        processId: 'read-cache-d1',
      );
      await journal.recoverAfterAccountsLoaded([_account]);
      await journal.ensureInitialized(_account);
      final port = GitLabAiWritePort(api, accountKey: _account);
      for (final id in ['blocked', 'retry']) {
        final prepared = await port.prepare(
          AiWriteRequest(
            operationId: 'createNote',
            executionId: id,
            scope: const AiWriteScope(
              accountKey: _account,
              grants: [AiScopeGrant(kind: AiScopeKind.project, projectId: 9)],
            ),
            arguments: const {
              'projectId': 9,
              'resource': 'issues',
              'iid': 3,
              'body': 'synthetic',
            },
          ),
        );
        await journal.prepare(
          draft: AiJournalDraft(
            executionId: id,
            accountKey: _account,
            conversationId: 'synthetic-conversation',
            runId: 'synthetic-run',
            operationId: 'createNote',
            writeKeys: prepared.writeKeys,
            dependencyKeys: prepared.dependencyKeys,
            payloadSha256: List.filled(64, 'a').join(),
            releaseName: 'synthetic',
          ),
        );
        await journal.markDispatching(executionId: id);
        final before = adapter.requests.length;
        final meter = RequestMeter();
        final outcome =
            await meter.runAsync(
                  () => port.commit(prepared, mayStart: () => true),
                )
                as AiWriteSettled;
        expect(outcome.state, AiJournalState.failedCertain);
        expect(outcome.resultCode, 'readCacheCleanup');
        expect(meter.count, 0);
        expect(adapter.requests, hasLength(before));
        await journal.finish(executionId: id, terminal: outcome.state);
      }
      final reopened = AiWriteJournal(
        keys: keys,
        applicationSupport: root,
        processId: 'fresh-read-cache-d1',
      );
      await reopened.recoverAfterAccountsLoaded([_account]);
      expect(
        reopened.entries(_account).map((e) => e.state),
        everyElement(AiJournalState.failedCertain),
      );
      expect(reopened.entries(_account), hasLength(2));
    },
  );
  for (final mode in ['end', 'privacy', 'terminal']) {
    testWidgets(
      '$mode wait has exact five-second deadline and late completion preserves outcome',
      (tester) async {
        final held = Completer<DiskClearResult>();
        final fence = _Fence(held.future);
        final backend = _Backend();
        backend.invalidating = (_) =>
            mode == 'end' && backend.events.length == 1
            ? _Fence(Future.value(_clear))
            : fence;
        final adapter = FakeAdapter(
          (_) => jsonResponse({
            'id': 33,
            'project_id': 9,
            'iid': 3,
            'title': 'authorized',
            'confidential': mode == 'privacy',
          }, status: mode == 'terminal' ? 401 : 200),
        );
        final api = _api(backend, adapter);
        Object? outcome;
        unawaited(
          (mode == 'end'
                  ? api.writeRecord('POST', _path, {'title': 'changed'})
                  : api.record(_path))
              .then<void>(
                (value) {
                  outcome = value;
                },
                onError: (Object error) {
                  outcome = error;
                },
              ),
        );
        try {
          // Dio's stream continuations include root-zone completion futures.
          // Drain those without advancing the fake deadline installed by CRA.
          for (
            var turn = 0;
            turn < 20 && backend.events.length < (mode == 'end' ? 2 : 1);
            turn++
          ) {
            await tester.pump(Duration.zero);
            await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          }
          expect(backend.events, hasLength(mode == 'end' ? 2 : 1));
          await tester.pump(const Duration(milliseconds: 4999));
          expect(outcome, isNull);
          await tester.pump(const Duration(milliseconds: 1));
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump();
          if (mode == 'terminal') {
            expect(
              outcome,
              isA<ApiFailure>().having(
                (e) => e.kind,
                'kind',
                FailureKind.unauthenticated,
              ),
            );
          } else {
            expect(outcome, containsPair('title', 'authorized'));
          }
          expect(
            backend.notices.single.code,
            ReadCacheCleanupCode.barrierTimedOut,
          );
          expect(
            backend.notices.single.disposition,
            mode == 'end'
                ? ReadCacheCleanupDisposition.originalOutcomePreserved
                : mode == 'privacy'
                ? ReadCacheCleanupDisposition.legalNetworkValueReturned
                : ReadCacheCleanupDisposition.diskClosed,
          );
          expect(fence.revoked, isTrue);
          expect(api.readCacheMetadataCounts['writes'], 0);
          expect(adapter.requests, hasLength(1));
          held.complete(_clear);
          await tester.pump();
          expect(adapter.requests, hasLength(1));
        } finally {
          if (!held.isCompleted) held.complete(_clear);
          api.close();
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump();
        }
      },
    );
  }
  for (final failure in [
    const ApiFailure(FailureKind.validation, status: 422),
    ApiFailure(
      FailureKind.rateLimited,
      status: 429,
      retryAt: DateTime.utc(2026, 10, 28),
    ),
    const ApiFailure(FailureKind.writeUncertain),
  ]) {
    test(
      'end cleanup preserves exact original ${failure.kind} identity and stack',
      () async {
        final stack = StackTrace.fromString('synthetic transport origin');
        final backend = _Backend()..throwingListener = true;
        backend.invalidating = (_) => backend.events.length == 1
            ? _Fence(Future.value(_clear))
            : _Fence(Future.error(const ApiFailure.readCacheCleanup(_state)));
        final api =
            GitLabApi(
                instance: GitLabInstance.parse('https://example.com/gitlab'),
                token: 'synthetic-test-token',
                dio: _FailureDio(failure, stack),
              )
              ..bindReadCache(_account, 1)
              ..attachReadCacheDiskBackend(backend);
        addTearDown(api.close);
        Object? caught;
        StackTrace? caughtStack;
        try {
          await api.writeRecord('POST', _path, {'title': 'changed'});
        } catch (error, trace) {
          caught = error;
          caughtStack = trace;
        }
        expect(caught, same(failure));
        expect(caughtStack.toString(), stack.toString());
        expect(backend.events, hasLength(2));
        expect(
          backend.notices.single.disposition,
          ReadCacheCleanupDisposition.originalOutcomePreserved,
        );
        expect(api.readCacheMetadataCounts['writes'], 0);
      },
    );
  }
  for (final route in ['projects', 'issues', 'links']) {
    test(
      'Gate 1 rejects whole old disk $route before source eligibility',
      () async {
        final backend = _Backend();
        final adapter = FakeAdapter(
          (r) => r.uri.path.endsWith('/issues/3')
              ? jsonResponse({'project_id': 9, 'iid': 3, 'confidential': true})
              : jsonResponse(
                  route == 'projects' ? [projectJson(9)] : <Object>[],
                ),
        );
        final api = _api(backend, adapter);
        addTearDown(api.close);
        await api.record(_path);
        final before = adapter.requests.length;
        backend.read = (lookup) async => ProjectedDiskEntry(
          accountKey: _account,
          canonicalKey: lookup.canonicalKey,
          cacheClass: route == 'links'
              ? ReadCacheDiskClass.thread
              : ReadCacheDiskClass.list,
          bodyKind: ReadCacheBodyKind.page,
          fetchedAt: DateTime.utc(2026, 10, 26),
          body: {
            'items': [
              route == 'projects'
                  ? {
                      ...projectJson(9),
                      'nested': {
                        'project_id': 9,
                        'iid': 3,
                        'confidential': false,
                      },
                    }
                  : {
                      'id': 33,
                      'project_id': 9,
                      'iid': 3,
                      'title': 'old',
                      'confidential': false,
                    },
            ],
            'next': null,
          },
          privacyEpoch: 0,
          issueIdentities: {ReadCacheIssueIdentity(9, 3)},
        );
        final read = await api.cachedRecords(
          route == 'links'
              ? ['projects', '9', 'issues', '4', 'links']
              : [route],
        );
        expect(read.lineage, CacheLineage.network);
        expect(adapter.requests.length, before + 1);
        expect(
          backend.accepted.every(
            (event) => event.$2.fetchedAt != DateTime.utc(2026, 10, 26),
          ),
          isTrue,
        );
        expect(
          backend.events
              .where(
                (e) =>
                    e.kind == DiskInvalidationKind.privacy &&
                    e.issueIdentities.contains(ReadCacheIssueIdentity(9, 3)),
              )
              .length,
          greaterThanOrEqualTo(2),
        );
      },
    );
  }
  test(
    'a nested note cannot clear the direct issue confidentiality fence',
    () async {
      final backend = _Backend();
      final adapter = FakeAdapter(
        (_) => jsonResponse({
          'id': 33,
          'project_id': 9,
          'iid': 3,
          'title': 'authorized',
          'confidential': true,
          'notes': [
            {'id': 1, 'confidential': false},
          ],
        }),
      );
      final api = _api(backend, adapter);
      addTearDown(api.close);
      await api.record(_path);
      backend.read = (lookup) async => ProjectedDiskEntry(
        accountKey: _account,
        canonicalKey: lookup.canonicalKey,
        cacheClass: ReadCacheDiskClass.detail,
        bodyKind: ReadCacheBodyKind.json,
        fetchedAt: DateTime.utc(2026, 10, 26, 23, 59),
        privacyEpoch: 0,
        issueIdentities: {ReadCacheIssueIdentity(9, 3)},
        body: {
          'id': 33,
          'project_id': 9,
          'iid': 3,
          'title': 'old public',
          'confidential': false,
        },
      );
      final read = await api.cachedRecord(_path);
      expect(read.lineage, CacheLineage.network);
      expect(read.value['title'], 'authorized');
      expect(adapter.requests, hasLength(2));
    },
  );

  test(
    'an issue notes endpoint cannot inherit its parent privacy identity',
    () async {
      final backend = _Backend();
      final adapter = FakeAdapter(
        (request) => jsonResponse(
          request.uri.path.endsWith('/notes')
              ? [
                  {'id': 1, 'iid': 3, 'confidential': false},
                ]
              : {
                  'id': 33,
                  'project_id': 9,
                  'iid': 3,
                  'title': 'authorized',
                  'confidential': true,
                },
        ),
      );
      final api = _api(backend, adapter);
      addTearDown(api.close);
      await api.record(_path);
      await api.records([..._path, 'notes']);
      backend.read = (lookup) async => ProjectedDiskEntry(
        accountKey: _account,
        canonicalKey: lookup.canonicalKey,
        cacheClass: ReadCacheDiskClass.detail,
        bodyKind: ReadCacheBodyKind.json,
        fetchedAt: DateTime.utc(2026, 10, 26, 23, 59),
        privacyEpoch: 0,
        issueIdentities: {ReadCacheIssueIdentity(9, 3)},
        body: {
          'id': 33,
          'project_id': 9,
          'iid': 3,
          'title': 'old public',
          'confidential': false,
        },
      );
      final read = await api.cachedRecord(_path);
      expect(read.lineage, CacheLineage.network);
      expect(adapter.requests, hasLength(3));
    },
  );
}
