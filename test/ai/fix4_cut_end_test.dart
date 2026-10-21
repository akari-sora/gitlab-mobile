import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/app_text.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';

import 'runner_test.dart' as base;

void main() {
  test(
    'cut-end trimming includes a single character and only the cut string',
    () {
      final secrets = base.Secrets();
      final redactor = Redactor(secrets: secrets);
      final cut = const AiAppText.plain('keepZebraSecret').clipped(5);
      secrets.current.add('ZebraSecret');
      expect(cut.redact(redactor).encode(), 'keep');
      expect(const AiAppText.plain('keepZ').redact(redactor).encode(), 'keepZ');
      expect(cut.encode(), 'keepZ');
    },
  );

  test(
    'an initially fitting clip keeps its budget after redaction expands text',
    () {
      final secrets = base.Secrets()..current.add('Q');
      final redactor = Redactor(secrets: secrets);
      final cut = const AiAppText.plain('QQQQ').clipped(5);
      expect(cut.redact(redactor).encode().length, lessThanOrEqualTo(5));
      final smaller = cut.redact(redactor).clipped(3);
      expect(smaller.redact(redactor).encode().length, lessThanOrEqualTo(3));
    },
  );

  test('cut-end trimming selects the longest overlapping proper prefix', () {
    final secrets = base.Secrets()..current.addAll(['abac', 'ababac']);
    final redactor = Redactor(secrets: secrets);
    expect(redactor.redactCutEnd('keepababa').text, 'keep');
    expect(redactor.redactCutEnd('keepab').text, 'keep');
    expect(redactor.redactCutEnd('keep').text, 'keep');
  });

  test(
    'a large repetitive late secret trims without retaining its remainder',
    () {
      final secret = '${'Q' * 100000}Z';
      final secrets = base.Secrets();
      final cut = AiAppText.plain('keep$secret').clipped(20000);
      secrets.current.add(secret);
      expect(cut.plainText.length, 20000);
      expect(cut.redact(Redactor(secrets: secrets)).encode(), 'keep');
    },
  );

  test('nested clips preserve both cut-string ordinals across redactions', () {
    final secrets = base.Secrets();
    final first = const AiAppText.plain('keepalphaSecretend').clipped(8);
    final outer = AiAppText.join([
      first,
      const AiAppText.plain('okbetaSecretend'),
    ], '|').clipped(14);
    secrets.current.addAll(['alphaSecret', 'betaSecret']);
    final redactor = Redactor(secrets: secrets);
    final safe = outer.redact(redactor);
    expect(safe.encode(), 'keep|ok');
    expect(safe.redact(redactor).encode(), 'keep|ok');
    expect(outer.encode(), 'keepalph|okbet');
  });
}
