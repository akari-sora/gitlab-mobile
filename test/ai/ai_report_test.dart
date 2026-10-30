import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_report.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/brand.dart';

final class _Secrets implements KnownSecretsSource {
  const _Secrets(this.current);

  @override
  final Iterable<String> current;
}

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
  test('AI report email is the owner\'s address', () {
    // The address the owner chose for AI reports (plan v5, third round).
    expect(aiReportEmail, 'aa22396584@gmail.com');
    expect(aiReportEmail.split('@'), hasLength(2));
    expect(aiReportEmail, isNot(contains(' ')));
    expect(aiReportEmail.codeUnits, everyElement(lessThan(128)));
  });

  test('the address also has a line without direction marks', () {
    // Arabic wraps the translated address in isolates; this line copies
    // cleanly into a recipient field from the share route.
    final body = aiReportBody(
      _report(),
      sendToLine: 'أرسل إلى \u2068$aiReportEmail\u2069',
    );
    expect(body.split('\n')[1], 'to: $aiReportEmail');
  });

  test('an attached answer keeps its line breaks and tabs', () {
    final body = aiReportBody(
      _report(response: 'func main() {\n\treturn\n}'),
      sendToLine: 'Send to $aiReportEmail',
    );
    expect(body, contains('func main() {\n\treturn\n}'));
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

  group('the developer\'s form', () {
    test('a secret split by invisible characters across the cut is '
        'redacted, not cut in half', () {
      const key =
          'f00dbabe0123456789abcdef0123456789abcdef0123456789abcdef01234567';
      final redactor = Redactor(secrets: const _Secrets([key]));
      // The chat's redaction strips only some format characters, so it does
      // not see a key split by the ones the report's clean-up removes.
      String draftSafe(String text) => redactor
          .redactSource(text.replaceAll(RegExp('[\\u2060-\\u2069]'), ''))
          .text;
      for (final joiner in ['\u206a', '\u00ad', '\u{e0020}', '\ufe0f']) {
        final split = key.split('').join(joiner);
        final answer = '${'x' * 3970}$split tail';
        // What the chat page does: clean up, redact whole, then build.
        final response = draftSafe(aiReportResponseText(answer));
        final fields = aiReportFormFields(_report(response: response));
        final checked = fields.checked(draftSafe)!;
        expect(checked.excerpt.length, lessThanOrEqualTo(aiReportExcerptLimit));
        expect(checked.excerpt, isNot(contains(key.substring(0, 8))));
        expect(checked.excerpt, isNot(contains(joiner)));
      }
    });

    const details =
        'description: wrong file\n'
        'preset: openai-default\n'
        'format: responses\n'
        'model: gpt-example\n'
        'time: 2026-10-22T00:09:10.123Z\n'
        'message: 3';

    test('is posted over HTTPS to the Google Form, four answers', () {
      expect(aiReportFormEndpoint.scheme, 'https');
      expect(aiReportFormEndpoint.host, 'docs.google.com');
      expect(aiReportFormEndpoint.path, endsWith('/formResponse'));
      expect(aiReportFormEndpoint.hasQuery, isFalse);
      expect({
        aiReportReasonEntry,
        aiReportDetailsEntry,
        aiReportExcerptEntry,
        aiReportAppEntry,
      }, hasLength(4));
    });

    test('the answers are exactly the report\'s values', () {
      final fields = aiReportFormFields(
        _report(description: 'wrong file', response: 'the answer'),
      );
      expect(fields.form, {
        aiReportReasonEntry: 'inaccurate',
        aiReportDetailsEntry: details,
        aiReportExcerptEntry: 'the answer',
        aiReportAppEntry: '0.6.0+612 (abc1234)',
      });
    });

    test('without an attached response the excerpt is empty', () {
      final fields = aiReportFormFields(_report(description: 'wrong file'));
      expect(fields.excerpt, isEmpty);
      expect(aiReportFormText(fields), isNot(contains('---')));
    });

    test('the preview shows every answer under its label', () {
      final fields = aiReportFormFields(
        _report(description: 'wrong file', response: 'line one\n\tline two'),
      );
      final text = aiReportFormText(fields);
      expect(
        text,
        'category: inaccurate\n'
        'app: 0.6.0+612 (abc1234)\n'
        '$details\n'
        '---\n'
        'line one\n\tline two',
      );
      expect(fields.shownIn(text), isTrue);
      expect(fields.shownIn('category: inaccurate'), isFalse);
    });

    test('single-line answers lose line breaks, controls and bidi marks', () {
      final fields = aiReportFormFields(
        _report(description: 'one\r\ntwo\u2028three\u0000\u202efour'),
      );
      expect(
        fields.details.split('\n').first,
        'description: one two threefour',
      );
      expect(fields.details.split('\n'), hasLength(6));
    });

    test('the excerpt is cut at 4,000 code units, never inside a pair', () {
      final long = 'a' * 5000;
      final cut = aiReportFormFields(_report(response: long)).excerpt;
      expect(cut, 'a' * aiReportExcerptLimit);
      expect(aiReportExcerptLimit, 4000);
      final exact = 'b' * 4000;
      expect(aiReportFormFields(_report(response: exact)).excerpt, exact);
      // An emoji across the limit is dropped whole, not halved.
      final straddle = '${'c' * 3999}\u{1F600}tail';
      expect(
        aiReportFormFields(_report(response: straddle)).excerpt,
        'c' * 3999,
      );
      // The mail fallback carries the same excerpt.
      expect(
        aiReportBody(_report(response: long), sendToLine: 'destination'),
        endsWith('---\n${'a' * 4000}'),
      );
    });

    test('secret-looking values never reach the form', () {
      const gitlabToken = 'glpat-SyntheticReportToken0123456789';
      const providerKey = 'sk-synthetic-provider-key-0123456789abcdef';
      final redactor = Redactor(
        secrets: const _Secrets([gitlabToken, providerKey]),
      );
      String check(String value) => redactor.redactSource(value).text;
      // Secrets where none belong: in the metadata, the description and the
      // attached answer.
      final report = AiReport(
        category: AiReportCategory.privacy,
        description: 'it printed $gitlabToken',
        appVersion: '0.6.0+612 (abc1234)',
        presetId: 'custom $providerKey',
        format: 'chatCompletions',
        model: 'model-$gitlabToken',
        time: DateTime.utc(2026, 10, 30, 1, 2, 3),
        messageIndex: 2,
        response: 'Use $providerKey\nwith $gitlabToken',
      );
      final built = aiReportFormFields(report);
      final fields = built.checked(check)!;
      expect(fields.form.keys, {
        aiReportReasonEntry,
        aiReportDetailsEntry,
        aiReportExcerptEntry,
        aiReportAppEntry,
      });
      final values = fields.form.values.join('\n');
      expect(values, isNot(contains(gitlabToken)));
      expect(values, isNot(contains(providerKey)));
      expect(values, isNot(contains('glpat-')));
      expect(values, isNot(contains(aiReportEmail)));
      expect(fields.excerpt, contains('Use '));
      // Each checked answer reads unchanged in the checked preview.
      expect(fields.shownIn(check(aiReportFormText(built))), isTrue);
    });

    test('an answer that cannot be checked stops the report', () {
      final fields = aiReportFormFields(_report(response: 'the answer'));
      // The redaction returns an empty string for what it cannot check.
      expect(
        fields.checked((value) => value == 'the answer' ? '' : value),
        isNull,
      );
      expect(fields.checked((value) => value)?.form, fields.form);
    });
  });
}
