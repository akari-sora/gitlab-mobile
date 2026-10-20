import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';

final class _Secrets implements KnownSecretsSource {
  Iterable<String> values = const [];

  @override
  Iterable<String> get current => values;
}

final class _ThrowingSecrets implements KnownSecretsSource {
  @override
  Iterable<String> get current => throw StateError('synthetic source failure');
}

void main() {
  test('every configured expression compiles without inline flags', () {
    for (final pattern in [
      ...Redactor.defaultRedactionPatterns,
      ...Redactor.assignmentPatterns,
      Redactor.urlCredentialsPattern,
    ]) {
      expect(pattern.pattern, isNot(contains('(?i)')));
      expect(
        () => RegExp(pattern.pattern, caseSensitive: pattern.caseSensitive),
        returnsNormally,
        reason: pattern.name,
      );
    }
  });

  test('redacts every credential family and case-insensitive assignments', () {
    final source = _Secrets();
    final redactor = Redactor(secrets: source);
    final values = <String>[
      'glpat-${'a' * 20}',
      'GR1348941${'B' * 20}',
      'ghp_${'c' * 36}',
      'github_pat_${'d' * 22}',
      'sk-proj-${'e' * 20}',
      'oc_sk_${'f' * 16}',
      'AIza${'G' * 35}',
      'AKIA${'H' * 16}',
      'AWS_SECRET_ACCESS_KEY=${'i' * 40}',
      'xoxb-${'j' * 10}',
      'https://hooks.slack.com/services/a/b/c',
      'sk_live_${'k' * 16}',
      'npm_${'l' * 36}',
      'pypi-AgEIcHlwaS5vcmc${'m' * 50}',
      'dckr_pat_${'n' * 27}',
      'eyJ${'o' * 10}.eyJ${'p' * 10}.${'q' * 10}',
      'Authorization: Bearer credential-value',
      'CLIENT_SECRET=${'r' * 12}',
    ];

    final result = redactor.redact(values.join('\n'));

    for (final value in values) {
      expect(
        result.text,
        isNot(contains(value)),
        reason: value.substring(0, 4),
      );
    }
    expect(result.redactions, values.length);
  });

  test('covers every variable token prefix and preserves case sensitivity', () {
    final gitLab = [
      'glpat',
      'gldt',
      'glrt',
      'glrtr',
      'glcbt',
      'glptt',
      'glft',
      'glimt',
      'glagent',
      'glsoat',
      'gloas',
      'glffct',
      'glwt',
    ].map((prefix) => '$prefix-${'a' * 20}');
    final gitHub = 'pousr'.split('').map((suffix) => 'gh${suffix}_${'b' * 36}');
    final sk = [
      'sk-${'c' * 20}',
      'sk-proj-${'c' * 20}',
      'sk-svcacct-${'c' * 20}',
      'sk-admin-${'c' * 20}',
      'sk-ant-api03-${'c' * 20}',
      'sk-or-v1-${'c' * 20}',
    ];
    final aws = [
      'AKIA',
      'ASIA',
      'ABIA',
      'ACCA',
    ].map((prefix) => '$prefix${'D' * 16}');
    final slack = 'abprs'.split('').map((suffix) => 'xox$suffix-${'e' * 10}');
    final stripe = [
      'sk_live_${'f' * 16}',
      'sk_test_${'f' * 16}',
      'rk_live_${'f' * 16}',
      'rk_test_${'f' * 16}',
    ];
    final tokens = [...gitLab, ...gitHub, ...sk, ...aws, ...slack, ...stripe];
    final redactor = Redactor(secrets: _Secrets());

    final result = redactor.redact(tokens.join('\n'));

    for (final token in tokens) {
      expect(
        result.text,
        isNot(contains(token)),
        reason: token.substring(0, 4),
      );
    }
    expect(redactor.redact('akia${'D' * 16} GHP_${'b' * 36}').redactions, 0);
  });

  test(
    'known secrets are longest-first, exact, and cumulative across rotation',
    () {
      final source = _Secrets()..values = ['abcd', 'abcdefgh'];
      final redactor = Redactor(secrets: source, patterns: const []);

      expect(redactor.redact('abcdefgh abcd').text, '[REDACTED] [REDACTED]');
      source.values = ['new-token'];

      expect(
        redactor.redact('abcdefgh old abcd new-token').text,
        '[REDACTED] old [REDACTED] [REDACTED]',
      );
    },
  );

  test(
    'redacts a secret assembled across source chunks before boundary call',
    () {
      final source = _Secrets()..values = ['rotated-secret'];
      final text = ['before rotated-', 'secret after'].join();

      expect(
        Redactor(secrets: source, patterns: const []).redact(text).text,
        'before [REDACTED] after',
      );
    },
  );

  test('masking before a caller truncates cannot retain a secret prefix', () {
    final source = _Secrets()..values = ['rotated-secret'];
    final redacted = Redactor(
      secrets: source,
      patterns: const [],
    ).redact('prefix rotated-secret suffix').text;

    expect(redacted.substring(0, 18), isNot(contains('rotated')));
  });

  test('bounds unterminated PEM redaction at an empty line or 100 lines', () {
    final redactor = Redactor(secrets: _Secrets(), patterns: const []);
    final blankBounded = redactor.redact(
      'x\n-----BEGIN PRIVATE KEY-----\nsecret\n\nvisible',
    );
    final hundredLines = List.generate(101, (index) => 'line-$index');
    final lineBounded = redactor.redact(
      '-----BEGIN RSA PRIVATE KEY-----\n${hundredLines.join('\n')}',
    );

    expect(blankBounded.text, 'x\n[REDACTED]\nvisible');
    expect(lineBounded.text, startsWith('[REDACTED]line-100'));
    expect(lineBounded.text, isNot(contains('line-99')));
  });

  test('redacts matching PEM end marker and preserves following content', () {
    final result = Redactor(secrets: _Secrets(), patterns: const []).redact(
      '-----BEGIN EC PRIVATE KEY-----\nabc\n'
      '-----END EC PRIVATE KEY-----\nafter',
    );

    expect(result.text, '[REDACTED]after');
  });

  test('handles CRLF PEM and content following BEGIN on the same line', () {
    final redactor = Redactor(secrets: _Secrets(), patterns: const []);

    expect(
      redactor
          .redact(
            '-----BEGIN PRIVATE KEY-----\r\nabc\r\n'
            '-----END PRIVATE KEY-----\r\nafter',
          )
          .text,
      '[REDACTED]after',
    );
    expect(
      redactor.redact('-----BEGIN PRIVATE KEY-----abc').text,
      '[REDACTED]',
    );
  });

  test(
    'preserves URL scheme and host separator while removing credentials',
    () {
      final result = Redactor(
        secrets: _Secrets(),
      ).redact('POSTGRES://user:password@database.internal:5432/db');

      expect(
        result.text,
        'POSTGRES://[REDACTED:url_credentials]@database.internal:5432/db',
      );
    },
  );

  test('invalid injected pattern fails closed as policyBlocked', () {
    final redactor = Redactor(
      secrets: _Secrets(),
      patterns: const [RedactionPattern('broken', '[')],
    );

    for (var attempt = 0; attempt < 2; attempt += 1) {
      expect(
        () => redactor.redact('content'),
        throwsA(
          isA<AiFailure>().having(
            (failure) => failure.kind,
            'kind',
            AiFailureKind.policyBlocked,
          ),
        ),
      );
    }
  });

  test('live secret-source runtime failure fails closed', () {
    final redactor = Redactor(secrets: _ThrowingSecrets());

    expect(
      () => redactor.redact('content'),
      throwsA(
        isA<AiFailure>().having(
          (failure) => failure.kind,
          'kind',
          AiFailureKind.policyBlocked,
        ),
      ),
    );
  });
}
