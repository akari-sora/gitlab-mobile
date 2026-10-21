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

// Structurally armored, unique synthetic lines; these cannot be used as keys.
List<String> _keyBody(int count, int columns) => List.generate(
  count,
  (i) => '${i.toString().padLeft(6, '0')}${'Ab9+/' * columns}'.substring(
    0,
    columns,
  ),
);

String _keyShape(String shape, List<String> lines, String newline) {
  switch (shape) {
    case 'yaml':
      return lines.map((line) => '  $line').join(newline);
    case 'tab':
      return lines.map((line) => '\t$line').join(newline);
    case 'quote':
      return lines.map((line) => '> $line').join(newline);
    case 'trailing spaces':
      return lines.map((line) => '$line ').join(newline);
    case 'BEGIN trailing space':
      return ['${lines.first} ', ...lines.skip(1)].join(newline);
    case 'diff minus':
      return lines.map((line) => '-$line').join(newline);
    case 'diff plus':
      return lines.map((line) => '+$line').join(newline);
    case 'timestamp':
      return lines.map((line) => '2026-10-20T00:00:00Z $line').join(newline);
    case 'JSON escaped newline':
      // A single physical line, including literal backslash-r/backslash-n.
      return '{"sshKey": "${lines.join(newline == '\n' ? r'\n' : r'\r\n')}"}';
    case 'body punctuation':
      final changed = [...lines];
      final middle = changed.length ~/ 2;
      changed[middle] =
          '${changed[middle].substring(0, 17)}!${changed[middle].substring(17)}';
      return changed.join(newline);
    default:
      throw ArgumentError(shape);
  }
}

// Each size gets the same warm-up before its samples.
int _redactionMicros(Redactor redactor, String input) {
  redactor.redactSource(input);
  final samples = <int>[];
  for (var i = 0; i < 3; i++) {
    final watch = Stopwatch()..start();
    redactor.redactSource(input);
    watch.stop();
    samples.add(watch.elapsedMicroseconds);
  }
  // Load only adds time, so the fastest sample is the least noisy one; a
  // quadratic shape still shows 16x at 4N.
  samples.sort();
  return samples.first;
}

