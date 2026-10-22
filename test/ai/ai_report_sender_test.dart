import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/ai/ai_report_sender.dart';

void main() {
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
