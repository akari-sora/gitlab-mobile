import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue_version.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/tools/write_tier.dart';
import 'package:gitlab_mobile/core/failure.dart';

import '../support/fake_adapter.dart';

const _account = 'https://example.com/gitlab#7';
const _scope = AiWriteScope(
  accountKey: _account,
  grants: [AiScopeGrant(kind: AiScopeKind.project, projectId: 9)],
);

ResponseBody _preflight(RequestOptions request) {
  if (request.uri.path.endsWith('/user')) {
    return jsonResponse({'id': 7, 'username': 'tester'});
  }
  if (request.uri.path.endsWith('/projects/9')) {
    return jsonResponse(projectJson(9));
  }
  if (request.uri.path.endsWith('/issues/3')) {
    return jsonResponse({'id': 33, 'iid': 3, 'project_id': 9});
  }
  return jsonResponse({'id': 8, 'iid': 3});
}

AiWriteRequest _request() => AiWriteRequest(
  operationId: 'createNote',
  executionId: 'p1-execution',
  scope: _scope,
  arguments: {
    'projectId': 9,
    'resource': 'issues',
    'iid': 3,
    'body': 'synthetic body',
  },
);

AiWriteSettled _classified(AiWritePrepared prepared, String code) =>
    AiWriteSettled(
      state: AiJournalState.failedCertain,
      resultCode: code,
      releaseName: prepared.releaseName,
      writeKeys: prepared.writeKeys,
      dependencyKeys: prepared.dependencyKeys,
    );

