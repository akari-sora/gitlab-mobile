import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/core/registry_models.dart';

import 'support/fake_adapter.dart';

const _sha = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _package = RegistryPackage(
  id: 12,
  name: 'mobile-kit',
  version: '1.2.3',
  type: 'generic',
  status: 'default',
  createdAt: '',
  canDelete: false,
);
const _file = RegistryPackageFile(
  id: 34,
  name: 'SHA256SUMS',
  size: 185,
  createdAt: '',
  sha256: _sha,
);

Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((value) => value.kind, 'kind', kind);

Map<String, Object?> _packageJson({
  int id = 12,
  String name = 'mobile-kit',
  Object? version = '1.2.3',
  String type = 'generic',
}) => {
  'id': id,
  'name': name,
  'version': version,
  'package_type': type,
  'status': 'default',
};

Map<String, Object?> _fileJson({
  int id = 34,
  String name = 'SHA256SUMS',
  Object? size = 185,
  Object? sha = _sha,
}) => {'id': id, 'file_name': name, 'size': size, 'file_sha256': sha};

String _apiPath(RequestOptions request) {
  final parts = request.uri.pathSegments;
  return parts.skip(parts.indexOf('v4') + 1).join('/');
}

final class _Sink implements IOSink {
  final bytes = BytesBuilder(copy: false);
  bool closed = false;

  @override
  Encoding encoding = utf8;
  @override
  void add(List<int> data) => bytes.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> close() async => closed = true;
  @override
  Future<void> flush() async {}
  @override
  Future<void> get done async {}
  @override
  void write(Object? object) => add(utf8.encode('$object'));
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      write(objects.join(separator));
  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));
  @override
  void writeln([Object? object = '']) => write('$object\n');
}

