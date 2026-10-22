import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart';
import 'package:gitlab_mobile/core/instance.dart';

// Plan v6 §3.1 "整欄寫回會刪掉看不到的內容": before a write back to the same
// field, the field's current value goes through the outgoing redaction, and
// every span the final text does not keep byte for byte is counted. A count
// above 0 is on the §4.1 fixed confirmation list (bypass included).

const _glpat = 'glpat-ABCDEFGHIJKLMNOPQRST';
const _hex = '0123456789abcdef0123456789abcdef';
const _pem =
    '-----BEGIN RSA PRIVATE KEY-----\n'
    'MIIBOgIBAAJBAKj34GkxFhD90vcNLYLInFEX6Ppy1tPf9Cnzj4p4WGeKLs1Pt8Qu\n'
    'KUpRKfFLfRYC9AIKjbJTWit+CqvjWYzvQwECAwEAAQ\n'
    '-----END RSA PRIVATE KEY-----\n';

void main() {
  test('a glpat token the provider saw as a marker counts as hidden', () {
    const current = 'Deploy notes\ntoken: $_glpat\nend';
    final seen = Redactor(secrets: const _Secrets()).redactSource(current);
    expect(seen.text, 'Deploy notes\n[REDACTED]\nend');

    final prepared = _prepare(
      modelText: 'Deploy notes\nend',
      currentFieldValue: current,
    );
    expect(prepared.policyBlocked, isFalse);
    expect(prepared.finalText, 'Deploy notes\nend');
    expect(prepared.hiddenSpanCount, 1);
    expect(
      prepared.confirmReasons,
      contains(AiFixedConfirmReason.hiddenContentRemoved),
    );

    final bare = _prepare(
      modelText: 'use the token',
      currentFieldValue: 'use $_glpat here',
    );
    expect(bare.hiddenSpanCount, 1);
    expect(
      bare.confirmReasons,
      contains(AiFixedConfirmReason.hiddenContentRemoved),
    );
  });

  test('a password assignment counts as hidden', () {
    const current = 'Login steps\npassword: hunter2hunter2\nthen sign in';
    final prepared = _prepare(
      modelText: 'Login steps\nthen sign in',
      currentFieldValue: current,
    );
    expect(prepared.policyBlocked, isFalse);
    expect(prepared.hiddenSpanCount, 1);
    expect(
      prepared.confirmReasons,
      contains(AiFixedConfirmReason.hiddenContentRemoved),
    );
  });

  test('a private key block counts as one hidden span', () {
    const current = 'Server key:\n$_pem\nRotate it monthly.';
    final prepared = _prepare(
      modelText: 'Server key:\n\nRotate it monthly.',
      currentFieldValue: current,
    );
    expect(prepared.policyBlocked, isFalse);
    expect(prepared.hiddenSpanCount, 1);
    expect(
      prepared.confirmReasons,
      contains(AiFixedConfirmReason.hiddenContentRemoved),
    );
  });

  test('a known secret counts as hidden', () {
    const known = 'synthetic-provider-key-0123456789';
    final prepared = _prepare(
      modelText: 'Use the key from the vault.',
      currentFieldValue: 'Use $known for now.',
      knownSecrets: const {known},
    );
    expect(prepared.policyBlocked, isFalse);
    expect(prepared.hiddenSpanCount, 1);
    expect(
      prepared.confirmReasons,
      contains(AiFixedConfirmReason.hiddenContentRemoved),
    );
  });

  test('upload links: a dropped one counts, a restored one does not', () {
    const other = 'keep ![s](https://x.example/uploads/$_hex/a.png) tail';
    final dropped = _prepare(modelText: 'keep tail', currentFieldValue: other);
    expect(dropped.hiddenSpanCount, 1);
    expect(
      dropped.confirmReasons,
      contains(AiFixedConfirmReason.hiddenContentRemoved),
    );

    final table = _table();
    final field = _field();
    const own = 'Screen ![shot](/uploads/$_hex/shot.png)';
    final outgoing = table.redactOutgoing(own, field: field);
    expect(outgoing, 'Screen ![shot]([[upload:u-1]])');
    final kept = _prepare(
      modelText: 'New wording ![shot]([[upload:u-1]])',
      placeholders: table,
      currentFieldValue: own,
    );
    expect(kept.policyBlocked, isFalse);
    expect(kept.finalText, 'New wording ![shot](/uploads/$_hex/shot.png)');
    expect(kept.hiddenSpanCount, 0);
    expect(kept.confirmReasons, isEmpty);
  });

  test('nothing hidden: no reason and a count of 0', () {
    const current =
        'Plain notes for #12\n\n'
        'See https://gitlab.example.com/group/proj/-/issues/3 and @alice.\n'
        'token: short\n'
        'timeout: 30 seconds\n\n'
        '```\nconst value = 1;\n```\n';
    final prepared = _prepare(
      modelText: 'Rewritten notes',
      currentFieldValue: current,
    );
    expect(prepared.policyBlocked, isFalse);
    expect(prepared.hiddenSpanCount, 0);
    expect(prepared.confirmReasons, isEmpty);
  });

  test('ranges land on the original text after a placeholder token', () {
    const input = 'a [[upload:u-9]] b token: $_glpat c';
    final ranges = Redactor(
      secrets: const _Secrets(),
    ).redactSourceRanges(input);
    expect(
      [for (final range in ranges) input.substring(range.start, range.end)],
      ['[[upload:u-9]]', 'token: $_glpat'],
    );

    final prepared = _prepare(modelText: 'a b c', currentFieldValue: input);
    expect(prepared.hiddenSpanCount, 2);
    expect(
      prepared.confirmReasons,
      contains(AiFixedConfirmReason.hiddenContentRemoved),
    );
  });

  test('a range starting or ending inside a token covers the whole token', () {
    // A known secret can match across the marker that replaced a token;
    // its range then has to cover the original token, not part of it.
    String ranged(String input, String secret) {
      final ranges = Redactor(
        secrets: _Secrets([secret]),
      ).redactSourceRanges(input);
      return [
        for (final range in ranges) input.substring(range.start, range.end),
      ].join('|');
    }

    expect(ranged('[[upload:y]]xyz tail', 'ED]xyz'), '[[upload:y]]xyz');
    expect(ranged('head abc[[upload:y]] tail', 'bc[RED'), 'bc[[upload:y]]');
    expect(
      ranged('[[attachment:q]] mid [[upload:y]]xyz end', 'ED]xyz'),
      '[[attachment:q]]|[[upload:y]]xyz',
    );
  });

  test('ranges refuse exactly when redaction refuses', () {
    final redactor = Redactor(secrets: const _Secrets(['DACT']));
    expect(() => redactor.redactSource('x'), throwsA(isA<AiFailure>()));
    expect(() => redactor.redactSourceRanges('x'), throwsA(isA<AiFailure>()));
  });
}

AiTextOutcome _prepare({
  required String modelText,
  UploadPlaceholderTable? placeholders,
  Set<String> knownSecrets = const <String>{},
  String? currentFieldValue,
}) => prepareWriteText(
  textClass: AiTextClass.quickActionMarkdown,
  modelText: modelText,
  field: _field(),
  placeholders: placeholders ?? _table(),
  knownSecrets: knownSecrets,
  aiAttribution: false,
  visibility: const AiVisibilityContext(targetProjectPath: 'group/proj'),
  currentFieldValue: currentFieldValue,
);

UploadPlaceholderTable _table() => UploadPlaceholderTable(
  instance: GitLabInstance.parse('https://gitlab.example.com'),
);

AiFieldProvenance _field() => AiFieldProvenance(
  resourceKey: const AiConflictKey('project:42/issue:1'),
  fieldName: AiWritableField.issueDescription,
  completeValue: true,
  projectId: 42,
  projectFullPath: 'group/proj',
  resourceWeb: Uri.parse('https://gitlab.example.com/group/proj/-/issues/1'),
);

final class _Secrets implements KnownSecretsSource {
  const _Secrets([this.current = const <String>[]]);

  @override
  final Iterable<String> current;
}
