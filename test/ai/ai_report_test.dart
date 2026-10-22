import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_report.dart';
import 'package:gitlab_mobile/core/brand.dart';

AiReport _report({String description = '', String? response}) => AiReport(
  category: AiReportCategory.inaccurate,
  description: description,
  appVersion: '0.6.0+612 (abc1234)',
  presetId: 'openai-default',
  format: 'responses',
  model: 'gpt-example',
  time: DateTime.parse('2026-10-22T08:09:10.123+08:00'),
  messageIndex: 3,
  response: response,
);

void main() {
  test('AI report email is a single ASCII address without spaces', () {
    expect(aiReportEmail.split('@'), hasLength(2));
    expect(aiReportEmail, isNot(contains(' ')));
    expect(aiReportEmail.codeUnits, everyElement(lessThan(128)));
  });

  test('report body starts with destination and omits response by default', () {
    final body = aiReportBody(_report(), sendToLine: 'Send to $aiReportEmail');

    expect(body.split('\n').first, 'Send to $aiReportEmail');
    expect(body, contains('category: inaccurate'));
    expect(body, contains('description: '));
    expect(body, contains('message: 3'));
    expect(body, isNot(contains('---')));
  });

  test('attached response keeps line breaks below a separator', () {
    final body = aiReportBody(
      _report(response: 'first line\nsecond line'),
      sendToLine: 'Send to $aiReportEmail',
    );

    expect(body, endsWith('---\nfirst line\nsecond line'));
  });

  test(
    'single-line values replace newlines and strip control and bidi marks',
    () {
      final body = aiReportBody(
        _report(
          description:
              'one\r\ntwo\u2028three\u2029four\u0000\u0008\u061c\u202e\u2067five',
        ),
        sendToLine: 'Send to $aiReportEmail',
      );

      expect(body.split('\n').first, 'Send to $aiReportEmail');
      expect(body, contains('description: one two three fourfive'));
      expect(body, isNot(contains('\u0000')));
      expect(body, isNot(contains('\u2028')));
      expect(body, isNot(contains('\u2029')));
      expect(body, isNot(contains('\u202e')));
    },
  );

  test('time is rendered in UTC ISO 8601 form', () {
    final body = aiReportBody(_report(), sendToLine: 'destination');

    expect(body, contains('time: 2026-10-22T00:09:10.123Z'));
  });

  test('mailto encodes subject and body including non-ASCII text', () {
    final uri = aiReportMailto('問題 report', 'line one\n內容 & more')!;

    expect(uri.scheme, 'mailto');
    expect(uri.path, aiReportEmail);
    expect(uri.queryParameters['subject'], '問題 report');
    expect(uri.queryParameters['body'], 'line one\n內容 & more');
    expect(uri.toString(), contains('%E5%95%8F%E9%A1%8C%20report'));
    expect(uri.toString(), contains('%26'));
  });

  test('mailto accepts 1,800 encoded characters and rejects 1,801', () {
    final base = aiReportMailto('', '')!.toString().length;
    final atLimit = 'x' * (1800 - base);

    expect(aiReportMailto('', atLimit)!.toString(), hasLength(1800));
    expect(aiReportMailto('', '${atLimit}x'), isNull);
  });
}
