import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_report.dart';
import 'package:gitlab_mobile/features/ai/ai_report_sender.dart';

/// Records each request with its body as it went on the wire.
final class _FormAdapter implements HttpClientAdapter {
  _FormAdapter(this.respond);

  final FutureOr<ResponseBody> Function(
    RequestOptions options,
    Future<void>? cancelFuture,
  )
  respond;
  final requests = <RequestOptions>[];
  final bodies = <String>[];
  var closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    bodies.add(utf8.decode(bytes));
    return respond(options, cancelFuture);
  }

  @override
  void close({bool force = false}) => closed = true;
}

_FormAdapter _answering(int status) =>
    _FormAdapter((_, _) => ResponseBody.fromString('<html></html>', status));

const _fields = AiReportFormFields(
  reason: 'harmful',
  details: 'description: rude & wrong = 1+1\npreset: custom',
  excerpt: '內容 with\nlines',
  app: '0.6.0+612 (abc1234)',
);

Matcher _failure(int? status, {bool mayHaveArrived = false}) =>
    isA<AiReportPostFailure>()
        .having((f) => f.status, 'status', status)
        .having((f) => f.mayHaveArrived, 'mayHaveArrived', mayHaveArrived);

void main() {
  group('the form post', () {
    test('a 200 is a report taken; only the four answers go', () async {
      final adapter = _answering(200);

      await postAiReport(_fields, adapter: adapter);

      final request = adapter.requests.single;
      expect(request.method, 'POST');
      expect(request.uri, aiReportFormEndpoint);
      expect(request.uri.scheme, 'https');
      expect(
        request.contentType,
        startsWith(Headers.formUrlEncodedContentType),
      );
      expect(request.followRedirects, isFalse);
      expect(Uri.splitQueryString(adapter.bodies.single), _fields.form);
      final headers = request.headers.keys.map((k) => k.toLowerCase()).toSet();
      for (final credential in [
        'authorization',
        'private-token',
        'job-token',
        'cookie',
        'api-key',
        'x-api-key',
      ]) {
        expect(headers, isNot(contains(credential)));
      }
      expect(adapter.closed, isTrue);
    });

    test('a redirect is not followed and does not count as taken', () async {
      // Google answers a form that needs sign-in with a redirect to the
      // sign-in page; nothing was recorded.
      final adapter = _FormAdapter(
        (_, _) => ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': ['https://accounts.google.com/ServiceLogin'],
          },
        ),
      );

      await expectLater(
        postAiReport(_fields, adapter: adapter),
        throwsA(
          isA<AiReportPostFailure>().having((f) => f.status, 'status', 302),
        ),
      );
      expect(adapter.requests, hasLength(1));
    });

    test('the confirmation page is not read', () async {
      // A body that never ends: the post completes without reading it.
      final page = StreamController<Uint8List>();
      addTearDown(page.close);
      final adapter = _FormAdapter((_, _) => ResponseBody(page.stream, 200));

      await postAiReport(_fields, adapter: adapter);

      expect(adapter.requests, hasLength(1));
    });

    for (final status in [400, 403, 404, 429, 500, 503]) {
      test('a $status is a failure with its status', () async {
        await expectLater(
          postAiReport(_fields, adapter: _answering(status)),
          throwsA(_failure(status)),
        );
      });
    }

    test('a transport error is a failure without a status', () async {
      final adapter = _FormAdapter(
        (options, _) => throw DioException.connectionError(
          requestOptions: options,
          reason: 'offline',
        ),
      );

      await expectLater(
        postAiReport(_fields, adapter: adapter),
        throwsA(_failure(null)),
      );
      expect(adapter.closed, isTrue);
    });

    test('a form that does not answer in time is a failure', () async {
      final adapter = _FormAdapter((options, cancelFuture) async {
        await cancelFuture;
        throw DioException.requestCancelled(
          requestOptions: options,
          reason: 'deadline',
        );
      });

      await expectLater(
        postAiReport(
          _fields,
          adapter: adapter,
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(_failure(null, mayHaveArrived: true)),
      );
    });

    test('a reset after the report went out may have delivered it', () async {
      final adapter = _FormAdapter(
        (options, _) => throw DioException.receiveTimeout(
          timeout: const Duration(seconds: 15),
          requestOptions: options,
        ),
      );

      await expectLater(
        postAiReport(_fields, adapter: adapter),
        throwsA(_failure(null, mayHaveArrived: true)),
      );
    });
  });

  group('sending in the app', () {
    test('a report the form takes is not offered to mail', () async {
      final adapter = _answering(200);
      var offers = 0;
      var fallbacks = 0;

      final route = await sendAiReportInApp(
        fields: _fields,
        post: (fields) => postAiReport(fields, adapter: adapter),
        offerFallback: (_) async {
          offers++;
          return true;
        },
        fallback: () async {
          fallbacks++;
          return AiReportRoute.mail;
        },
      );

      expect(route, AiReportRoute.form);
      expect(adapter.requests, hasLength(1));
      expect(offers, 0);
      expect(fallbacks, 0);
    });

    test('a 500 is shown first, then the fallback runs', () async {
      final events = <String>[];

      final route = await sendAiReportInApp(
        fields: _fields,
        post: (fields) => postAiReport(fields, adapter: _answering(500)),
        offerFallback: (failure) async {
          events.add('offer ${failure.status}');
          return true;
        },
        fallback: () async {
          events.add('fallback');
          return AiReportRoute.mail;
        },
      );

      expect(route, AiReportRoute.mail);
      expect(events, ['offer 500', 'fallback']);
    });

    test('any other error from the post is offered the same way', () async {
      AiReportPostFailure? offered;

      final route = await sendAiReportInApp(
        fields: _fields,
        post: (_) => Future<void>.error(StateError('synthetic')),
        offerFallback: (failure) async {
          offered = failure;
          return true;
        },
        fallback: () async => AiReportRoute.share,
      );

      expect(route, AiReportRoute.share);
      expect(offered, isNotNull);
      expect(offered?.status, isNull);
    });

    test('a transport error declined hands nothing over', () async {
      final adapter = _FormAdapter(
        (options, _) => throw DioException.connectionError(
          requestOptions: options,
          reason: 'offline',
        ),
      );
      AiReportPostFailure? offered;
      var fallbacks = 0;

      final route = await sendAiReportInApp(
        fields: _fields,
        post: (fields) => postAiReport(fields, adapter: adapter),
        offerFallback: (failure) async {
          offered = failure;
          return false;
        },
        fallback: () async {
          fallbacks++;
          return AiReportRoute.mail;
        },
      );

      expect(route, isNull);
      expect(offered?.status, isNull);
      expect(offered, isNotNull);
      expect(fallbacks, 0);
    });
  });

  test('returns mail after a successful external launch', () async {
    Uri? launched;
    var shares = 0;

    final route = await sendAiReport(
      subject: 'Report',
      body: 'Body',
      launch: (uri) async {
        launched = uri;
        return true;
      },
      share: (_, _, _) async => shares++,
    );

    expect(route, AiReportRoute.mail);
    expect(launched?.scheme, 'mailto');
    expect(shares, 0);
  });

  test('false launch shares the exact body and origin', () async {
    String? shared;
    String? sharedSubject;
    Rect? sharedOrigin;
    const origin = Rect.fromLTWH(1, 2, 3, 4);

    final route = await sendAiReport(
      subject: 'Report',
      body: 'Exact report text',
      sharePositionOrigin: origin,
      launch: (_) async => false,
      share: (text, subject, passedOrigin) async {
        shared = text;
        sharedSubject = subject;
        sharedOrigin = passedOrigin;
      },
    );

    expect(route, AiReportRoute.share);
    expect(shared, 'Exact report text');
    expect(sharedSubject, 'Report');
    expect(sharedOrigin, origin);
  });

  test('a launch exception falls back to sharing', () async {
    var shared = false;

    final route = await sendAiReport(
      subject: 'Report',
      body: 'Body',
      launch: (_) => Future<bool>.error(StateError('no mail app')),
      share: (_, _, _) async => shared = true,
    );

    expect(route, AiReportRoute.share);
    expect(shared, isTrue);
  });

  test('oversized mailto shares directly without launching', () async {
    var launches = 0;
    String? shared;

    final route = await sendAiReport(
      subject: 'Report',
      body: 'x' * 1801,
      launch: (_) async {
        launches++;
        return true;
      },
      share: (text, _, _) async => shared = text,
    );

    expect(route, AiReportRoute.share);
    expect(launches, 0);
    expect(shared, 'x' * 1801);
  });
}
