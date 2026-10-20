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

  test('unterminated PEM fails closed through its bounded window', () {
    final redactor = Redactor(secrets: _Secrets(), patterns: const []);
    final blankBounded = redactor.redact(
      'x\n-----BEGIN PRIVATE KEY-----\nsecret\n\nvisible',
    );
    const begin = '-----BEGIN RSA PRIVATE KEY-----';
    const windowChars = 32 * 1024; // At most 64 KiB of UTF-16 text.
    final window = begin + 'A' * (windowChars - begin.length);
    final windowBounded = redactor.redact('$window!after-window');

    expect(blankBounded.text, 'x\n[REDACTED]');
    expect(windowBounded.text, '[REDACTED]!after-window');
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

  test('prefixed credential headers hide the complete review corpus', () {
    for (final (input, expected) in [
      ('Proxy-Authorization: Basic dXNlcjpwYXNzd29yZDEyMw==', '[REDACTED]'),
      ('> Proxy-Authorization: Basic dXNlcjpwYXNzd29yZDEyMw==', '> [REDACTED]'),
      ('headers.Authorization: Bearer abcdefghijklmnopqrstuvwx', '[REDACTED]'),
      (
        'request.headers.authorization=Token SYNTHETIC-CREDENTIAL',
        '[REDACTED]',
      ),
      ('HTTP_AUTHORIZATION=Bearer SYNTHETIC-CREDENTIAL', '[REDACTED]'),
      for (final header in [
        'private-token',
        'job-token',
        'x-api-key',
        'api-key',
        'x-goog-api-key',
      ])
        ('headers.$header: Bot SYNTHETIC-CREDENTIAL', '[REDACTED]'),
    ]) {
      final result = Redactor(secrets: _Secrets()).redact(input);
      expect(result.text, expected, reason: input.split(RegExp('[:=]')).first);
      expect(result.redactions, 1);
    }
    const ordinary = 'NotAuthorization: visible\nmax_tokens: 1024';
    expect(Redactor(secrets: _Secrets()).redact(ordinary).text, ordinary);
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

  for (final label in ['PGP PRIVATE KEY BLOCK', 'RSA PRIVATE KEY']) {
    test('long synthetic $label fixture redacts past 100 body lines', () {
      // Structurally armored, deliberately unusable data; no real private key.
      // 112 x 64 columns also exceeds an openssl genrsa 8192-sized PEM.
      final body = List.filled(112, 'A' * 64).join('\n');
      final headers = label.startsWith('PGP')
          ? 'Version: Synthetic fixture\n\n'
          : '';
      final checksum = label.startsWith('PGP') ? '\n=AAAA' : '';
      final input =
          'before\n-----BEGIN $label-----\n$headers$body$checksum\n'
          '-----END $label-----\r\nafter';
      final result = Redactor(secrets: _Secrets()).redact(input);
      expect(result.text, 'before\n[REDACTED]after');
      expect(result.redactions, 1);
    });
  }

  test('PEM matching END at the window boundary is also redacted', () {
    const begin = '-----BEGIN PRIVATE KEY-----';
    const end = '-----END PRIVATE KEY-----';
    const cap = 32 * 1024;
    final redactor = Redactor(secrets: _Secrets());
    final fitting = begin + 'A' * (cap - begin.length - end.length) + end;
    expect(redactor.redact('$fitting\nafter').text, '[REDACTED]after');
    final outside = begin + 'A' * (cap - begin.length);
    expect(redactor.redact('$outside$end\nafter').text, '[REDACTED]after');
  });

  for (final (prefixName, prefix) in [
    ('set -x grep', "+ grep -q -- '-----BEGIN OPENSSH PRIVATE KEY-----' key\n"),
    (
      'head -3 PKCS8',
      '-----BEGIN PRIVATE KEY-----\n${'A' * 64}\n${'B' * 64}\n',
    ),
    ('documentation', 'Example: -----BEGIN RSA PRIVATE KEY----- in docs.\n'),
  ]) {
    for (final (label, lines, columns) in [
      ('OPENSSH PRIVATE KEY', 47, 70),
      ('PRIVATE KEY', 50, 64),
      ('RSA PRIVATE KEY', 49, 64),
    ]) {
      test('$prefixName before boundary-crossing $label leaks zero lines', () {
        // RSA-4096 armor shapes, deliberately unusable synthetic contents.
        final body = List.generate(
          lines,
          (i) => '${i.toString().padLeft(4, '0')}${'Ab9+/' * columns}'
              .substring(0, columns),
        );
        final key =
            '-----BEGIN $label-----\n${body.join('\n')}\n'
            '-----END $label-----\n';
        final firstBegin = prefix.indexOf('-----BEGIN');
        final boundary = firstBegin + 32 * 1024;
        // Exercise a body-line interior and both split marker shapes.
        for (final split in [key.length ~/ 2, 12, key.length - 12]) {
          final padding = '.' * (boundary - split - prefix.length - 1);
          final input = '$prefix$padding\n${key}after';
          final result = Redactor(secrets: _Secrets()).redact(input);
          expect(
            result.text,
            '${prefix.substring(0, firstBegin)}[REDACTED]after',
          );
          expect(body.where(result.text.contains), isEmpty);
          expect(result.redactions, 1);
        }
      });
    }
  }

  for (final lineEnding in ['\n', '\r\n']) {
    test('PGP armor over 64 KiB is fully redacted with $lineEnding', () {
      final body = List.generate(1200, (i) => '${'Ab9+/' * 12}AAAA');
      final input = [
        'before',
        '-----BEGIN PGP PRIVATE KEY BLOCK-----',
        'Version: Synthetic fixture',
        '',
        ...body,
        'Comment: Synthetic continuation header',
        '=AB9+',
        '-----END PGP PRIVATE KEY BLOCK-----',
        'after',
      ].join(lineEnding);
      expect(input.length, greaterThan(64 * 1024));
      final result = Redactor(secrets: _Secrets()).redact(input);
      expect(result.text, 'before$lineEnding[REDACTED]after');
      expect(result.redactions, 1);
    });
  }

  test(
    'PEM boundary inside an armor header retains no header or body tail',
    () {
      const begin = '-----BEGIN PGP PRIVATE KEY BLOCK-----\n';
      const header = 'Comment: Synthetic armor header with spaces\n';
      for (var split = 1; split < header.length; split++) {
        final padding = 'A' * (32 * 1024 - begin.length - split - 1);
        final input =
            '$begin$padding\n$header${'B' * 64}\n=AAAA\n'
            '-----END PGP PRIVATE KEY BLOCK-----\nafter';
        expect(
          Redactor(secrets: _Secrets()).redact(input).text,
          '[REDACTED]after',
        );
      }
    },
  );

  test('PEM extension cap fails closed through the remaining input', () {
    final input =
        '-----BEGIN PRIVATE KEY-----\n${'A' * (2 * 1024 * 1024)}\n'
        '-----END PRIVATE KEY-----\nafter';
    expect(Redactor(secrets: _Secrets()).redact(input).text, '[REDACTED]');
  });

  test('PEM extension cap inside a nested BEGIN also fails closed', () {
    const begin = '-----BEGIN PRIVATE KEY-----\n';
    final padding = 'A' * (32 * 1024 + 1024 * 1024 - begin.length - 13);
    final input =
        '$begin$padding\n-----BEGIN RSA PRIVATE KEY-----\n${'B' * 64}\n'
        '-----END RSA PRIVATE KEY-----\nafter';
    expect(Redactor(secrets: _Secrets()).redact(input).text, '[REDACTED]');
  });

  test(
    'PEM window refills when a matching END crosses the cached boundary',
    () {
      const first = '-----BEGIN PRIVATE KEY-----x-----END PRIVATE KEY-----';
      const second = '-----BEGIN RSA PRIVATE KEY-----';
      final padding = ' ' * (32 * 1024 - first.length - second.length - 5);
      final input =
          '$first$padding$second\n${'A' * 100}\n'
          '-----END RSA PRIVATE KEY-----\nafter';
      final result = Redactor(secrets: _Secrets()).redact(input);
      expect(result.text, '[REDACTED]$padding[REDACTED]after');
      expect(result.redactions, 2);
    },
  );

  test('PEM ignores other END labels before the matching END', () {
    final result = Redactor(secrets: _Secrets()).redact(
      '-----BEGIN PGP PRIVATE KEY BLOCK-----\n\n'
      '-----END RSA PRIVATE KEY-----\nSYNTHETIC-KEY-BODY\n'
      '-----END PGP PRIVATE KEY BLOCK-----\nafter',
    );
    expect(result.text, '[REDACTED]after');
    expect(result.redactions, 1);
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

  test('plain SSH git userinfo survives while passwords and tokens do not', () {
    final redactor = Redactor(secrets: _Secrets());
    for (final scheme in ['ssh', 'SSH']) {
      final remote = '$scheme://git@host.example/group/repo.git';
      expect(redactor.redact(remote).text, remote);
      expect(redactor.redact(remote).redactions, 0);
      expect(
        redactor.redact('$scheme://git:pw@host.example/repo.git').text,
        '$scheme://[REDACTED]@host.example/repo.git',
      );
      expect(
        redactor.redact('$scheme://opaque-token@host.example/repo.git').text,
        '$scheme://[REDACTED]@host.example/repo.git',
      );
    }
    final known = Redactor(secrets: _Secrets()..values = ['git']);
    expect(
      known.redact('ssh://git@host.example/repo').text,
      'ssh://[REDACTED]@host.example/repo',
    );
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

  test('hostile PEM blocks remain under one second at 2 MiB', () {
    final redactor = Redactor(secrets: _Secrets());
    redactor.redact('-----BEGIN PRIVATE KEY-----\n\n' * 10);
    final input = '-----BEGIN PRIVATE KEY-----\n\n' * 72316;
    final watch = Stopwatch()..start();
    final result = redactor.redact(input);
    watch.stop();
    // Missing END now consumes the bounded window, including nested BEGINs.
    expect(result.text, matches(RegExp(r'^(?:\[REDACTED\]|\n)+$')));
    expect(result.redactions, greaterThan(0));
    // ignore: avoid_print
    print(
      'unterminated PEM ${input.length} bytes: ${watch.elapsedMilliseconds} ms',
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test('2 MiB hostile armor extensions stay under one second', () {
    for (final body in ['A' * 64 + '\n', 'Comment: Synthetic armor\n']) {
      const begin = '-----BEGIN PGP PRIVATE KEY BLOCK-----\n';
      const size = 2 * 1024 * 1024;
      final repeated = body * ((size - begin.length) ~/ body.length + 1);
      final input = begin + repeated.substring(0, size - begin.length);
      final redactor = Redactor(secrets: _Secrets());
      redactor.redact('$begin$body');
      final watch = Stopwatch()..start();
      final result = redactor.redact(input);
      watch.stop();
      expect(result.text, '[REDACTED]');
      // ignore: avoid_print
      print('armor PEM ${input.length} bytes: ${watch.elapsedMilliseconds} ms');
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    }
  });

  for (final suffix in ['', ' ']) {
    test(
      '2 MiB inline PEM blocks with ${suffix.length} trailing spaces stay under 1 s',
      () {
        const block = '-----BEGIN PRIVATE KEY----------END PRIVATE KEY-----';
        final repeated = block + suffix;
        final count = 2 * 1024 * 1024 ~/ repeated.length;
        final padding = ' ' * (2 * 1024 * 1024 - count * repeated.length);
        final input = repeated * count + padding;
        final redactor = Redactor(secrets: _Secrets());
        redactor.redact(repeated * 100);
        final watch = Stopwatch()..start();
        final result = redactor.redact(input);
        watch.stop();
        expect(result.redactions, count);
        expect(result.text, '[REDACTED]$suffix' * count + padding);
        // Retain host timing in the expanded acceptance output.
        // ignore: avoid_print
        print(
          'inline PEM ${input.length} bytes, suffix=${suffix.length}: ${watch.elapsedMilliseconds} ms',
        );
        expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

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
