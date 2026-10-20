import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/shared/markdown_media_source.dart';

import 'support/fake_adapter.dart';

Matcher failure(FailureKind kind) =>
    isA<ApiFailure>().having((value) => value.kind, 'kind', kind);

void main() {
  final instance = GitLabInstance.parse('https://example.com/gitlab');
  final projectWeb = Uri.parse('https://example.com/gitlab/team/project');
  final base = Uri.parse(
    'https://example.com/gitlab/team/project/-/blob/${'a' * 40}/docs/readme.md',
  );

  group('Markdown media resolver', () {
    MarkdownMediaSource resolve(String value) => resolveMarkdownMedia(
      Uri.parse(value),
      base: base,
      instance: instance,
      projectId: 42,
      projectWeb: projectWeb,
    );

    test('pins relative, root-relative and parent paths to the blob ref', () {
      final relative = resolve('images/shot.png');
      expect(relative.kind, MarkdownMediaSourceKind.repository);
      expect(relative.project, '42');
      expect(relative.path, 'docs/images/shot.png');
      expect(relative.ref, 'a' * 40);

      expect(resolve('/logo.png').path, 'logo.png');
      expect(resolve('../logo.png').path, 'logo.png');
      expect(
        resolve('../../../logo.png').kind,
        MarkdownMediaSourceKind.blocked,
      );
    });

    test('recognises same-instance raw and raw blob URLs', () {
      final raw = resolve(
        'https://example.com/gitlab/other/repo/-/raw/main/assets/a.png',
      );
      expect(raw.kind, MarkdownMediaSourceKind.repository);
      expect(raw.project, 'other/repo');
      expect(raw.ref, 'main');
      expect(raw.path, 'assets/a.png');

      final blob = resolve(
        'https://example.com/gitlab/team/project/-/blob/dev/a.svg?raw=true',
      );
      expect(blob.kind, MarkdownMediaSourceKind.repository);
      expect(blob.project, '42');
      expect(blob.ref, 'dev');
      expect(blob.path, 'a.svg');
      expect(
        resolve(
          'https://example.com/gitlab/team/project/-/blob/dev/a.svg',
        ).kind,
        MarkdownMediaSourceKind.external,
      );
    });

    test('keeps uploads on the existing authenticated project path', () {
      const secret = '0123456789abcdef0123456789abcdef';
      final source = resolve('/uploads/$secret/demo.mp4');
      expect(source.kind, MarkdownMediaSourceKind.upload);
      expect(source.project, '42');
      expect(source.path, '$secret/demo.mp4');
      expect(source.filename, 'demo.mp4');
    });

    test('malformed escapes fail closed without decoding a filename', () {
      const secret = '0123456789abcdef0123456789abcdef';
      final source = resolve('/uploads/$secret/%FF.png');
      expect(source.kind, MarkdownMediaSourceKind.blocked);
      expect(source.filename, isNull);
    });

    test('allows bounded base64 images and blocks unsafe schemes and IPs', () {
      final data = resolve('data:image/png;base64,AQID');
      expect(data.kind, MarkdownMediaSourceKind.data);
      expect(data.bytes, Uint8List.fromList([1, 2, 3]));
      expect(
        resolve('data:text/plain;base64,AQID').kind,
        MarkdownMediaSourceKind.blocked,
      );
      final oversized = base64Encode(Uint8List(5 * 1024 * 1024 + 1));
      expect(
        resolve('data:image/png;base64,$oversized').kind,
        MarkdownMediaSourceKind.blocked,
      );
      expect(
        resolve('http://cdn.example/a.png').kind,
        MarkdownMediaSourceKind.blocked,
      );
      expect(
        resolve('https://127.0.0.1/a.png').kind,
        MarkdownMediaSourceKind.blocked,
      );
      expect(
        resolve('https://[::1]/a.png').kind,
        MarkdownMediaSourceKind.blocked,
      );
      expect(
        resolve('https://[::ffff:127.0.0.1]/a.png').kind,
        MarkdownMediaSourceKind.blocked,
      );
      expect(
        resolve('https://cdn.example/a.png').kind,
        MarkdownMediaSourceKind.external,
      );
      expect(
        resolve('https://other.example/a.png').kind,
        MarkdownMediaSourceKind.external,
      );
    });
  });

  group('Markdown media transport', () {
    test('repository bytes use authenticated raw API with progress', () async {
      final adapter = FakeAdapter(
        (_) => ResponseBody.fromBytes(
          [1, 2, 3],
          200,
          headers: {
            'content-length': ['3'],
          },
        ),
      );
      final api = testApi(adapter);
      final loader = MarkdownMediaLoader(api: api);
      addTearDown(loader.close);
      addTearDown(api.close);
      final progress = <(int, int?)>[];

      final bytes = await loader.load(
        MarkdownMediaSource(
          kind: MarkdownMediaSourceKind.repository,
          project: 'other/repo',
          ref: 'main',
          path: 'assets/a.png',
        ),
        onProgress: (received, total) => progress.add((received, total)),
      );

      expect(bytes, [1, 2, 3]);
      final request = adapter.requests.single;
      expect(request.headers['PRIVATE-TOKEN'], 'synthetic-test-token');
      expect(request.followRedirects, isFalse);
      expect(request.uri.pathSegments[4], 'other/repo');
      expect(request.uri.pathSegments[7], 'assets/a.png');
      expect(request.uri.queryParameters['ref'], 'main');
      expect(progress.last, (3, 3));
    });

    test('repository raw method enforces caller budget', () async {
      final adapter = FakeAdapter(
        (_) => ResponseBody.fromBytes(
          [1, 2, 3],
          200,
          headers: {
            'content-length': ['3'],
          },
        ),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      await expectLater(
        api.rawFileBytes('42', 'main', 'a.png', maxBytes: 2),
        throwsA(failure(FailureKind.tooLarge)),
      );
      expect(adapter.requests.single.followRedirects, isFalse);
    });

    test(
      'external client sends no GitLab credential and validates type',
      () async {
        final adapter = FakeAdapter(
          (_) => ResponseBody.fromBytes(
            [4, 5],
            200,
            headers: {
              'content-type': ['image/png'],
              'content-length': ['2'],
            },
          ),
        );
        final dio =
            Dio(
                BaseOptions(
                  headers: {
                    'PRIVATE-TOKEN': 'must-not-leak',
                    'Cookie': 'session=must-not-leak',
                  },
                  queryParameters: {'private_token': 'must-not-leak'},
                ),
              )
              ..interceptors.add(
                InterceptorsWrapper(
                  onRequest: (options, handler) {
                    options.headers['Authorization'] = 'Bearer must-not-leak';
                    handler.next(options);
                  },
                ),
              )
              ..httpClientAdapter = adapter;
        final loader = MarkdownMediaLoader(external: dio);
        addTearDown(loader.close);
        final bytes = await loader.load(
          MarkdownMediaSource(
            kind: MarkdownMediaSourceKind.external,
            uri: Uri.parse('https://cdn.example/a.png'),
          ),
        );
        expect(bytes, [4, 5]);
        final request = adapter.requests.single;
        expect(request.headers['PRIVATE-TOKEN'], isNull);
        expect(request.headers['Authorization'], isNull);
        expect(request.headers['Cookie'], isNull);
        expect(request.uri.queryParameters['private_token'], isNull);
        expect(request.followRedirects, isFalse);

        final wrongType = FakeAdapter(
          (_) => ResponseBody.fromString(
            'html',
            200,
            headers: {
              'content-type': ['text/html'],
            },
          ),
        );
        final wrongLoader = MarkdownMediaLoader(
          external: Dio()..httpClientAdapter = wrongType,
        );
        addTearDown(wrongLoader.close);
        await expectLater(
          wrongLoader.load(
            MarkdownMediaSource(
              kind: MarkdownMediaSourceKind.external,
              uri: Uri.parse('https://cdn.example/a.png'),
            ),
          ),
          throwsA(isA<MarkdownMediaNotImage>()),
        );
      },
    );

    test('external redirects stay HTTPS and reject private IP hops', () async {
      final adapter = FakeAdapter((request) {
        if (request.uri.host == 'cdn.example') {
          return ResponseBody.fromString(
            '',
            302,
            headers: {
              'location': ['https://192.168.1.2/a.png'],
            },
          );
        }
        throw StateError('private redirect must not be requested');
      });
      final loader = MarkdownMediaLoader(
        external: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(loader.close);
      await expectLater(
        loader.load(
          MarkdownMediaSource(
            kind: MarkdownMediaSourceKind.external,
            uri: Uri.parse('https://cdn.example/a.png'),
          ),
        ),
        throwsA(failure(FailureKind.redirectBlocked)),
      );
      expect(adapter.requests, hasLength(1));
    });

    test('external redirect chain stops after three hops', () async {
      final adapter = FakeAdapter(
        (request) => ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': ['/next-${request.uri.pathSegments.length}'],
          },
        ),
      );
      final loader = MarkdownMediaLoader(
        external: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(loader.close);
      await expectLater(
        loader.load(
          MarkdownMediaSource(
            kind: MarkdownMediaSourceKind.external,
            uri: Uri.parse('https://cdn.example/start.png'),
          ),
        ),
        throwsA(failure(FailureKind.redirectBlocked)),
      );
      expect(adapter.requests, hasLength(4));
    });

    test(
      'external streamed body enforces budget without content length',
      () async {
        final adapter = FakeAdapter(
          (_) => ResponseBody(
            Stream<Uint8List>.fromIterable([
              Uint8List(5 * 1024 * 1024),
              Uint8List(1),
            ]),
            200,
            headers: {
              'content-type': ['image/png'],
            },
          ),
        );
        final loader = MarkdownMediaLoader(
          external: Dio()..httpClientAdapter = adapter,
        );
        addTearDown(loader.close);
        await expectLater(
          loader.load(
            MarkdownMediaSource(
              kind: MarkdownMediaSourceKind.external,
              uri: Uri.parse('https://cdn.example/large.png'),
            ),
          ),
          throwsA(failure(FailureKind.tooLarge)),
        );
      },
    );

    test(
      'optional sink streams bytes without closing the caller sink',
      () async {
        final adapter = FakeAdapter(
          (_) => ResponseBody.fromBytes(
            [1, 2, 3],
            200,
            headers: {
              'content-type': ['video/mp4'],
            },
          ),
        );
        final loader = MarkdownMediaLoader(
          external: Dio()..httpClientAdapter = adapter,
        );
        addTearDown(loader.close);
        final builder = BytesBuilder(copy: false);
        final sink = IOSink(_TestConsumer(builder));
        final returned = await loader.load(
          MarkdownMediaSource(
            kind: MarkdownMediaSourceKind.external,
            uri: Uri.parse('https://cdn.example/movie.mp4'),
          ),
          image: false,
          sink: sink,
        );
        expect(returned, isEmpty);
        sink.add([4]);
        await sink.close();
        expect(builder.takeBytes(), [1, 2, 3, 4]);
      },
    );

    test('upload media uses the bounded project upload API', () async {
      const secret = '0123456789abcdef0123456789abcdef';
      final adapter = FakeAdapter(
        (_) => ResponseBody.fromBytes(
          [7, 8],
          200,
          headers: {
            'content-length': ['2'],
          },
        ),
      );
      final api = testApi(adapter);
      final loader = MarkdownMediaLoader(api: api);
      addTearDown(loader.close);
      addTearDown(api.close);
      final bytes = await loader.load(
        const MarkdownMediaSource(
          kind: MarkdownMediaSourceKind.upload,
          project: '42',
          path: '$secret/demo.mp4',
        ),
        image: false,
      );
      expect(bytes, [7, 8]);
      expect(
        adapter.requests.single.uri.path,
        '/gitlab/api/v4/projects/42/uploads/$secret/demo.mp4',
      );
    });

    test('caller cancellation reaches authenticated transport', () async {
      final started = Completer<void>();
      final pending = Completer<ResponseBody>();
      final adapter = FakeAdapter((_) {
        started.complete();
        return pending.future;
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final token = CancelToken();
      final request = api.rawFileBytes(
        '42',
        'main',
        'a.png',
        cancelToken: token,
      );
      final cancelled = expectLater(
        request,
        throwsA(failure(FailureKind.cancelled)),
      );
      await started.future;
      token.cancel();
      pending.completeError(
        DioException(
          requestOptions: RequestOptions(),
          type: DioExceptionType.cancel,
        ),
      );
      await cancelled;
      expect(adapter.cancelFutures.single, isNotNull);
    });

    test('loader close cancels repository and external transports', () async {
      final repositoryStarted = Completer<void>();
      final repositoryPending = Completer<ResponseBody>();
      final repositoryAdapter = FakeAdapter((_) {
        repositoryStarted.complete();
        return repositoryPending.future;
      });
      final api = testApi(repositoryAdapter);
      addTearDown(api.close);
      final repositoryLoader = MarkdownMediaLoader(api: api);
      final repositoryRequest = repositoryLoader.load(
        const MarkdownMediaSource(
          kind: MarkdownMediaSourceKind.repository,
          project: '42',
          ref: 'main',
          path: 'movie.mp4',
        ),
        image: false,
      );
      final repositoryCancelled = expectLater(
        repositoryRequest,
        throwsA(failure(FailureKind.cancelled)),
      );
      await repositoryStarted.future;
      repositoryLoader.close();
      repositoryPending.completeError(
        DioException(
          requestOptions: RequestOptions(),
          type: DioExceptionType.cancel,
        ),
      );
      await repositoryCancelled;

      final externalStarted = Completer<void>();
      final externalPending = Completer<ResponseBody>();
      final externalAdapter = FakeAdapter((_) {
        externalStarted.complete();
        return externalPending.future;
      });
      final externalLoader = MarkdownMediaLoader(
        external: Dio()..httpClientAdapter = externalAdapter,
      );
      final externalRequest = externalLoader.load(
        MarkdownMediaSource(
          kind: MarkdownMediaSourceKind.external,
          uri: Uri.parse('https://cdn.example/movie.mp4'),
        ),
        image: false,
      );
      final externalCancelled = expectLater(
        externalRequest,
        throwsA(failure(FailureKind.cancelled)),
      );
      await externalStarted.future;
      externalLoader.close();
      externalPending.completeError(
        DioException(
          requestOptions: RequestOptions(),
          type: DioExceptionType.cancel,
        ),
      );
      await externalCancelled;
    });
  });
}

final class _TestConsumer implements StreamConsumer<List<int>> {
  const _TestConsumer(this.builder);
  final BytesBuilder builder;

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      builder.add(chunk);
    }
  }

  @override
  Future<void> close() async {}
}
