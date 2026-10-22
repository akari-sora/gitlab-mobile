import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';

import '../support/fake_adapter.dart';

typedef _DeleteCall = Future<void> Function(GitLabApi api);

final class _DeleteCase {
  const _DeleteCase(this.name, this.path, this.uri, this.wrapper);

  final String name;
  final List<String> path;
  final String uri;
  final _DeleteCall wrapper;
}

Future<int> _legacyEffectiveProjectAccess(
  GitLabApi api,
  int project,
  int userId,
) async {
  try {
    final member = await api.record([
      'projects',
      '$project',
      'members',
      'all',
      '$userId',
    ]);
    return member['access_level'] is int ? member['access_level'] as int : 0;
  } on ApiFailure catch (failure) {
    if (failure.status == 404) return 0;
    rethrow;
  }
}

void _expectSameWire(RequestOptions actual, RequestOptions legacy) {
  expect(actual.method, legacy.method);
  expect(actual.uri.toString(), legacy.uri.toString());
  expect(actual.uri.path, legacy.uri.path);
  expect(actual.uri.query, legacy.uri.query);
  expect(actual.data, legacy.data);
  expect(jsonEncode(actual.data), jsonEncode(legacy.data));
  expect(actual.followRedirects, legacy.followRedirects);
}

void main() {
  for (final method in const [
    'deletePackage',
    'deletePackageFile',
    'deleteContainerRepository',
    'deleteContainerTag',
    'effectiveProjectAccess',
  ]) {
    test('P15 registry wiring uses $method at every call site', () {
      final source = File(
        'lib/features/workspace/registries_page.dart',
      ).readAsStringSync();
      expect(
        RegExp('\\.$method\\s*\\(').allMatches(source),
        hasLength(method == 'effectiveProjectAccess' ? 3 : 1),
      );
    });
  }

  test('P15 registry wiring has no generic deletes or local access helper', () {
    final source = File(
      'lib/features/workspace/registries_page.dart',
    ).readAsStringSync();

    expect(source, isNot(contains('.removeRecord(')));
    expect(source, isNot(contains('_effectiveAccess(')));
  });

  final deletes = <_DeleteCase>[
    _DeleteCase(
      'package',
      const ['projects', '42', 'packages', '10'],
      'https://example.com/gitlab/api/v4/projects/42/packages/10',
      (api) => api.deletePackage(42, 10),
    ),
    _DeleteCase(
      'package file',
      const ['projects', '42', 'packages', '10', 'package_files', '11'],
      'https://example.com/gitlab/api/v4/projects/42/packages/10/package_files/11',
      (api) => api.deletePackageFile(42, 10, 11),
    ),
    _DeleteCase(
      'container repository',
      const ['projects', '42', 'registry', 'repositories', '12'],
      'https://example.com/gitlab/api/v4/projects/42/registry/repositories/12',
      (api) => api.deleteContainerRepository(42, 12),
    ),
    _DeleteCase(
      'container tag',
      const [
        'projects',
        '42',
        'registry',
        'repositories',
        '12',
        'tags',
        'v1/#tag',
      ],
      'https://example.com/gitlab/api/v4/projects/42/registry/repositories/12/tags/v1%2F%23tag',
      (api) => api.deleteContainerTag(42, 12, 'v1/#tag'),
    ),
  ];

  for (final deletion in deletes) {
    test(
      '${deletion.name} wrapper preserves the generic delete wire',
      () async {
        final wrapperAdapter = FakeAdapter(
          (_) => ResponseBody.fromString('', 204),
        );
        final legacyAdapter = FakeAdapter(
          (_) => ResponseBody.fromString('', 204),
        );
        final wrapperApi = testApi(wrapperAdapter);
        final legacyApi = testApi(legacyAdapter);
        addTearDown(wrapperApi.close);
        addTearDown(legacyApi.close);

        await deletion.wrapper(wrapperApi);
        await legacyApi.removeRecord(deletion.path);

        final request = wrapperAdapter.requests.single;
        _expectSameWire(request, legacyAdapter.requests.single);
        expect(request.method, 'DELETE');
        expect(request.uri.toString(), deletion.uri);
        expect(request.uri.pathSegments, [
          'gitlab',
          'api',
          'v4',
          ...deletion.path,
        ]);
        expect(request.uri.query, isEmpty);
        expect(request.data, isNull);
        expect(jsonEncode(request.data), 'null');
      },
    );
  }

  test(
    'effectiveProjectAccess preserves integer and absent access behavior',
    () async {
      for (final (body, expected) in <(Object, int)>[
        ({'access_level': 40}, 40),
        ({'access_level': '40'}, 0),
        (<String, Object?>{}, 0),
      ]) {
        final wrapperAdapter = FakeAdapter((_) => jsonResponse(body));
        final legacyAdapter = FakeAdapter((_) => jsonResponse(body));
        final wrapperApi = testApi(wrapperAdapter);
        final legacyApi = testApi(legacyAdapter);
        addTearDown(wrapperApi.close);
        addTearDown(legacyApi.close);

        expect(await wrapperApi.effectiveProjectAccess(42, 7), expected);
        expect(await _legacyEffectiveProjectAccess(legacyApi, 42, 7), expected);
        final request = wrapperAdapter.requests.single;
        _expectSameWire(request, legacyAdapter.requests.single);
        expect(request.method, 'GET');
        expect(
          request.uri.toString(),
          'https://example.com/gitlab/api/v4/projects/42/members/all/7',
        );
        expect(request.data, isNull);
        expect(jsonEncode(request.data), 'null');
      }
    },
  );

  test('effectiveProjectAccess maps only 404 to zero', () async {
    for (final status in [404, 401, 403, 500]) {
      final wrapperAdapter = FakeAdapter(
        (_) => jsonResponse(<String, Object?>{}, status: status),
      );
      final legacyAdapter = FakeAdapter(
        (_) => jsonResponse(<String, Object?>{}, status: status),
      );
      final wrapperApi = testApi(wrapperAdapter);
      final legacyApi = testApi(legacyAdapter);
      addTearDown(wrapperApi.close);
      addTearDown(legacyApi.close);

      if (status == 404) {
        expect(await wrapperApi.effectiveProjectAccess(42, 7), 0);
        expect(await _legacyEffectiveProjectAccess(legacyApi, 42, 7), 0);
      } else {
        final statusMatcher = isA<ApiFailure>().having(
          (failure) => failure.status,
          'status',
          status,
        );
        await expectLater(
          wrapperApi.effectiveProjectAccess(42, 7),
          throwsA(statusMatcher),
        );
        await expectLater(
          _legacyEffectiveProjectAccess(legacyApi, 42, 7),
          throwsA(statusMatcher),
        );
      }

      _expectSameWire(
        wrapperAdapter.requests.single,
        legacyAdapter.requests.single,
      );
      expect(wrapperAdapter.requests, hasLength(1));
      expect(legacyAdapter.requests, hasLength(1));
    }
  });
}
