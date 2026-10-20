import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/shared/markdown_media_source.dart';

import 'support/fake_adapter.dart';

Matcher failure(FailureKind kind) =>
    isA<ApiFailure>().having((value) => value.kind, 'kind', kind);

void main() {
  group('FIX2 Markdown source and API boundaries', () {
    test('Argon literal external host inputs are blocked', () {
      for (final value in [
        'https://0177.0.0.1/a.png',
        'https://0/a.png',
        'https://127.0.0.1./a.png',
        'https://[::ffff:0:127.0.0.1]/a.png',
      ]) {
        expect(
          resolveMarkdownMedia(Uri.parse(value)).kind,
          MarkdownMediaSourceKind.blocked,
          reason: value,
        );
      }
    });

    test('Argon encoded project and ref traversal inputs are blocked', () {
      final api = testApi(
        FakeAdapter((_) => ResponseBody.fromBytes(const [], 200)),
      );
      final instance = api.instance;
      addTearDown(api.close);
      for (final value in [
        'https://example.com/gitlab/group%2f..%2fvictim/repo/-/raw/main/a.png',
        'https://example.com/gitlab/team/project/-/raw/..%2f..%2frefs/a.png',
      ]) {
        expect(
          resolveMarkdownMedia(Uri.parse(value), instance: instance).kind,
          MarkdownMediaSourceKind.blocked,
          reason: value,
        );
      }
    });

    test(
      'rawFileBytes rejects decoded traversal and control coordinates',
      () async {
        final adapter = FakeAdapter(
          (_) => throw StateError('invalid coordinate must not be requested'),
        );
        final api = testApi(adapter);
        addTearDown(api.close);
        for (final coordinate in [
          ('group%2F..%2Fvictim', 'main', 'a.png'),
          ('group/project', '..%2Frefs', 'a.png'),
          ('group/project', 'main', 'docs%2F..%2Fsecret.png'),
          ('group/project', 'main\u0000', 'a.png'),
          ('group\\project', 'main', 'a.png'),
          ('group%5Cproject', 'main', 'a.png'),
          ('group%', 'main', 'a.png'),
          ('group/project', 'main%', 'a.png'),
          ('group/project', 'main', 'a%.png'),
        ]) {
          await expectLater(
            api.rawFileBytes(coordinate.$1, coordinate.$2, coordinate.$3),
            throwsA(failure(FailureKind.unsupported)),
            reason: '$coordinate',
          );
        }
        expect(adapter.requests, isEmpty);
      },
    );

    test(
      'malformed redirect Locations fail closed as redirectBlocked',
      () async {
        for (final location in ['http://[::1', 'https://cdn.example/%ZZ']) {
          final adapter = FakeAdapter(
            (_) => ResponseBody.fromString(
              '',
              302,
              headers: {
                'location': [location],
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
                uri: Uri.parse('https://cdn.example/a.png'),
              ),
            ),
            throwsA(failure(FailureKind.redirectBlocked)),
            reason: location,
          );
        }
      },
    );

    test('repository stalled stream reacts promptly to cancellation', () async {
      final controller = StreamController<Uint8List>();
      final adapter = FakeAdapter(
        (_) => ResponseBody(
          controller.stream,
          200,
          headers: {
            'content-type': ['video/mp4'],
          },
        ),
      );
      final api = testApi(adapter);
      final token = CancelToken();
      addTearDown(api.close);
      addTearDown(() => unawaited(controller.close()));
      final request = api.rawFileBytes(
        '42',
        'main',
        'movie.mp4',
        cancelToken: token,
      );
      await Future<void>.delayed(Duration.zero);
      token.cancel();
      await expectLater(
        request.timeout(const Duration(milliseconds: 300)),
        throwsA(failure(FailureKind.cancelled)),
      );
    });

    test('external stalled stream reacts promptly to loader close', () async {
      final controller = StreamController<Uint8List>();
      final adapter = FakeAdapter(
        (_) => ResponseBody(
          controller.stream,
          200,
          headers: {
            'content-type': ['video/mp4'],
          },
        ),
      );
      final loader = MarkdownMediaLoader(
        external: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(() => unawaited(controller.close()));
      final request = loader.load(
        MarkdownMediaSource(
          kind: MarkdownMediaSourceKind.external,
          uri: Uri.parse('https://cdn.example/movie.mp4'),
        ),
        image: false,
      );
      await Future<void>.delayed(Duration.zero);
      loader.close();
      await expectLater(
        request.timeout(const Duration(milliseconds: 300)),
        throwsA(failure(FailureKind.cancelled)),
      );
    });

    test('repository and external sinks flush once after all chunks', () async {
      final repositoryConsumer = _CountingConsumer();
      final repositorySink = IOSink(repositoryConsumer);
      final repositoryAdapter = FakeAdapter(
        (_) => ResponseBody(
          Stream<Uint8List>.fromIterable([
            Uint8List.fromList([1]),
            Uint8List.fromList([2]),
          ]),
          200,
          headers: {
            'content-type': ['video/mp4'],
          },
        ),
      );
      final api = testApi(repositoryAdapter);
      addTearDown(api.close);
      addTearDown(repositorySink.close);
      await api.rawFileBytes('42', 'main', 'movie.mp4', sink: repositorySink);
      expect(repositoryConsumer.addStreamCalls, 1);

      final externalConsumer = _CountingConsumer();
      final externalSink = IOSink(externalConsumer);
      final externalAdapter = FakeAdapter(
        (_) => ResponseBody(
          Stream<Uint8List>.fromIterable([
            Uint8List.fromList([3]),
            Uint8List.fromList([4]),
          ]),
          200,
          headers: {
            'content-type': ['video/mp4'],
          },
        ),
      );
      final loader = MarkdownMediaLoader(
        external: Dio()..httpClientAdapter = externalAdapter,
      );
      addTearDown(loader.close);
      addTearDown(externalSink.close);
      await loader.load(
        MarkdownMediaSource(
          kind: MarkdownMediaSourceKind.external,
          uri: Uri.parse('https://cdn.example/movie.mp4'),
        ),
        image: false,
        sink: externalSink,
      );
      expect(externalConsumer.addStreamCalls, 1);
    });
  });
}

final class _CountingConsumer implements StreamConsumer<List<int>> {
  int addStreamCalls = 0;

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    addStreamCalls++;
    await stream.drain<void>();
  }

  @override
  Future<void> close() async {}
}
