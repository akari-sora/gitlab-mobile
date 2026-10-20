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

      expect(result.text, 'POSTGRES://[REDACTED]@database.internal:5432/db');
    },
  );

  for (final (label, secret, input, hidden)
      in <(String, String, String, String)>[
        ('PAT prefix', 'glpat', 'glpat-${'A' * 20}', 'A' * 20),
        (
          'header name',
          'Authorization',
          'Authorization: Bearer SYNTHETIC-HEADER-SECRET',
          'SYNTHETIC-HEADER-SECRET',
        ),
        (
          'PEM BEGIN',
          '-----BEGIN PRIVATE KEY-----',
          '-----BEGIN PRIVATE KEY-----\nSYNTHETIC-PRIVATE-MATERIAL\n'
              '-----END PRIVATE KEY-----',
          'SYNTHETIC-PRIVATE-MATERIAL',
        ),
      ]) {
    test('known secret $label cannot disable structural detection', () {
      final redactor = Redactor(secrets: _Secrets()..values = [secret]);
      final result = redactor.redact(input);
      expect(result.text, isNot(contains(hidden)), reason: label);
      expect(result.redactions, 1);
    });
  }

  test('marker collisions fail closed instead of retaining a known secret', () {
    for (final secret in ['REDACTED', 'EDAC', '[REDACTED]']) {
      final redactor = Redactor(secrets: _Secrets()..values = [secret]);
      expect(
        () => redactor.redact(secret),
        throwsA(
          isA<AiFailure>().having(
            (f) => f.kind,
            'kind',
            AiFailureKind.policyBlocked,
          ),
        ),
      );
    }
  });

  test('overlapping literal matches leave no suffix of another secret', () {
    final result = Redactor(
      secrets: _Secrets()..values = ['abcd', 'cdef'],
      patterns: const [],
    ).redact('abcdef');
    expect(result.text, '[REDACTED]');
    expect(result.redactions, 1);
  });

  test('headers hide arbitrary schemes and JSON credential values', () {
    for (final input in [
      'Authorization: Token SYNTHETIC-CREDENTIAL',
      'Authorization: Bot SYNTHETIC-CREDENTIAL',
      '"Authorization": "Bearer SYNTHETIC-CREDENTIAL"',
      "'x-api-key': 'SYNTHETIC-CREDENTIAL'",
    ]) {
      final result = Redactor(secrets: _Secrets()).redact(input);
      expect(result.text, isNot(contains('SYNTHETIC-CREDENTIAL')));
      expect(result.redactions, 1);
    }
  });

  test('environment and JSON secret assignments hide complete values', () {
    for (final input in [
      'DB_PASSWORD=SYNTHETIC-CREDENTIAL',
      'POSTGRES_PASSWORD: SYNTHETIC-CREDENTIAL',
      'export GITLAB_TOKEN=SYNTHETIC-CREDENTIAL',
      'SECRET_KEY_BASE=SYNTHETIC-CREDENTIAL',
      '{"password": "SYNTHETIC-CREDENTIAL"}',
      '{"client_secret":"SYNTHETIC-CREDENTIAL"}',
    ]) {
      final result = Redactor(secrets: _Secrets()).redact(input);
      expect(result.text, isNot(contains('SYNTHETIC-CREDENTIAL')));
      expect(result.redactions, 1);
    }
    expect(
      Redactor(
        secrets: _Secrets(),
      ).redact('{"max_tokens": 1024, "tokens": 123456789}').redactions,
      0,
    );
  });

  test('encrypted and PGP private keys redact through matching END', () {
    for (final label in ['RSA PRIVATE KEY', 'PGP PRIVATE KEY BLOCK']) {
      final result = Redactor(secrets: _Secrets()).redact(
        '-----BEGIN $label-----\nProc-Type: 4,ENCRYPTED\n'
        'DEK-Info: AES-128-CBC,ABCDEF\n\nSYNTHETIC-KEY-BODY\n'
        '-----END $label-----\nafter',
      );
      expect(result.text, '[REDACTED]after');
      expect(result.redactions, 1);
    }
  });

  test('single-line PEM preserves the following ordinary lines', () {
    final result = Redactor(secrets: _Secrets()).redact(
      '-----BEGIN PRIVATE KEY----- inline-key -----END PRIVATE KEY-----\n'
      'normal line 1\nnormal line 2\n\nafter blank line',
    );
    expect(
      result.text,
      '[REDACTED]normal line 1\nnormal line 2\n\nafter blank line',
    );
  });

  test('URL authority stops before query and fragment delimiters', () {
    for (final delimiter in ['?', '#']) {
      final input = 'https://example.com:8443${delimiter}user=alice@corp.com';
      expect(Redactor(secrets: _Secrets()).redact(input).text, input);
    }
  });

  test('URL userinfo handles opaque tokens and the final at separator', () {
    for (final userinfo in ['opaquetoken0123456789', 'user:p@ss0123456']) {
      final result = Redactor(
        secrets: _Secrets(),
      ).redact('https://$userinfo@host.example/repo.git');
      expect(result.text, 'https://[REDACTED]@host.example/repo.git');
    }
  });

  test('redaction is idempotent with distinct-span counts', () {
    final redactor = Redactor(secrets: _Secrets());
    final first = redactor.redact(
      'https://user:pass@host.example/x\n'
      'Authorization: Bearer glpat-${'A' * 20}\n'
      'token = glpat-${'B' * 20}',
    );
    expect(first.redactions, 3);
    final second = redactor.redact(first.text);
    expect(second.text, first.text);
    expect(second.redactions, 0);
  });

  test('hostile JWT runs remain under three seconds at 2 MiB', () {
    final redactor = Redactor(secrets: _Secrets());
    redactor.redact('eyJ-' * 100);
    // Reject quadratic implementations at 32 KiB before attempting 2 MiB.
    final probe = Stopwatch()..start();
    redactor.redact('eyJ-' * 8192);
    probe.stop();
    expect(probe.elapsed, lessThan(const Duration(seconds: 1)));
    final input = 'eyJ-' * (2 * 1024 * 1024 ~/ 4);
    final watch = Stopwatch()..start();
    final result = redactor.redact(input);
    watch.stop();
    expect(result.text, input);
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
  });

  test('hostile PEM blocks remain under three seconds at 2 MiB', () {
    final redactor = Redactor(secrets: _Secrets());
    redactor.redact('-----BEGIN PRIVATE KEY-----\n\n' * 10);
    final input = '-----BEGIN PRIVATE KEY-----\n\n' * 72316;
    final watch = Stopwatch()..start();
    final result = redactor.redact(input);
    watch.stop();
    expect(result.redactions, 72316);
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
  });

  test('hostile assignment runs remain under three seconds at 2 MiB', () {
    final redactor = Redactor(secrets: _Secrets());
    redactor.redact('TOKEN_' * 10);
    final input = 'TOKEN_' * 349526;
    final watch = Stopwatch()..start();
    final result = redactor.redact(input);
    watch.stop();
    expect(result.text, input);
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
  });

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