void main() {
  test('production catalogue version is 5 and still dependency free', () {
    expect(aiToolCatalogueVersion, 5);
    final source = File(
      'lib/core/ai/tools/tool_catalogue_version.dart',
    ).readAsStringSync();
    expect(RegExp(r'\b(import|export|part)\b').hasMatch(source), isFalse);
  });

  test('P1 all seven nullable family seams precede legacy preparation', () {
    final source = File(
      'lib/core/ai/tools/gitlab_write_port.dart',
    ).readAsStringSync();
    var previous = source.indexOf('Future<AiWritePrepared> prepare(');
    for (final family in [
      'Files',
      'Refs',
      'Merge',
      'Ci',
      'Snippets',
      'Deletes',
      'Project',
    ]) {
      final offset = source.indexOf('_prepare$family,', previous);
      expect(offset, greaterThan(previous), reason: family);
      previous = offset;
      final part = File(
        'lib/core/ai/tools/gitlab_write_port_${family.toLowerCase()}.dart',
      ).readAsStringSync();
      expect(part, startsWith("part of 'gitlab_write_port.dart';"));
      expect(part, contains('Future<AiWritePrepared?> _prepare$family('));
    }
    expect(source.indexOf('await _api.currentUser();'), greaterThan(previous));
  });

  test('P1 request snapshots HMAC and app-created identities separately', () {
    const created = AiCreatedRef(
      accountKey: _account,
      kind: AiTargetKind.pipeline,
      projectId: 9,
      id: 123,
    );
    final identities = <AiCreatedRef>{created};
    final key = <int>[1, 2, 3];
    final request = AiWriteRequest(
      operationId: 'setStar',
      executionId: 'p1-snapshot',
      scope: _scope,
      arguments: {'projectId': 9, 'starred': true},
      segmentCreated: identities,
      scheduleHmacKey: key,
    );
    identities.clear();
    key[0] = 99;
    expect(request.segmentCreated, {created});
    expect(request.scheduleHmacKey, [1, 2, 3]);
    expect(request.arguments.keys, unorderedEquals(['projectId', 'starred']));
    expect(() => request.segmentCreated.clear(), throwsUnsupportedError);
    expect(() => request.scheduleHmacKey![0] = 99, throwsUnsupportedError);
    expect(request.segmentCreated, {
      const AiCreatedRef(
        accountKey: _account,
        kind: AiTargetKind.pipeline,
        projectId: 9,
        id: 123,
      ),
    });
    expect(created.hashCode, request.segmentCreated.single.hashCode);
    expect(
      created,
      isNot(
        const AiCreatedRef(
          accountKey: 'https://other.example#7',
          kind: AiTargetKind.pipeline,
          projectId: 9,
          id: 123,
        ),
      ),
    );
  });

  test('P1 port keeps ledger upload boundaries closed before HTTP', () async {
    for (final arguments in <Map<String, Object?>>[
      {'projectId': 9, 'starred': true, 'unlisted': true},
      {'projectId': 9, 'attachmentId': 'att-1', 'filename': 'test.txt'},
    ]) {
      final adapter = FakeAdapter(_preflight);
      final api = testApi(adapter);
      addTearDown(api.close);
      final port = GitLabAiWritePort(api, accountKey: _account);
      await expectLater(
        port.prepare(
          AiWriteRequest(
            operationId: arguments.containsKey('attachmentId')
                ? 'upload_attachment'
                : 'setStar',
            executionId: 'p1-closed-arguments',
            scope: _scope,
            arguments: arguments,
          ),
        ),
        throwsA(
          isA<ApiFailure>().having(
            (failure) => failure.kind,
            'kind',
            FailureKind.validation,
          ),
        ),
      );
      expect(adapter.requests, isEmpty);
    }
  });

  test(
    'P1 legacy prepared defaults expose structured, isolated metadata',
    () async {
      final adapter = FakeAdapter(_preflight);
      final api = testApi(adapter);
      addTearDown(api.close);
      final port = GitLabAiWritePort(api, accountKey: _account);
      final prepared = await port.prepare(_request());
      expect(prepared.releaseName, '#3');
      expect(prepared.confirmName, isNull);
      expect(prepared.facts.touchesCiConfig, isFalse);
      expect(prepared.bindingTargets, isEmpty);
      expect(prepared.bindingDigest, isEmpty);
      expect(prepared.journal.headSha, isNull);
      expect(prepared.textScan, isNull);
      expect(prepared.createdOnSuccess, isNull);
      expect(prepared.classify, isNull);
      final preview = prepared.preview as AiFieldsPreview;
      expect(preview.fields, _request().arguments);
      expect(() => preview.fields.clear(), throwsUnsupportedError);
      expect(() => prepared.bindingTargets.clear(), throwsUnsupportedError);
      final outcome = await port.commit(prepared, mayStart: () => true);
      expect((outcome as AiWriteSettled).state, AiJournalState.succeeded);
      expect(adapter.requests.where((r) => r.method != 'GET'), hasLength(1));
    },
  );

  test('P1 classifier sees mutation and independent readback once', () async {
    final api = testApi(FakeAdapter(_preflight));
    addTearDown(api.close);
    var calls = 0;
    final port = GitLabAiWritePort(
      api,
      accountKey: _account,
      resultClassifier:
          (prepared, {result, readback, mutationError, readbackError}) {
            calls++;
            expect(result, {'id': 8, 'iid': 3});
            expect(readback, {'id': 8, 'iid': 3});
            expect(mutationError, isNull);
            expect(readbackError, isNull);
            return _classified(prepared, 'customResult');
          },
    );
    final prepared = await port.prepare(_request());
    expect(prepared.classify, isNotNull);
    final outcome = await port.commit(prepared, mayStart: () => true);
    expect((outcome as AiWriteSettled).resultCode, 'customResult');
    expect(
      await port.commit(prepared, mayStart: () => true),
      isA<AiWriteNotSent>(),
    );
    expect(calls, 1);
  });

  for (final failureInReadback in [false, true]) {
    test(
      'P1 classifier separates errors, readback=$failureInReadback',
      () async {
        final adapter = FakeAdapter((request) {
          if ((!failureInReadback && request.method != 'GET') ||
              (failureInReadback && request.uri.path.endsWith('/notes/8'))) {
            return jsonResponse({}, status: 401);
          }
          return _preflight(request);
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        var calls = 0;
        final port = GitLabAiWritePort(
          api,
          accountKey: _account,
          resultClassifier:
              (prepared, {result, readback, mutationError, readbackError}) {
                calls++;
                expect(readback, isNull);
                if (failureInReadback) {
                  expect(result, isA<Map<String, dynamic>>());
                  expect(mutationError, isNull);
                  expect(readbackError, isA<ApiFailure>());
                } else {
                  expect(result, isNull);
                  expect(mutationError, isA<ApiFailure>());
                  expect(readbackError, isNull);
                }
                return _classified(prepared, 'classifiedError');
              },
        );
        final prepared = await port.prepare(_request());
        final outcome = await port.commit(prepared, mayStart: () => true);
        expect((outcome as AiWriteSettled).resultCode, 'classifiedError');
        expect(calls, 1);
        expect(adapter.requests.where((r) => r.method != 'GET'), hasLength(1));
      },
    );
  }

  for (final throwsInClassifier in [false, true]) {
    test(
      'P1 null classifier fallback and throw safety: $throwsInClassifier',
      () async {
        final api = testApi(FakeAdapter(_preflight));
        addTearDown(api.close);
        final port = GitLabAiWritePort(
          api,
          accountKey: _account,
          resultClassifier:
              (prepared, {result, readback, mutationError, readbackError}) {
                if (throwsInClassifier) throw StateError('synthetic');
                return null;
              },
        );
        final outcome = await port.commit(
          await port.prepare(_request()),
          mayStart: () => true,
        );
        expect(
          (outcome as AiWriteSettled).state,
          throwsInClassifier
              ? AiJournalState.writeUncertain
              : AiJournalState.succeeded,
        );
      },
    );
  }

  test('P1 protected createFile rises to T4; obsolete saveFile does not', () {
    for (final operation in ['createFile', 'saveFile']) {
      final decision = decideTier(
        AiTierInput(
          level: AiAutonomyLevel.conversationGrant,
          capability: AiCapability(
            operationId: operation,
            baseTier: AiWriteTier.t3,
            scopeClass: AiScopeClass.project,
          ),
          scope: _scope,
          binding: const AiBindingResult(
            userMessage: '',
            allBound: true,
            intentAuthorizesLowRisk: true,
          ),
          target: AiTargetRef(kind: AiTargetKind.file, projectId: 9),
          facts: const AiTierFacts(protectedOrDefaultBranch: true),
          typedName: 'main',
        ),
      );
      expect(
        decision.tier,
        operation == 'createFile' ? AiWriteTier.t4 : AiWriteTier.t3,
      );
    }
  });
}