void main() {
  test('an alias keeping under four secret characters is not matched', () {
    // A pasted key with one trailing space: the pattern takes all but the
    // space, and an alias of '[REDACTED] ' would glue ordinary text together.
    for (final key in ['sk-proj-${'B' * 30} ', 'sk-proj-${'B' * 30}.x']) {
      final redactor = Redactor(secrets: _Secrets()..values = [key]);
      const text = 'token=[REDACTED] and pw=[REDACTED].xml here';
      final result = redactor.redactSource(text);
      expect(result.text, text, reason: key);
      expect(result.redactions, 0, reason: key);
      expect(redactor.verificationAliases, isEmpty, reason: key);
    }
  });

  for (final shape in [
    'yaml',
    'tab',
    'quote',
    'trailing spaces',
    'BEGIN trailing space',
    'diff minus',
    'diff plus',
    'timestamp',
    'JSON escaped newline',
    'body punctuation',
  ]) {
    test('FIX4 zero-leak matrix $shape', () {
      final failures = <String>[];
      for (final (prefixName, prefix) in [
        ('none', 'before\n'),
        ('set-x', "+ grep -q -- '-----BEGIN OPENSSH PRIVATE KEY-----' key\n"),
        ('head-3', '-----BEGIN PRIVATE KEY-----\n${'A' * 64}\n${'B' * 64}\n'),
        ('docs', 'Example: -----BEGIN RSA PRIVATE KEY----- in docs.\n'),
      ]) {
        for (final (kind, label, count, columns) in [
          ('OpenSSH', 'OPENSSH PRIVATE KEY', 47, 70),
          ('PKCS8', 'PRIVATE KEY', 50, 64),
          ('RSA', 'RSA PRIVATE KEY', 49, 64),
          ('encrypted RSA', 'RSA PRIVATE KEY', 49, 64),
          ('EC', 'EC PRIVATE KEY', 4, 64),
          ('PGP', 'PGP PRIVATE KEY BLOCK', 1200, 64),
        ]) {
          final body = _keyBody(count, columns);
          var leaks = 0;
          var failedCases = 0;
          for (final newline in ['\n', '\r\n']) {
            final lines = [
              '-----BEGIN $label-----',
              if (kind == 'encrypted RSA') ...[
                'Proc-Type: 4,ENCRYPTED',
                'DEK-Info: AES-128-CBC,0123456789ABCDEF',
                '',
              ],
              if (kind == 'PGP') ...['Version: Synthetic fixture', ''],
              ...body,
              if (kind == 'PGP') '=AAAA',
              '-----END $label-----',
            ];
            final key = _keyShape(shape, lines, newline);
            if (kind == 'PGP') expect(key.length, greaterThan(64 * 1024));
            for (final split in [0, 12, key.length ~/ 2, key.length - 12]) {
              final firstBegin = prefix.indexOf('-----BEGIN');
              final boundary = firstBegin + (split ~/ 32768 + 1) * 32768;
              final padding = firstBegin < 0
                  ? ''
                  : '.' * (boundary - split - prefix.length - 1);
              final input = '$prefix$padding\n$key${newline}after';
              final result = Redactor(secrets: _Secrets()).redactSource(input);
              final leaked = body.where(result.text.contains).length;
              leaks += leaked;
              // A prefix holding a BEGIN without its END withholds the rest.
              final stray = prefix.contains('-----BEGIN');
              final ending = stray
                  ? '[REDACTED:private_key_unterminated]'
                  : 'after';
              if (leaked != 0 ||
                  !result.text.endsWith(ending) ||
                  result.withheldPrivateKeyContext != stray) {
                failedCases++;
              }
            }
          }
          final cell = '$shape / $prefixName / $kind';
          // Keep complete cell counts in the before/acceptance receipts.
          // ignore: avoid_print
          print(
            'FIX4 matrix $cell: 8 cases, $leaks leaked lines, $failedCases failures',
          );
          if (failedCases != 0) {
            failures.add('$cell: $failedCases cases, $leaks lines');
          }
        }
      }
      expect(failures, isEmpty);
    });
  }

  test('FIX4 marker edge cases pair by label and position', () {
    final redactor = Redactor(secrets: _Secrets());
    const begin = '-----BEGIN PRIVATE KEY-----';
    const end = '-----END PRIVATE KEY-----';
    const unterminated = '[REDACTED:private_key_unterminated]';
    // An END before any BEGIN may close a key whose start is not in the text
    // (a log read from an offset), so everything up to it is withheld.
    expect(
      redactor.redactSource('doc $end\nbefore $begin body $end\nafter').text,
      '[REDACTED:private_key_unopened]before [REDACTED]after',
    );
    expect(
      redactor.redactSource('KEYTAIL1\nKEYTAIL2\n$end\nlog continues').text,
      '[REDACTED:private_key_unopened]log continues',
    );
    expect(
      redactor
          .redactSource(
            'doc $begin example $end\nbetween\n$begin body $end\nafter',
          )
          .text,
      'doc [REDACTED]between\n[REDACTED]after',
    );
    expect(
      redactor.redactSource('before $begin body -----END PRIVATE KEY----').text,
      'before $unterminated',
    );
    for (final ending in ['\r', '\n', '\r\n']) {
      expect(
        redactor.redactSource('$begin body $end${ending}after').text,
        '[REDACTED]after',
      );
    }
    const certificate =
        '-----BEGIN CERTIFICATE-----\nPUBLIC\n-----END CERTIFICATE-----\n';
    expect(
      redactor.redactSource('$certificate$begin body $end\n$certificate').text,
      '$certificate[REDACTED]$certificate',
    );
    expect(
      redactor.redactSource('before $begin arbitrary ! text\nafter').text,
      'before $unterminated',
    );
    expect(
      redactor.redactSource('before $end after').text,
      '[REDACTED:private_key_unopened] after',
    );
    // Non-private ENDs must not close a private range.
    expect(
      redactor.redactSource('$begin$certificate after').text,
      unterminated,
    );
    for (final label in [
      'PRIVATE KEY',
      'RSA PRIVATE KEY',
      'EC PRIVATE KEY',
      'DSA PRIVATE KEY',
      'OPENSSH PRIVATE KEY',
      'ENCRYPTED PRIVATE KEY',
      'CUSTOM 123 PRIVATE KEY',
      'PGP PRIVATE KEY BLOCK',
    ]) {
      expect(
        redactor
            .redactSource(
              '-----BEGIN $label----- body -----END $label----- after',
            )
            .text,
        '[REDACTED] after',
      );
      // Only an END with the same label closes a BEGIN.
      if (label != 'PRIVATE KEY') {
        expect(
          redactor.redactSource('-----BEGIN $label----- body $end after').text,
          unterminated,
        );
      }
    }
    const other = '-----BEGIN PUBLIC KEY-----pub-----END PUBLIC KEY-----';
    expect(redactor.redactSource(other).text, other);
    // Two BEGINs need two ENDs.
    final result = redactor.redactSource(
      '$begin nested $begin body $end\nafter',
    );
    expect(result.text, unterminated);
    expect(result.redactions, 1);
    expect(
      redactor.redactSource('$begin nested $begin body $end\n$end\nafter').text,
      '[REDACTED]after',
    );
    expect(redactor.redactSource(result.text).redactions, 0);
    final missing = redactor.redactSource('$begin body');
    expect(redactor.redactSource(missing.text).text, unterminated);
    expect(redactor.redactSource(missing.text).redactions, 0);
  });

  test('FIX4 shared delimiters do not hide a BEGIN', () {
    final redactor = Redactor(secrets: _Secrets());
    const end = '-----END PRIVATE KEY-----';
    const begin = '-----BEGIN PRIVATE KEY-----';
    final prefix = end.substring(0, end.length - 5);
    // The prefix is itself an END with no BEGIN before it (see below).
    expect(
      redactor.redactSource('$prefix$begin body $end\nafter').text,
      '[REDACTED:private_key_unopened]after',
    );
    expect(
      redactor.redactSource('$prefix$begin body').text,
      '[REDACTED:private_key_unterminated]',
    );
    // A closed key whose END shares its last five hyphens with the next
    // BEGIN: the second key is redacted too, with or without its own END.
    expect(
      redactor.redactSource('$begin doc $prefix$begin BODY $end after').text,
      '[REDACTED] after',
    );
    expect(
      redactor.redactSource('$begin doc $prefix$begin BODY').text,
      '[REDACTED:private_key_unterminated]',
    );
    expect(
      redactor
          .redactSource('$begin a $prefix$begin b $prefix$begin c $end\nz')
          .text,
      '[REDACTED]z',
    );
    // This END starts inside the BEGIN marker and cannot close that range.
    final overlappingEnd = end.substring(5);
    expect(
      redactor.redactSource('$begin$overlappingEnd body').text,
      '[REDACTED:private_key_unterminated]',
    );
  });

  test(
    'FIX4 unterminated reason survives overlapping secret and assignment spans',
    () {
      final redactor = Redactor(
        secrets: _Secrets()..values = ['before -----BEGIN'],
      );
      final result = redactor.redactSource(
        'password="before -----BEGIN PRIVATE KEY----- body',
      );
      expect(result.text, '[REDACTED:private_key_unterminated]');
      expect(result.redactions, 1);
      final collision = Redactor(
        secrets: _Secrets()..values = ['private_key_unterminated'],
      );
      expect(
        () => collision.redactSource('-----BEGIN PRIVATE KEY----- body'),
        throwsA(
          isA<AiFailure>().having(
            (f) => f.kind,
            'kind',
            AiFailureKind.policyBlocked,
          ),
        ),
      );
    },
  );

  final growthInputs = <String, String Function(int)>{
    'alternating BEGIN END': (n) {
      const block = '-----BEGIN PRIVATE KEY----------END PRIVATE KEY-----';
      return (block * (n ~/ block.length + 1)).substring(0, n);
    },
    'long invalid labels': (n) {
      final block = '-----BEGIN ${'AZ09 ' * 200}';
      return (block * (n ~/ block.length + 1)).substring(0, n);
    },
    'single invalid label': (n) => '-----BEGIN ${'A' * n}',
    '100k BEGIN no END': (n) => '-----BEGIN PRIVATE KEY-----' * n,
    'overlapping-rescan sentinel': (n) => '-----BEGIN PRIVATE KEY-----' * n,
    'single line': (n) => 'A' * n,
    'JWT': (n) => 'eyJ-' * (n ~/ 4),
    'assignment': (n) => 'TOKEN_' * (n ~/ 6),
    'inline trailing space': (n) {
      const block = '-----BEGIN PRIVATE KEY----------END PRIVATE KEY----- ';
      return (block * (n ~/ block.length + 1)).substring(0, n);
    },
    'armor body': (n) => '-----BEGIN PGP PRIVATE KEY BLOCK-----\n${'A' * n}',
    'many distinct labels': (n) {
      final buffer = StringBuffer();
      for (var i = 0; buffer.length < n; i++) {
        buffer.write(
          '-----BEGIN L$i PRIVATE KEY-----x-----END L$i PRIVATE KEY-----',
        );
      }
      return buffer.toString().substring(0, n);
    },
    'armor header': (n) =>
        '-----BEGIN PGP PRIVATE KEY BLOCK-----\n${'Comment: Synthetic armor\n' * (n ~/ 25 + 1)}',
  };
  for (final entry in growthInputs.entries) {
    test('FIX4 linear growth ${entry.key}', () {
      final n = switch (entry.key) {
        '100k BEGIN no END' => 25000,
        'overlapping-rescan sentinel' => 2000,
        // 4N stays at 2 MiB: an identifier run of 4 MiB overflows the regex
        // stack (fails closed), which the context builders avoid (ledger).
        _ => 512 * 1024,
      };
      final small = entry.value(n);
      final large = entry.value(4 * n);
      final redactor = Redactor(secrets: _Secrets());
      final smallMicros = _redactionMicros(redactor, small);
      final largeMicros = _redactionMicros(redactor, large);
      // ignore: avoid_print
      print(
        'FIX4 growth ${entry.key}: N=${small.length} $smallMicros us; '
        '4N=${large.length} $largeMicros us; ratio=${largeMicros / smallMicros}',
      );
      // Linear growth is 4x and quadratic 16x; 8x leaves room for noise on a
      // loaded runner.
      expect(largeMicros, lessThan(smallMicros * 8));
      expect(largeMicros, lessThan(5000000));
    }, timeout: const Timeout(Duration(minutes: 2)));
  }

  test('FIX5 BEGIN/END pairing grows linearly from N to 8N', () {
    // Many short pairs: a quadratic pairing loop shows at 4N even though the
    // marker scan dominates at 2N.
    String pairs(int n) {
      const block = '-----BEGIN PRIVATE KEY----- k -----END PRIVATE KEY-----\n';
      return (block * (n ~/ block.length + 1)).substring(0, n);
    }

    final redactor = Redactor(secrets: _Secrets());
    final small = pairs(512 * 1024);
    final large = pairs(4 * 1024 * 1024);
    final smallMicros = _redactionMicros(redactor, small);
    final largeMicros = _redactionMicros(redactor, large);
    // ignore: avoid_print
    print(
      'FIX5 pairing growth: N=${small.length} $smallMicros us; '
      '8N=${large.length} $largeMicros us; ratio=${largeMicros / smallMicros}',
    );
    // Linear growth is 8x and quadratic pairing 64x.
    expect(largeMicros, lessThan(smallMicros * 14));
    expect(largeMicros, lessThan(10000000));
  }, timeout: const Timeout(Duration(minutes: 2)));

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

    final result = redactor.redactSource(values.join('\n'));

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

    final result = redactor.redactSource(tokens.join('\n'));

    for (final token in tokens) {
      expect(
        result.text,
        isNot(contains(token)),
        reason: token.substring(0, 4),
      );
    }
    expect(
      redactor.redactSource('akia${'D' * 16} GHP_${'b' * 36}').redactions,
      0,
    );
  });

  test(
    'known secrets are longest-first, exact, and cumulative across rotation',
    () {
      final source = _Secrets()..values = ['abcd', 'abcdefgh'];
      final redactor = Redactor(secrets: source, patterns: const []);

      expect(
        redactor.redactSource('abcdefgh abcd').text,
        '[REDACTED] [REDACTED]',
      );
      source.values = ['new-token'];

      expect(
        redactor.redactSource('abcdefgh old abcd new-token').text,
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
        Redactor(secrets: source, patterns: const []).redactSource(text).text,
        'before [REDACTED] after',
      );
    },
  );

  test('masking before a caller truncates cannot retain a secret prefix', () {
    final source = _Secrets()..values = ['rotated-secret'];
    final redacted = Redactor(
      secrets: source,
      patterns: const [],
    ).redactSource('prefix rotated-secret suffix').text;

    expect(redacted.substring(0, 18), isNot(contains('rotated')));
  });

  test('unterminated PEM withholds all remaining input without a cap', () {
    final redactor = Redactor(secrets: _Secrets(), patterns: const []);
    final blankBounded = redactor.redactSource(
      'x\n-----BEGIN PRIVATE KEY-----\nsecret\n\nvisible',
    );
    const begin = '-----BEGIN RSA PRIVATE KEY-----';
    const windowChars = 32 * 1024; // At most 64 KiB of UTF-16 text.
    final window = begin + 'A' * (windowChars - begin.length);
    final windowBounded = redactor.redactSource('$window!after-window');

    expect(blankBounded.text, 'x\n[REDACTED:private_key_unterminated]');
    expect(windowBounded.text, '[REDACTED:private_key_unterminated]');
  });

  test('redacts matching PEM end marker and preserves following content', () {
    final result = Redactor(secrets: _Secrets(), patterns: const [])
        .redactSource(
          '-----BEGIN EC PRIVATE KEY-----\nabc\n'
          '-----END EC PRIVATE KEY-----\nafter',
        );

    expect(result.text, '[REDACTED]after');
  });

  test('handles CRLF PEM and content following BEGIN on the same line', () {
    final redactor = Redactor(secrets: _Secrets(), patterns: const []);

    expect(
      redactor
          .redactSource(
            '-----BEGIN PRIVATE KEY-----\r\nabc\r\n'
            '-----END PRIVATE KEY-----\r\nafter',
          )
          .text,
      '[REDACTED]after',
    );
    expect(
      redactor.redactSource('-----BEGIN PRIVATE KEY-----abc').text,
      '[REDACTED:private_key_unterminated]',
    );
  });

  test(
    'preserves URL scheme and host separator while removing credentials',
    () {
      final result = Redactor(
        secrets: _Secrets(),
      ).redactSource('POSTGRES://user:password@database.internal:5432/db');

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
      final result = redactor.redactSource(input);
      expect(result.text, isNot(contains(hidden)), reason: label);
      expect(result.redactions, 1);
    });
  }

  test('marker collisions fail closed instead of retaining a known secret', () {
    for (final secret in ['REDACTED', 'EDAC', '[REDACTED]']) {
      final redactor = Redactor(secrets: _Secrets()..values = [secret]);
      expect(
        () => redactor.redactSource(secret),
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
    ).redactSource('abcdef');
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
      final result = Redactor(secrets: _Secrets()).redactSource(input);
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
      final result = Redactor(secrets: _Secrets()).redactSource(input);
      expect(result.text, expected, reason: input.split(RegExp('[:=]')).first);
      expect(result.redactions, 1);
    }
    const ordinary = 'NotAuthorization: visible\nmax_tokens: 1024';
    expect(Redactor(secrets: _Secrets()).redactSource(ordinary).text, ordinary);
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
      final result = Redactor(secrets: _Secrets()).redactSource(input);
      expect(result.text, isNot(contains('SYNTHETIC-CREDENTIAL')));
      expect(result.redactions, 1);
    }
    expect(
      Redactor(
        secrets: _Secrets(),
      ).redactSource('{"max_tokens": 1024, "tokens": 123456789}').redactions,
      0,
    );
  });

  test('encrypted and PGP private keys redact through matching END', () {
    for (final label in ['RSA PRIVATE KEY', 'PGP PRIVATE KEY BLOCK']) {
      final result = Redactor(secrets: _Secrets()).redactSource(
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
      final result = Redactor(secrets: _Secrets()).redactSource(input);
      expect(result.text, 'before\n[REDACTED]after');
      expect(result.redactions, 1);
    });
  }

  test(
    'PEM END around the former 32 KiB boundary preserves following text',
    () {
      const begin = '-----BEGIN PRIVATE KEY-----';
      const end = '-----END PRIVATE KEY-----';
      const cap = 32 * 1024;
      final redactor = Redactor(secrets: _Secrets());
      final fitting = begin + 'A' * (cap - begin.length - end.length) + end;
      expect(redactor.redactSource('$fitting\nafter').text, '[REDACTED]after');
      final outside = begin + 'A' * (cap - begin.length);
      expect(
        redactor.redactSource('$outside$end\nafter').text,
        '[REDACTED]after',
      );
    },
  );

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
          final result = Redactor(secrets: _Secrets()).redactSource(input);
          // The prefix's BEGIN never meets its own END.
          expect(
            result.text,
            '${prefix.substring(0, firstBegin)}'
            '[REDACTED:private_key_unterminated]',
          );
          expect(body.where(result.text.contains), isEmpty);
          expect(result.redactions, 1);
          expect(result.withheldPrivateKeyContext, isTrue);
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
      final result = Redactor(secrets: _Secrets()).redactSource(input);
      expect(result.text, 'before$lineEnding[REDACTED]after');
      expect(result.redactions, 1);
    });
  }

  test('PEM armor headers around 32 KiB retain no header or body tail', () {
    const begin = '-----BEGIN PGP PRIVATE KEY BLOCK-----\n';
    const header = 'Comment: Synthetic armor header with spaces\n';
    for (var split = 1; split < header.length; split++) {
      final padding = 'A' * (32 * 1024 - begin.length - split - 1);
      final input =
          '$begin$padding\n$header${'B' * 64}\n=AAAA\n'
          '-----END PGP PRIVATE KEY BLOCK-----\nafter';
      expect(
        Redactor(secrets: _Secrets()).redactSource(input).text,
        '[REDACTED]after',
      );
    }
  });

  test('PEM END beyond the former 1 MiB cap preserves following text', () {
    final input =
        '-----BEGIN PRIVATE KEY-----\n${'A' * (2 * 1024 * 1024)}\n'
        '-----END PRIVATE KEY-----\nafter';
    expect(
      Redactor(secrets: _Secrets()).redactSource(input).text,
      '[REDACTED]after',
    );
  });

  test('PEM nested BEGIN beyond 1 MiB stays withheld without its own END', () {
    const begin = '-----BEGIN PRIVATE KEY-----\n';
    final padding = 'A' * (32 * 1024 + 1024 * 1024 - begin.length - 13);
    final input =
        '$begin$padding\n-----BEGIN RSA PRIVATE KEY-----\n${'B' * 64}\n'
        '-----END RSA PRIVATE KEY-----\nafter';
    expect(
      Redactor(secrets: _Secrets()).redactSource(input).text,
      '[REDACTED:private_key_unterminated]',
    );
  });

  test('separate PEM ranges preserve intervening text across 32 KiB', () {
    const first = '-----BEGIN PRIVATE KEY-----x-----END PRIVATE KEY-----';
    const second = '-----BEGIN RSA PRIVATE KEY-----';
    final padding = ' ' * (32 * 1024 - first.length - second.length - 5);
    final input =
        '$first$padding$second\n${'A' * 100}\n'
        '-----END RSA PRIVATE KEY-----\nafter';
    final result = Redactor(secrets: _Secrets()).redactSource(input);
    expect(result.text, '[REDACTED]$padding[REDACTED]after');
    expect(result.redactions, 2);
  });

  test('PEM foreign END inside a key withholds from the start', () {
    final result = Redactor(secrets: _Secrets()).redactSource(
      'intro\n-----BEGIN PGP PRIVATE KEY BLOCK-----\n\n'
      '-----END RSA PRIVATE KEY-----\nSYNTHETIC-KEY-BODY\n'
      '-----END PGP PRIVATE KEY BLOCK-----\nafter',
    );
    expect(result.text, '[REDACTED:private_key_unopened]after');
    expect(result.redactions, 1);
    expect(result.withheldPrivateKeyContext, isTrue);
  });

  test('FIX7 fragments with any private-key marker are withheld whole', () {
    final redactor = Redactor(secrets: _Secrets());
    // Round-7 review: cut at both ends, the BEGIN belongs to key B and the
    // END to key A; markers alone match a complete key between plain text.
    const begin = '-----BEGIN RSA PRIVATE KEY-----';
    const end = '-----END RSA PRIVATE KEY-----';
    const cut = 'A_TAIL\n$begin\nB_HEAD\n$end\nB_TAIL\n';
    final fragment = redactor.redactFragment(cut);
    expect(fragment.text, '[REDACTED:private_key_fragment]');
    expect(fragment.withheldPrivateKeyContext, isTrue);
    for (final marker in [begin, end, '-----BEGIN PRIVATE KEY-----']) {
      expect(
        redactor.redactFragment('log\n$marker\nmore').text,
        '[REDACTED:private_key_fragment]',
      );
    }
    // Fragments without a private-key marker use the ordinary rules.
    final plain = redactor.redactFragment(
      'a glpat-${'x' * 20} line\n-----BEGIN CERTIFICATE-----',
    );
    expect(plain.text, 'a [REDACTED] line\n-----BEGIN CERTIFICATE-----');
    expect(plain.withheldPrivateKeyContext, isFalse);
    // A complete source is not a fragment: the same text keeps its context.
    expect(redactor.redactSource(cut).text, 'A_TAIL\n[REDACTED]B_TAIL\n');
    final collision = Redactor(
      secrets: _Secrets()..values = ['private_key_fragment'],
    );
    expect(
      () => collision.redactFragment('$begin x'),
      throwsA(
        isA<AiFailure>().having(
          (f) => f.kind,
          'kind',
          AiFailureKind.policyBlocked,
        ),
      ),
    );
  });

  test('FIX8 fragments with a cut marker are withheld whole', () {
    final redactor = Redactor(secrets: _Secrets());
    const withheld = '[REDACTED:private_key_fragment]';
    for (final cut in [
      // Both delimiters cut by one hyphen; the label survives.
      '----BEGIN RSA PRIVATE KEY-----\nBODY\n-----END RSA PRIVATE KEY----',
      // The end of a BEGIN marker starts the fragment.
      'IVATE KEY-----\nBODY1\nBODY2',
      'Y-----\nBODY1',
      '--\r\nBODY1',
      'ATE KEY BLOCK-----\nBODY1',
      // The start of an END marker ends the fragment.
      'BODY1\nBODY2\n-----EN',
      'BODY1\n-----END RSA PRIV',
      'BODY1\n---',
      // Indented or prefixed END cut at the end of the fragment.
      'BODY1\n  --',
      'BODY1\n2026-10-21T00:00:00.000000Z 00O -----END RSA PRIV',
    ]) {
      final result = redactor.redactFragment(cut);
      expect(result.text, withheld, reason: cut);
      expect(result.withheldPrivateKeyContext, isTrue);
    }
    // Ordinary fragments are not withheld.
    for (final plain in [
      'log line\nnext line',
      'a - b\nc -- d',
      '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----',
    ]) {
      expect(redactor.redactFragment(plain).text, plain);
    }
  });

  test('FIX8 many distinct labels grow linearly from N to 8N', () {
    String labels(int n) {
      final buffer = StringBuffer();
      for (var i = 0; buffer.length < n; i++) {
        buffer.write(
          '-----BEGIN L$i PRIVATE KEY-----x-----END L$i PRIVATE KEY-----',
        );
      }
      return buffer.toString().substring(0, n);
    }

    final redactor = Redactor(secrets: _Secrets());
    final small = labels(512 * 1024);
    final large = labels(4 * 1024 * 1024);
    final smallMicros = _redactionMicros(redactor, small);
    final largeMicros = _redactionMicros(redactor, large);
    // ignore: avoid_print
    print(
      'FIX8 label growth: N=${small.length} $smallMicros us; '
      '8N=${large.length} $largeMicros us; ratio=${largeMicros / smallMicros}',
    );
    // Linear is 8x; per-END work over all labels grows about 64x.
    expect(largeMicros, lessThan(smallMicros * 14));
    expect(largeMicros, lessThan(10000000));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('FIX6 interleaved keys stay redacted until every label closes', () {
    final redactor = Redactor(secrets: _Secrets());
    String key(String label, String part) =>
        '-----$part $label PRIVATE KEY-----\n';
    // Three keys printed interleaved (round-6 review).
    final three = redactor.redactSource(
      '${key('EC', 'BEGIN')}A_HEAD\n${key('RSA', 'BEGIN')}B_HEAD\n'
      '${key('EC', 'END')}B_TAIL\n${key('OPENSSH', 'BEGIN')}C_BODY\n'
      '${key('OPENSSH', 'END')}${key('RSA', 'END')}after',
    );
    expect(three.text, '[REDACTED]after');
    expect(three.withheldPrivateKeyContext, isFalse);
    // The second key of the same label is cut off before its END.
    final cut = redactor.redactSource(
      'x\n${key('RSA', 'BEGIN')}A\n${key('RSA', 'BEGIN')}B\n'
      '${key('RSA', 'END')}B_TAIL',
    );
    expect(cut.text, 'x\n[REDACTED:private_key_unterminated]');
    // A log read from an offset inside interleaved keys, same and
    // different labels: the tail before the first BEGIN is withheld.
    for (final (first, second) in [('RSA', 'RSA'), ('RSA', 'EC')]) {
      final midRead = redactor.redactSource(
        'A_TAIL\n${key(second, 'BEGIN')}B1\n${key(first, 'END')}B2\n'
        '${key(second, 'END')}after',
      );
      expect(midRead.text, '[REDACTED:private_key_unopened]after');
      expect(midRead.withheldPrivateKeyContext, isTrue);
    }
  });

  test('single-line PEM preserves the following ordinary lines', () {
    final result = Redactor(secrets: _Secrets()).redactSource(
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
      expect(Redactor(secrets: _Secrets()).redactSource(input).text, input);
    }
  });

  test('URL userinfo handles opaque tokens and the final at separator', () {
    for (final userinfo in ['opaquetoken0123456789', 'user:p@ss0123456']) {
      final result = Redactor(
        secrets: _Secrets(),
      ).redactSource('https://$userinfo@host.example/repo.git');
      expect(result.text, 'https://[REDACTED]@host.example/repo.git');
    }
  });

  test('plain SSH git userinfo survives while passwords and tokens do not', () {
    final redactor = Redactor(secrets: _Secrets());
    for (final scheme in ['ssh', 'SSH']) {
      final remote = '$scheme://git@host.example/group/repo.git';
      expect(redactor.redactSource(remote).text, remote);
      expect(redactor.redactSource(remote).redactions, 0);
      expect(
        redactor.redactSource('$scheme://git:pw@host.example/repo.git').text,
        '$scheme://[REDACTED]@host.example/repo.git',
      );
      expect(
        redactor
            .redactSource('$scheme://opaque-token@host.example/repo.git')
            .text,
        '$scheme://[REDACTED]@host.example/repo.git',
      );
    }
    final known = Redactor(secrets: _Secrets()..values = ['git']);
    expect(
      known.redactSource('ssh://git@host.example/repo').text,
      'ssh://[REDACTED]@host.example/repo',
    );
  });

  test('redaction is idempotent with distinct-span counts', () {
    final redactor = Redactor(secrets: _Secrets());
    final first = redactor.redactSource(
      'https://user:pass@host.example/x\n'
      'Authorization: Bearer glpat-${'A' * 20}\n'
      'token = glpat-${'B' * 20}',
    );
    expect(first.redactions, 3);
    final second = redactor.redactSource(first.text);
    expect(second.text, first.text);
    expect(second.redactions, 0);
  });

  test('hostile JWT runs remain under three seconds at 2 MiB', () {
    final redactor = Redactor(secrets: _Secrets());
    redactor.redactSource('eyJ-' * 100);
    // Reject quadratic implementations at 32 KiB before attempting 2 MiB.
    final probe = Stopwatch()..start();
    redactor.redactSource('eyJ-' * 8192);
    probe.stop();
    expect(probe.elapsed, lessThan(const Duration(seconds: 1)));
    final input = 'eyJ-' * (2 * 1024 * 1024 ~/ 4);
    final watch = Stopwatch()..start();
    final result = redactor.redactSource(input);
    watch.stop();
    expect(result.text, input);
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
  });

  test('hostile unterminated PEM blocks remain under five seconds at 2 MiB', () {
    final redactor = Redactor(secrets: _Secrets());
    redactor.redactSource('-----BEGIN PRIVATE KEY-----\n\n' * 10);
    final input = '-----BEGIN PRIVATE KEY-----\n\n' * 72316;
    final watch = Stopwatch()..start();
    final result = redactor.redactSource(input);
    watch.stop();
    // No END: one reason-bearing span withholds every nested BEGIN.
    expect(result.text, '[REDACTED:private_key_unterminated]');
    expect(result.redactions, 1);
    // ignore: avoid_print
    print(
      'unterminated PEM ${input.length} bytes: ${watch.elapsedMilliseconds} ms',
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('2 MiB unterminated armor stays under five seconds', () {
    for (final body in ['A' * 64 + '\n', 'Comment: Synthetic armor\n']) {
      const begin = '-----BEGIN PGP PRIVATE KEY BLOCK-----\n';
      const size = 2 * 1024 * 1024;
      final repeated = body * ((size - begin.length) ~/ body.length + 1);
      final input = begin + repeated.substring(0, size - begin.length);
      final redactor = Redactor(secrets: _Secrets());
      redactor.redactSource('$begin$body');
      final watch = Stopwatch()..start();
      final result = redactor.redactSource(input);
      watch.stop();
      expect(result.text, '[REDACTED:private_key_unterminated]');
      // ignore: avoid_print
      print('armor PEM ${input.length} bytes: ${watch.elapsedMilliseconds} ms');
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    }
  });

  for (final suffix in ['', ' ']) {
    test(
      '2 MiB inline PEM blocks with ${suffix.length} trailing spaces stay under 5 s',
      () {
        const block = '-----BEGIN PRIVATE KEY----------END PRIVATE KEY-----';
        final repeated = block + suffix;
        final count = 2 * 1024 * 1024 ~/ repeated.length;
        final padding = ' ' * (2 * 1024 * 1024 - count * repeated.length);
        final input = repeated * count + padding;
        final redactor = Redactor(secrets: _Secrets());
        redactor.redactSource(repeated * 100);
        final watch = Stopwatch()..start();
        final result = redactor.redactSource(input);
        watch.stop();
        expect(result.redactions, count);
        expect(result.text, '[REDACTED]$suffix' * count + padding);
        // Retain host timing in the expanded acceptance output.
        // ignore: avoid_print
        print(
          'inline PEM ${input.length} bytes, suffix=${suffix.length}: ${watch.elapsedMilliseconds} ms',
        );
        expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  test('hostile assignment runs remain under three seconds at 2 MiB', () {
    final redactor = Redactor(secrets: _Secrets());
    redactor.redactSource('TOKEN_' * 10);
    final input = 'TOKEN_' * 349526;
    final watch = Stopwatch()..start();
    final result = redactor.redactSource(input);
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
        () => redactor.redactSource('content'),
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
      () => redactor.redactSource('content'),
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