void main() {
  test('fresh metadata uses exact package and bounded file routes', () async {
    final adapter = FakeAdapter((request) {
      switch (_apiPath(request)) {
        case 'projects/8/packages/12':
          return jsonResponse(_packageJson());
        case 'projects/8/packages/12/package_files':
          expect(request.uri.queryParameters['per_page'], '100');
          return jsonResponse([_fileJson()]);
      }
      return jsonResponse({'error': 'unexpected'}, status: 404);
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    final result = await api.packageFileForDownload(
      8,
      _package,
      _file,
      isCurrent: () => true,
    );

    expect(result.id, 34);
    expect(result.sha256, _sha);
    expect(adapter.requests, hasLength(2));
    expect(
      adapter.requests.every(
        (request) => request.headers['Cache-Control'] == 'no-store',
      ),
      isTrue,
    );
  });

  test('versionless package identity is valid and remains exact', () async {
    const expected = RegistryPackage(
      id: 12,
      name: 'mobile-kit',
      version: '',
      type: 'generic',
      status: '',
      createdAt: '',
      canDelete: false,
    );
    final adapter = FakeAdapter(
      (request) => _apiPath(request).endsWith('/12')
          ? jsonResponse(_packageJson(version: null))
          : jsonResponse([_fileJson()]),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    expect(
      (await api.packageFileForDownload(
        8,
        expected,
        _file,
        isCurrent: () => true,
      )).id,
      34,
    );
  });

  test(
    'package identity changes and malformed numeric identity fail closed',
    () async {
      for (final entry in <(Map<String, Object?>, FailureKind)>[
        (_packageJson(name: 'replacement'), FailureKind.conflict),
        (_packageJson(id: 99), FailureKind.invalidResponse),
        (
          {..._packageJson()}..remove('package_type'),
          FailureKind.invalidResponse,
        ),
        ({..._packageJson(), 'id': '12'}, FailureKind.invalidResponse),
      ]) {
        final api = testApi(
          FakeAdapter(
            (request) => _apiPath(request).endsWith('/12')
                ? jsonResponse(entry.$1)
                : jsonResponse([_fileJson()]),
          ),
        );
        await expectLater(
          api.packageFileForDownload(8, _package, _file, isCurrent: () => true),
          throwsA(_failure(entry.$2)),
        );
        api.close();
      }
    },
  );

  test('file identity, size, and canonical sha256 are required', () async {
    for (final entry in <(Map<String, Object?>, FailureKind)>[
      (_fileJson(name: 'other'), FailureKind.conflict),
      (_fileJson(size: 184), FailureKind.conflict),
      (
        _fileJson(
          sha:
              '1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        ),
        FailureKind.conflict,
      ),
      (_fileJson(size: -1), FailureKind.unsupported),
      (
        _fileJson(size: GitLabApi.maxArtifactBytes + 1),
        FailureKind.unsupported,
      ),
      (_fileJson(size: '185'), FailureKind.invalidResponse),
      ({..._fileJson()}..remove('size'), FailureKind.invalidResponse),
      (_fileJson(sha: null), FailureKind.invalidResponse),
      (_fileJson(sha: _sha.toUpperCase()), FailureKind.invalidResponse),
      (
        _fileJson(sha: List.filled(63, '0').join()),
        FailureKind.invalidResponse,
      ),
    ]) {
      final api = testApi(
        FakeAdapter(
          (request) => _apiPath(request).endsWith('/12')
              ? jsonResponse(_packageJson())
              : jsonResponse([entry.$1]),
        ),
      );
      await expectLater(
        api.packageFileForDownload(8, _package, _file, isCurrent: () => true),
        throwsA(_failure(entry.$2)),
      );
      api.close();
    }
  });

  test(
    'a zero-byte file with a canonical checksum remains downloadable',
    () async {
      final adapter = FakeAdapter(
        (request) => _apiPath(request).endsWith('/12')
            ? jsonResponse(_packageJson())
            : jsonResponse([_fileJson(size: 0)]),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      const zeroFile = RegistryPackageFile(
        id: 34,
        name: 'SHA256SUMS',
        size: 0,
        createdAt: '',
        sha256: _sha,
      );
      final result = await api.packageFileForDownload(
        8,
        _package,
        zeroFile,
        isCurrent: () => true,
      );
      expect(result.size, 0);
    },
  );

  test('metadata pagination is capped at 200 inspected rows', () async {
    final adapter = FakeAdapter((request) {
      if (_apiPath(request).endsWith('/12')) {
        return jsonResponse(_packageJson());
      }
      final page = request.uri.queryParameters['page'] ?? '1';
      final offset = page == '1' ? 1000 : 2000;
      final rows = List.generate(
        100,
        (index) => _fileJson(id: offset + index, name: 'file-$index'),
      );
      return jsonResponse(
        rows,
        headers: {
          'x-next-page': [page == '1' ? '2' : '3'],
        },
      );
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    await expectLater(
      api.packageFileForDownload(8, _package, _file, isCurrent: () => true),
      throwsA(_failure(FailureKind.unsupported)),
    );
    expect(
      adapter.requests,
      hasLength(3),
      reason: 'package plus two file pages',
    );
  });

  test(
    'selected first-page file stops before an oversized later page',
    () async {
      final adapter = FakeAdapter((request) {
        if (_apiPath(request).endsWith('/12')) {
          return jsonResponse(_packageJson());
        }
        if (request.uri.queryParameters['page'] == null) {
          return jsonResponse(
            [_fileJson()],
            headers: {
              'x-next-page': ['2'],
            },
          );
        }
        return jsonResponse(
          List.generate(
            101,
            (index) => _fileJson(id: 1000 + index, name: 'later-$index'),
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      expect(
        (await api.packageFileForDownload(
          8,
          _package,
          _file,
          isCurrent: () => true,
        )).id,
        _file.id,
      );
      expect(
        adapter.requests,
        hasLength(2),
        reason: 'package plus selected page',
      );
    },
  );

  test('selected page is fully checked for duplicate file ids', () async {
    final api = testApi(
      FakeAdapter(
        (request) => _apiPath(request).endsWith('/12')
            ? jsonResponse(_packageJson())
            : jsonResponse([_fileJson(), _fileJson(name: 'duplicate-name')]),
      ),
    );
    addTearDown(api.close);
    await expectLater(
      api.packageFileForDownload(8, _package, _file, isCurrent: () => true),
      throwsA(_failure(FailureKind.invalidResponse)),
    );
  });

  test('replayed page cursor is invalid and never loops', () async {
    final adapter = FakeAdapter((request) {
      if (_apiPath(request).endsWith('/12')) {
        return jsonResponse(_packageJson());
      }
      return jsonResponse(
        [_fileJson(id: 90, name: 'other')],
        headers: {
          'x-next-page': ['2'],
        },
      );
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    await expectLater(
      api.packageFileForDownload(8, _package, _file, isCurrent: () => true),
      throwsA(_failure(FailureKind.invalidResponse)),
    );
    expect(adapter.requests.length, lessThanOrEqualTo(3));
  });

  test('empty pagination chains and oversized pages stay bounded', () async {
    final emptyAdapter = FakeAdapter((request) {
      if (_apiPath(request).endsWith('/12')) {
        return jsonResponse(_packageJson());
      }
      final page = int.tryParse(request.uri.queryParameters['page'] ?? '1')!;
      return jsonResponse(
        [],
        headers: {
          'x-next-page': ['${page + 1}'],
        },
      );
    });
    final emptyApi = testApi(emptyAdapter);
    await expectLater(
      emptyApi.packageFileForDownload(
        8,
        _package,
        _file,
        isCurrent: () => true,
      ),
      throwsA(_failure(FailureKind.unsupported)),
    );
    expect(emptyAdapter.requests, hasLength(11));
    emptyApi.close();

    final largeApi = testApi(
      FakeAdapter(
        (request) => _apiPath(request).endsWith('/12')
            ? jsonResponse(_packageJson())
            : jsonResponse(
                List.generate(
                  101,
                  (index) => _fileJson(id: 1000 + index, name: 'file-$index'),
                ),
              ),
      ),
    );
    await expectLater(
      largeApi.packageFileForDownload(
        8,
        _package,
        _file,
        isCurrent: () => true,
      ),
      throwsA(_failure(FailureKind.invalidResponse)),
    );
    largeApi.close();
  });

  test('owner is checked after every await and close also cancels', () async {
    var current = true;
    final packageGate = Completer<void>();
    final adapter = FakeAdapter((request) async {
      if (_apiPath(request).endsWith('/12')) {
        await packageGate.future;
        return jsonResponse(_packageJson());
      }
      return jsonResponse([_fileJson()]);
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final pending = api.packageFileForDownload(
      8,
      _package,
      _file,
      isCurrent: () => current,
    );
    current = false;
    packageGate.complete();
    await expectLater(pending, throwsA(_failure(FailureKind.cancelled)));
    expect(adapter.requests, hasLength(1));

    api.close();
    await expectLater(
      api.packageFileForDownload(8, _package, _file, isCurrent: () => true),
      throwsA(_failure(FailureKind.cancelled)),
    );
  });

  test(
    'download uses universal numeric endpoint and selected file name',
    () async {
      final adapter = FakeAdapter(
        (request) => ResponseBody(
          Stream.value(Uint8List.fromList([1, 2, 3])),
          200,
          headers: {
            Headers.contentLengthHeader: ['3'],
            Headers.contentTypeHeader: ['text/plain'],
            'content-disposition': ['attachment; filename="attacker-name"'],
          },
        ),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      final sink = _Sink();
      final progress = <(int, int?)>[];
      final result = await api.downloadPackageFile(
        8,
        12,
        34,
        sink: sink,
        fileName: 'SHA256SUMS',
        onProgress: (received, total) => progress.add((received, total)),
      );
      expect(
        _apiPath(adapter.requests.single),
        'projects/8/packages/12/package_files/34/download',
      );
      expect(result.fileName, 'SHA256SUMS');
      expect(result.bytesWritten, 3);
      expect(sink.bytes.takeBytes(), [1, 2, 3]);
      expect(progress, [(3, 3)]);
    },
  );

  test(
    'one https redirect is credential-free and a chain is blocked',
    () async {
      const location = 'https://cdn.example.net/package/file';
      var secondRedirect = false;
      final adapter = FakeAdapter((request) {
        if (request.uri.host == 'example.com') {
          return ResponseBody.fromString(
            '',
            302,
            headers: {
              'location': [location],
            },
          );
        }
        if (secondRedirect) {
          return ResponseBody.fromString(
            '',
            302,
            headers: {
              'location': ['https://cdn.example.net/again'],
            },
          );
        }
        return ResponseBody(Stream.value(Uint8List.fromList([7])), 200);
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final first = await api.downloadPackageFile(
        8,
        12,
        34,
        sink: _Sink(),
        fileName: 'file.bin',
      );
      expect(first.bytesWritten, 1);
      final hop = adapter.requests.last;
      expect(hop.uri.toString(), location);
      final headerNames = hop.headers.keys.map((key) => key.toLowerCase());
      expect(headerNames, isNot(contains('authorization')));
      expect(headerNames, isNot(contains('private-token')));
      expect(headerNames, isNot(contains('cookie')));

      secondRedirect = true;
      await expectLater(
        api.downloadPackageFile(8, 12, 34, sink: _Sink(), fileName: 'file.bin'),
        throwsA(_failure(FailureKind.redirectBlocked)),
      );
    },
  );

  test('download validates inputs, bounds stream, cancel, and close', () async {
    final adapter = FakeAdapter(
      (_) => ResponseBody(
        Stream.fromIterable([
          Uint8List.fromList([1, 2, 3]),
          Uint8List.fromList([4, 5, 6]),
        ]),
        200,
      ),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    for (final call in <Future<ArtifactDownload>>[
      api.downloadPackageFile(0, 12, 34, sink: _Sink(), fileName: 'file'),
      api.downloadPackageFile(8, 12, 34, sink: _Sink(), fileName: '../file'),
      api.downloadPackageFile(
        8,
        12,
        34,
        sink: _Sink(),
        fileName: 'file',
        maxBytes: GitLabApi.maxArtifactBytes + 1,
      ),
    ]) {
      await expectLater(call, throwsA(_failure(FailureKind.validation)));
    }
    final bounded = _Sink();
    await expectLater(
      api.downloadPackageFile(
        8,
        12,
        34,
        sink: bounded,
        fileName: 'file',
        maxBytes: 4,
      ),
      throwsA(_failure(FailureKind.tooLarge)),
    );
    expect(bounded.closed, isTrue);

    final cancel = Completer<void>()..complete();
    await expectLater(
      api.downloadPackageFile(
        8,
        12,
        34,
        sink: _Sink(),
        fileName: 'file',
        cancel: cancel.future,
      ),
      throwsA(_failure(FailureKind.cancelled)),
    );
    api.close();
    await expectLater(
      api.downloadPackageFile(8, 12, 34, sink: _Sink(), fileName: 'file'),
      throwsA(_failure(FailureKind.cancelled)),
    );
  });

  test('404 stays ambiguous and 429 arms the local retry gate', () async {
    final missingAdapter = FakeAdapter(
      (_) => jsonResponse({'message': '404'}, status: 404),
    );
    final missingApi = testApi(missingAdapter);
    await expectLater(
      missingApi.downloadPackageFile(
        8,
        12,
        34,
        sink: _Sink(),
        fileName: 'file',
      ),
      throwsA(
        isA<ApiFailure>()
            .having((value) => value.kind, 'kind', FailureKind.invisible)
            .having((value) => value.status, 'status', 404),
      ),
    );
    expect(
      missingAdapter.requests,
      hasLength(1),
      reason: 'no guessed fallback',
    );
    missingApi.close();

    final limitedAdapter = FakeAdapter(
      (_) => jsonResponse(
        {'message': 'slow down'},
        status: 429,
        headers: const {
          'retry-after': ['60'],
        },
      ),
    );
    final limitedApi = testApi(limitedAdapter);
    for (var attempt = 0; attempt < 2; attempt++) {
      await expectLater(
        limitedApi.downloadPackageFile(
          8,
          12,
          34,
          sink: _Sink(),
          fileName: 'file',
        ),
        throwsA(_failure(FailureKind.rateLimited)),
      );
    }
    expect(limitedAdapter.requests, hasLength(1));
    limitedApi.close();
  });

  test('OAuth 401 rotates once and retries the numeric endpoint', () async {
    var downloads = 0;
    final downloadAdapter = FakeAdapter((request) {
      downloads++;
      if (downloads == 1) {
        return jsonResponse({'error': 'expired'}, status: 401);
      }
      expect(request.headers['Authorization'], 'Bearer fresh-access');
      return ResponseBody(Stream.value(Uint8List.fromList([9])), 200);
    });
    final oauthAdapter = FakeAdapter(
      (_) => jsonResponse({
        'access_token': 'fresh-access',
        'refresh_token': 'fresh-refresh',
        'expires_in': 3600,
      }),
    );
    final instance = GitLabInstance.parse('https://example.com/gitlab');
    final api = GitLabApi(
      instance: instance,
      credential: const OAuthCredential(
        accessToken: 'expired-access',
        refreshToken: 'refresh-token',
        clientId: 'mobile',
      ),
      dio: Dio()..httpClientAdapter = downloadAdapter,
      oauth: OAuthTokenClient(
        instance: instance,
        clientId: 'mobile',
        dio: Dio()..httpClientAdapter = oauthAdapter,
      ),
    );
    addTearDown(api.close);
    expect(
      (await api.downloadPackageFile(
        8,
        12,
        34,
        sink: _Sink(),
        fileName: 'file',
      )).bytesWritten,
      1,
    );
    expect(downloads, 2);
    expect(oauthAdapter.requests, hasLength(1));
  });
}
