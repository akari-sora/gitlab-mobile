import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';

import '../support/fake_adapter.dart';

const _sha = 'ce013625030ba8dba906f756967f9e9ca394464a';
const _binding = DiskBinding(
  accountKey: 'https://example.com/gitlab#1',
  generation: 1,
);

void main() {
  test(
    'proxy tree 404 remains indeterminate after numeric project succeeds',
    () async {
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/projects/42')) {
          return jsonResponse({'id': 42});
        }
        return ResponseBody.fromString(
          '<html>proxy</html>',
          404,
          headers: {
            'content-type': ['text/html'],
          },
        );
      });
      final api = testApi(adapter)
        ..bindReadCache(_binding.accountKey, _binding.generation);
      final losses = <OfflineAccessLoss>[];
      api.bindOfflineAccess(
        binding: _binding,
        onAccessLoss: losses.add,
        onValidatedJson: (_) {},
      );
      addTearDown(api.close);
      await expectLater(
        api.offlineCommitAvailable(projectId: 42, sha: _sha),
        throwsA(
          isA<ApiFailure>().having(
            (e) => e.kind,
            'kind',
            FailureKind.invalidResponse,
          ),
        ),
      );
      expect(adapter.requests, hasLength(2));
      expect(losses, isEmpty);
    },
  );

  for (final commitGone in [false, true]) {
    test(
      'ref 404 probes numeric project then saved SHA: commitGone=$commitGone',
      () async {
        final adapter = FakeAdapter((request) {
          if (request.uri.path.endsWith('/branches/main')) {
            return jsonResponse({'message': 'missing ref'}, status: 404);
          }
          if (request.uri.path.endsWith('/projects/42')) {
            return jsonResponse({'id': 42});
          }
          return commitGone
              ? jsonResponse({'message': 'missing commit'}, status: 404)
              : jsonResponse([]);
        });
        final api = testApi(adapter)
          ..bindReadCache(_binding.accountKey, _binding.generation);
        final losses = <OfflineAccessLoss>[];
        api.bindOfflineAccess(
          binding: _binding,
          onAccessLoss: losses.add,
          onValidatedJson: (_) {},
        );
        addTearDown(api.close);
        final result = await api.probeOfflineVersion(
          projectId: 42,
          kind: OfflineRefKind.branch,
          name: 'main',
          sha: _sha,
        );
        expect(
          result.state,
          commitGone
              ? OfflineVersionState.commitGone
              : OfflineVersionState.refGone,
        );
        expect(adapter.requests, hasLength(3));
        expect(adapter.requests.last.uri.queryParameters, {
          'ref': _sha,
          'per_page': '1',
        });
        expect(losses, isEmpty);
      },
    );
  }

  test(
    'numeric project JSON 404 fences and stops the version fallback',
    () async {
      final adapter = FakeAdapter(
        (_) => jsonResponse({'message': 'not found'}, status: 404),
      );
      final api = testApi(adapter)
        ..bindReadCache(_binding.accountKey, _binding.generation);
      final losses = <OfflineAccessLoss>[];
      api.bindOfflineAccess(
        binding: _binding,
        onAccessLoss: losses.add,
        onValidatedJson: (_) {},
      );
      addTearDown(api.close);
      await expectLater(
        api.probeOfflineVersion(
          projectId: 42,
          kind: OfflineRefKind.tag,
          name: 'v1',
          sha: _sha,
        ),
        throwsA(isA<ApiFailure>()),
      );
      expect(adapter.requests, hasLength(2));
      expect(losses, hasLength(1));
      expect(losses.single.projectId, 42);
      expect(losses.single.scope, OfflineAccessScope.project);
    },
  );

  test(
    'known alias refusal schedules numeric probe without direct access loss',
    () async {
      var denied = false;
      final adapter = FakeAdapter(
        (_) => denied
            ? jsonResponse({'message': 'forbidden'}, status: 403)
            : jsonResponse({'id': 42, 'path_with_namespace': 'team/project'}),
      );
      final api = testApi(adapter)
        ..bindReadCache(_binding.accountKey, _binding.generation);
      final losses = <OfflineAccessLoss>[];
      final probes = <(DiskBinding, int)>[];
      api.bindOfflineAccess(
        binding: _binding,
        onAccessLoss: losses.add,
        onValidatedJson: (_) {},
        onAmbiguousAccessLoss: (owner, id) => probes.add((owner, id)),
      );
      addTearDown(api.close);
      await api.cachedRecord(['projects', 'team/project']);
      denied = true;
      await expectLater(
        api.record(['projects', 'team/project']),
        throwsA(isA<ApiFailure>()),
      );
      expect(losses, isEmpty);
      expect(probes, [(_binding, 42)]);
      await expectLater(
        api.record(['projects', 'unknown/project']),
        throwsA(isA<ApiFailure>()),
      );
      expect(probes, hasLength(1));
    },
  );

  for (final cancelled in [false, true]) {
    test(
      'partial archive JSON refusal is bounded: cancelled=$cancelled',
      () async {
        final listening = Completer<void>();
        late StreamController<Uint8List> body;
        body = StreamController<Uint8List>(
          onListen: () {
            body.add(Uint8List.fromList(utf8.encode('{"message":')));
            listening.complete();
          },
        );
        final adapter = FakeAdapter((request) {
          if (request.uri.path.endsWith('/branches/main')) {
            return jsonResponse({
              'commit': {'id': _sha},
            });
          }
          return ResponseBody(
            body.stream,
            403,
            headers: {
              'content-type': ['application/json'],
            },
          );
        });
        final api = testApi(adapter)
          ..bindReadCache(_binding.accountKey, _binding.generation);
        final losses = <OfflineAccessLoss>[];
        api.bindOfflineAccess(
          binding: _binding,
          onAccessLoss: losses.add,
          onValidatedJson: (_) {},
        );
        final token = CancelToken();
        try {
          await api.resolveOfflineRef(
            projectId: 42,
            kind: OfflineRefKind.branch,
            name: 'main',
          );
          final watch = Stopwatch()..start();
          final result = api.repositoryArchive(
            projectId: 42,
            sha: _sha,
            cancelToken: token,
          );
          final checked = expectLater(
            result.timeout(const Duration(seconds: 7)),
            throwsA(
              isA<ApiFailure>().having(
                (error) => error.kind,
                'kind',
                cancelled ? FailureKind.cancelled : FailureKind.forbidden,
              ),
            ),
          );
          await listening.future;
          if (cancelled) token.cancel();
          await checked;
          expect(watch.elapsed, lessThan(Duration(seconds: cancelled ? 2 : 7)));
          if (!cancelled) {
            expect(
              watch.elapsed,
              greaterThanOrEqualTo(const Duration(seconds: 5)),
            );
          }
          expect(losses, isEmpty);
        } finally {
          token.cancel();
          api.close();
          await body.close();
        }
      },
      timeout: const Timeout(Duration(seconds: 12)),
    );
  }
}
