import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/schedule_params.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

const _key = <int>[
  0,
  1,
  2,
  3,
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  15,
  16,
  17,
  18,
  19,
  20,
  21,
  22,
  23,
  24,
  25,
  26,
  27,
  28,
  29,
  30,
  31,
];

Map<String, dynamic> _schedule({
  String ref = 'main',
  Object? variables = const <Object?>[],
  Object? inputs = const <String, Object?>{},
}) => <String, dynamic>{'ref': ref, 'variables': variables, 'inputs': inputs};

AiScheduleParams _evaluate(
  Map<String, dynamic> schedule, {
  bool hasMorePages = false,
  bool truncated = false,
  Object? variablesCount,
  Object? inputsCount,
}) => evaluateScheduleParams(
  schedule,
  key: _key,
  hasMorePages: hasMorePages,
  truncated: truncated,
  variablesCount: variablesCount,
  inputsCount: inputsCount,
);

void main() {
  group('scheduled pipeline parameter binding', () {
    test('HMAC matches an independent SHA-256 vector and binds its key', () {
      // Python stdlib hmac over sorted compact JSON:
      // {"inputs":{},"ref":"main","variables":[]}, key bytes 0..31.
      final result = _evaluate(_schedule());
      final hex = result.hmac!
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(
        hex,
        'b5ce2f3a3c7493d49c45009f2117b17e49a638d3189a8072af0c384e330bbd85',
      );
      final other = evaluateScheduleParams(
        _schedule(),
        key: List<int>.filled(32, 9),
      );
      expect(other.hmac, isNot(orderedEquals(result.hmac!)));
    });

    test('all API variable metadata participates in the HMAC', () {
      AiScheduleParams withMetadata(bool raw) => _evaluate(
        _schedule(
          variables: [
            {'key': 'A', 'value': '1', 'variable_type': 'env_var', 'raw': raw},
          ],
        ),
      );
      expect(
        withMetadata(false).hmac,
        isNot(orderedEquals(withMetadata(true).hmac!)),
      );
    });

    test(
      'covers nonempty variables, inputs-only, and explicit empty states',
      () {
        final variables = _evaluate(
          _schedule(
            ref: 'release',
            variables: const <Object?>[
              <String, Object?>{
                'key': 'DEPLOY_ENV',
                'value': 'staging',
                'variable_type': 'env_var',
              },
            ],
          ),
          variablesCount: 1,
          inputsCount: 0,
        );
        expect(variables.state, AiScheduleParamsState.nonEmpty);
        expect(variables.ref, 'release');
        expect(variables.variableNames, <String>['DEPLOY_ENV']);
        expect(variables.inputNames, isEmpty);
        expect(variables.hmac, hasLength(32));

        final inputs = _evaluate(
          _schedule(
            inputs: const <Object?>[
              <String, Object?>{'name': 'retries', 'value': 3},
            ],
          ),
          variablesCount: 0,
          inputsCount: 1,
        );
        expect(inputs.state, AiScheduleParamsState.nonEmpty);
        expect(inputs.variableNames, isEmpty);
        expect(inputs.inputNames, <String>['retries']);
        expect(inputs.hmac, hasLength(32));

        final empty = _evaluate(
          _schedule(inputs: const <Object?>[]),
          variablesCount: 0,
          inputsCount: 0,
        );
        expect(empty.state, AiScheduleParamsState.explicitEmpty);
        expect(empty.ref, 'main');
        expect(empty.variableNames, isEmpty);
        expect(empty.inputNames, isEmpty);
        expect(empty.hmac, hasLength(32));
      },
    );

    test('missing permission fields and truncation are unreadable', () {
      final missingVariables = _evaluate(<String, dynamic>{
        'ref': 'main',
        'inputs': <String, Object?>{},
      });
      final missingInputs = _evaluate(<String, dynamic>{
        'ref': 'main',
        'variables': <Object?>[],
      });
      final truncated = _evaluate(
        _schedule(),
        truncated: true,
        variablesCount: 0,
        inputsCount: 0,
      );

      for (final result in <AiScheduleParams>[
        missingVariables,
        missingInputs,
        truncated,
      ]) {
        expect(result.state, AiScheduleParamsState.unreadable);
        expect(result.hmac, isNull);
        expect(result.variableNames, isEmpty);
        expect(result.inputNames, isEmpty);
      }
    });

    test(
      'malformed, null, incomplete, and count-mismatched data fail closed',
      () {
        final cases = <AiScheduleParams>[
          _evaluate(_schedule(ref: '')),
          _evaluate(<String, dynamic>{
            'ref': null,
            'variables': <Object?>[],
            'inputs': <String, Object?>{},
          }),
          _evaluate(_schedule(variables: null)),
          _evaluate(_schedule(inputs: null)),
          _evaluate(_schedule(variables: 'not-a-list')),
          _evaluate(_schedule(inputs: 4)),
          _evaluate(
            _schedule(),
            hasMorePages: true,
            variablesCount: 0,
            inputsCount: 0,
          ),
          _evaluate(_schedule(), variablesCount: 1, inputsCount: 0),
          _evaluate(_schedule(), variablesCount: 0, inputsCount: 1),
        ];

        for (final result in cases) {
          expect(result.state, AiScheduleParamsState.unreadable);
          expect(result.hmac, isNull);
        }
      },
    );

    test('the HMAC binds values, variable type, input JSON type, and ref', () {
      final base = _evaluate(
        _schedule(
          variables: const <Object?>[
            <String, Object?>{
              'key': 'A',
              'value': '1',
              'variable_type': 'env_var',
            },
          ],
          inputs: const <String, Object?>{'flag': true},
        ),
      );
      final changedValue = _evaluate(
        _schedule(
          variables: const <Object?>[
            <String, Object?>{
              'key': 'A',
              'value': '2',
              'variable_type': 'env_var',
            },
          ],
          inputs: const <String, Object?>{'flag': true},
        ),
      );
      final changedType = _evaluate(
        _schedule(
          variables: const <Object?>[
            <String, Object?>{
              'key': 'A',
              'value': '1',
              'variable_type': 'file',
            },
          ],
          inputs: const <String, Object?>{'flag': true},
        ),
      );
      final changedJsonType = _evaluate(
        _schedule(
          variables: const <Object?>[
            <String, Object?>{
              'key': 'A',
              'value': '1',
              'variable_type': 'env_var',
            },
          ],
          inputs: const <String, Object?>{'flag': 'true'},
        ),
      );
      final changedRef = _evaluate(
        _schedule(
          ref: 'next',
          variables: const <Object?>[
            <String, Object?>{
              'key': 'A',
              'value': '1',
              'variable_type': 'env_var',
            },
          ],
          inputs: const <String, Object?>{'flag': true},
        ),
      );

      for (final changed in <AiScheduleParams>[
        changedValue,
        changedType,
        changedJsonType,
        changedRef,
      ]) {
        expect(changed.hmac, isNot(orderedEquals(base.hmac!)));
      }
      expect(_evaluate(_schedule(), truncated: true).hmac, isNull);
    });

    test(
      'collection order is stable while nested array order remains bound',
      () {
        final first = _evaluate(
          _schedule(
            variables: const <Object?>[
              <String, Object?>{
                'key': 'B',
                'value': '2',
                'variable_type': 'file',
              },
              <String, Object?>{
                'key': 'A',
                'value': '1',
                'variable_type': 'env_var',
              },
            ],
            inputs: const <Object?>[
              <String, Object?>{
                'name': 'zeta',
                'value': <Object?>[1, 2],
              },
              <String, Object?>{'name': 'alpha', 'value': true},
            ],
          ),
        );
        final reordered = _evaluate(
          _schedule(
            variables: const <Object?>[
              <String, Object?>{
                'key': 'A',
                'value': '1',
                'variable_type': 'env_var',
              },
              <String, Object?>{
                'key': 'B',
                'value': '2',
                'variable_type': 'file',
              },
            ],
            inputs: const <Object?>[
              <String, Object?>{'name': 'alpha', 'value': true},
              <String, Object?>{
                'name': 'zeta',
                'value': <Object?>[1, 2],
              },
            ],
          ),
        );
        final nestedReordered = _evaluate(
          _schedule(
            variables: const <Object?>[
              <String, Object?>{
                'key': 'A',
                'value': '1',
                'variable_type': 'env_var',
              },
              <String, Object?>{
                'key': 'B',
                'value': '2',
                'variable_type': 'file',
              },
            ],
            inputs: const <String, Object?>{
              'alpha': true,
              'zeta': <Object?>[2, 1],
            },
          ),
        );

        expect(first.variableNames, <String>['A', 'B']);
        expect(first.inputNames, <String>['alpha', 'zeta']);
        expect(first.hmac, orderedEquals(reordered.hmac!));
        expect(first.hmac, isNot(orderedEquals(nestedReordered.hmac!)));
      },
    );

    test('length-prefixed JSON binding has no A=B=C boundary collision', () {
      final left = _evaluate(
        _schedule(
          variables: const <Object?>[
            <String, Object?>{
              'key': 'A',
              'value': 'B=C',
              'variable_type': 'env_var',
            },
          ],
        ),
      );
      final right = _evaluate(
        _schedule(
          variables: const <Object?>[
            <String, Object?>{
              'key': 'A=B',
              'value': 'C',
              'variable_type': 'env_var',
            },
          ],
        ),
      );
      expect(left.hmac, isNot(orderedEquals(right.hmac!)));
    });

    test(
      'invalid HMAC keys fail closed without retaining parameter values',
      () {
        final schedule = _schedule(
          variables: const <Object?>[
            <String, Object?>{
              'key': 'VISIBLE_NAME',
              'value': 'schedule-value-must-not-survive',
              'variable_type': 'env_var',
            },
          ],
          inputs: const <String, Object?>{
            'VISIBLE_INPUT': 'input-value-must-not-survive',
          },
        );
        final readable = _evaluate(schedule);
        expect(readable.variableNames, <String>['VISIBLE_NAME']);
        expect(readable.inputNames, <String>['VISIBLE_INPUT']);
        expect(
          readable.toString(),
          isNot(contains('schedule-value-must-not-survive')),
        );
        expect(
          readable.toString(),
          isNot(contains('input-value-must-not-survive')),
        );

        for (final badKey in <List<int>>[
          List<int>.filled(31, 0),
          List<int>.filled(33, 0),
          <int>[...List<int>.filled(31, 0), -1],
          <int>[...List<int>.filled(31, 0), 256],
        ]) {
          final result = evaluateScheduleParams(schedule, key: badKey);
          expect(result.state, AiScheduleParamsState.unreadable);
          expect(result.hmac, isNull);
        }
      },
    );

    test('returned names and HMAC bytes cannot be mutated', () {
      final result = _evaluate(
        _schedule(
          variables: const <Object?>[
            <String, Object?>{
              'key': 'A',
              'value': '1',
              'variable_type': 'env_var',
            },
          ],
          inputs: const <String, Object?>{'flag': true},
        ),
      );
      expect(() => result.variableNames.add('B'), throwsUnsupportedError);
      expect(() => result.inputNames.add('other'), throwsUnsupportedError);
      expect(() => result.hmac![0] = 99, throwsUnsupportedError);
    });
  });

  group('pipeline variables', () {
    test('null and an empty list are accepted as empty optional variables', () {
      for (final raw in <Object?>[null, <Object?>[]]) {
        final result = validatePipelineVariables(raw, knownSecrets: const {});
        expect(result, isA<AiPipelineVariablesAccepted>());
        expect((result as AiPipelineVariablesAccepted).variables, isEmpty);
      }
    });

    test('accepts canonical records and only the optional supported type', () {
      final result =
          validatePipelineVariables(const <Object?>[
                <String, Object?>{'key': 'PLAIN', 'value': 'one'},
                <String, Object?>{
                  'key': 'ENVIRONMENT',
                  'value': 'two',
                  'variable_type': 'env_var',
                },
                <String, Object?>{
                  'key': 'FILE_CONTENT',
                  'value': 'three',
                  'variable_type': 'file',
                },
              ], knownSecrets: const {})
              as AiPipelineVariablesAccepted;

      expect(result.variables, <Map<String, String>>[
        <String, String>{'key': 'PLAIN', 'value': 'one'},
        <String, String>{
          'key': 'ENVIRONMENT',
          'value': 'two',
          'variable_type': 'env_var',
        },
        <String, String>{
          'key': 'FILE_CONTENT',
          'value': 'three',
          'variable_type': 'file',
        },
      ]);
      expect(
        () => result.variables.add(<String, String>{}),
        throwsUnsupportedError,
      );
      expect(
        () => result.variables.first['value'] = 'changed',
        throwsUnsupportedError,
      );
    });

    test('rejects malformed records, duplicate names, and unknown keys', () {
      final cases = <Object?>[
        'not-a-list',
        <Object?>[null],
        <Object?>[
          <String, Object?>{'key': 'A'},
        ],
        <Object?>[
          <String, Object?>{'key': 'A', 'value': 1},
        ],
        <Object?>[
          <String, Object?>{'key': 1, 'value': 'x'},
        ],
        <Object?>[
          <String, Object?>{'key': 'A', 'value': 'x', 'extra': 'y'},
        ],
        <Object?>[
          <String, Object?>{'key': 'A', 'value': 'x', 'variable_type': 'raw'},
        ],
        <Object?>[
          <String, Object?>{'key': 'A', 'value': 'x'},
          <String, Object?>{'key': 'A', 'value': 'y'},
        ],
      ];

      for (final raw in cases) {
        final result = validatePipelineVariables(raw, knownSecrets: const {});
        expect(result, isA<AiPipelineVariablesRejected>());
        expect(
          (result as AiPipelineVariablesRejected).reasonCode,
          'pipelineVariablesInvalid',
        );
      }
    });

    test(
      'names are ASCII alphanumeric or underscore and block reserved forms',
      () {
        final invalid = <String>['', 'A-B', 'naïve', 'with space'];
        for (final name in invalid) {
          final result =
              validatePipelineVariables(<Object?>[
                    <String, Object?>{'key': name, 'value': 'safe'},
                  ], knownSecrets: const {})
                  as AiPipelineVariablesRejected;
          expect(result.reasonCode, 'pipelineVariablesInvalid', reason: name);
        }

        final blocked = <String>[
          'CI_JOB_TOKEN',
          'ci_custom',
          'GITLAB_USER_ID',
          'gitlab_custom',
          'APP_DEBUG_FLAG',
          'app_debug_mode',
        ];
        for (final name in blocked) {
          final result =
              validatePipelineVariables(<Object?>[
                    <String, Object?>{'key': name, 'value': 'safe'},
                  ], knownSecrets: const {})
                  as AiPipelineVariablesRejected;
          expect(
            result.reasonCode,
            'pipelineVariableNameBlocked',
            reason: name,
          );
        }
        for (final name in ['DEBUG_TRACE', 'debug_value']) {
          expect(
            validatePipelineVariables([
              {'key': name, 'value': 'safe'},
            ], knownSecrets: const {}),
            isA<AiPipelineVariablesAccepted>(),
            reason: name,
          );
        }
      },
    );

    test(
      'scans canonical keys, values, and types for known or patterned secrets',
      () {
        final cases = <(Object?, Set<String>)>[
          (
            <Object?>[
              <String, Object?>{
                'key': 'SAFE_NAME',
                'value': 'known-secret-value',
              },
            ],
            const {'known-secret-value'},
          ),
          (
            <Object?>[
              <String, Object?>{'key': 'KNOWN_SECRET_VALUE', 'value': 'safe'},
            ],
            const {'KNOWN_SECRET_VALUE'},
          ),
          (
            <Object?>[
              <String, Object?>{
                'key': 'SAFE_NAME',
                'value': 'safe',
                'variable_type': 'env_var',
              },
            ],
            const {'env_var'},
          ),
          (
            <Object?>[
              <String, Object?>{
                'key': 'SAFE_NAME',
                'value': 'glpat-ABCDEFGHIJKLMNOPQRST',
              },
            ],
            const {},
          ),
        ];

        for (final (raw, secrets) in cases) {
          final result = validatePipelineVariables(raw, knownSecrets: secrets);
          expect(result, isA<AiPipelineVariablesRejected>());
          expect((result as AiPipelineVariablesRejected).reasonCode, 'secret');
        }
      },
    );

    test('rejects an existing redaction marker before dispatch', () {
      final result =
          validatePipelineVariables(const <Object?>[
                <String, Object?>{'key': 'SAFE_NAME', 'value': '[REDACTED]'},
              ], knownSecrets: const {})
              as AiPipelineVariablesRejected;
      expect(result.reasonCode, 'redactionMarker');
    });
  });

  test(
    'the schedule HMAC key is immutable and shared by every journal owner',
    () {
      final rootA = Directory.systemTemp.createTempSync('schedule-key-a.');
      final rootB = Directory.systemTemp.createTempSync('schedule-key-b.');
      try {
        final firstOwner = AiWriteJournal(
          keys: MemoryAiJournalKeyStore(),
          applicationSupport: rootA,
        );
        final secondOwner = AiWriteJournal(
          keys: MemoryAiJournalKeyStore(),
          applicationSupport: rootB,
        );

        final first = firstOwner.scheduleHmacKey;
        final reread = firstOwner.scheduleHmacKey;
        final second = secondOwner.scheduleHmacKey;
        final singleton = AiWriteJournal.instance.scheduleHmacKey;

        expect(first, hasLength(32));
        expect(first, everyElement(inInclusiveRange(0, 255)));
        expect(reread, orderedEquals(first));
        expect(second, orderedEquals(first));
        expect(singleton, orderedEquals(first));
        expect(() => first[0] = first[0] ^ 0xff, throwsUnsupportedError);
        expect(rootA.listSync(), isEmpty);
        expect(rootB.listSync(), isEmpty);
      } finally {
        rootA.deleteSync(recursive: true);
        rootB.deleteSync(recursive: true);
      }
    },
  );
}
