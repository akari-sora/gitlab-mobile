import 'ai_failure.dart';

const _redacted = '[REDACTED]';

abstract interface class KnownSecretsSource {
  Iterable<String> get current;
}

final class RedactionPattern {
  const RedactionPattern(this.name, this.pattern, {this.caseSensitive = true});

  final String name;
  final String pattern;
  final bool caseSensitive;
}

final class RedactionResult {
  const RedactionResult(this.text, this.redactions);

  final String text;
  final int redactions;
}

final class Redactor {
  Redactor({
    required KnownSecretsSource secrets,
    List<RedactionPattern> patterns = defaultRedactionPatterns,
  }) : _secrets = secrets,
       _patternDefinitions = List.unmodifiable(patterns);

  static const List<RedactionPattern> defaultRedactionPatterns = [
    RedactionPattern(
      'gitlab',
      r'\b(?:glpat|gldt|glrt|glrtr|glcbt|glptt|glft|glimt|glagent|glsoat|gloas|glffct|glwt)-[0-9A-Za-z_\-.]{20,}',
    ),
    RedactionPattern('gitlab-runner', r'\bGR1348941[0-9A-Za-z_\-]{20,}'),
    RedactionPattern('github', r'\bgh[pousr]_[A-Za-z0-9]{36,255}\b'),
    RedactionPattern(
      'github-fine-grained',
      r'\bgithub_pat_[A-Za-z0-9_]{22,255}\b',
    ),
    RedactionPattern(
      'openai-anthropic-openrouter',
      r'\bsk-(?:proj-|svcacct-|admin-|ant-[a-z]+\d{2}-|or-v1-)?[A-Za-z0-9_\-]{20,}',
    ),
    RedactionPattern('opencode', r'\boc_sk_[A-Za-z0-9_\-]{16,}'),
    RedactionPattern('google', r'\bAIza[0-9A-Za-z_\-]{35}\b'),
    RedactionPattern(
      'aws-access-key',
      r'\b(?:AKIA|ASIA|ABIA|ACCA)[0-9A-Z]{16}\b',
    ),
    RedactionPattern(
      'aws-secret',
      r'''aws_secret_access_key\s*[:=]\s*["']?[A-Za-z0-9/+=]{40}''',
      caseSensitive: false,
    ),
    RedactionPattern('slack-token', r'\bxox[abprs]-[0-9A-Za-z\-]{10,}'),
    RedactionPattern(
      'slack-webhook',
      r'https://hooks\.slack\.com/services/[A-Za-z0-9/_\-]+',
    ),
    RedactionPattern('stripe', r'\b(?:sk|rk)_(?:live|test)_[0-9A-Za-z]{16,}'),
    RedactionPattern('npm', r'\bnpm_[A-Za-z0-9]{36}\b'),
    RedactionPattern('pypi', r'\bpypi-AgEIcHlwaS5vcmc[A-Za-z0-9_\-]{50,}'),
    RedactionPattern('docker', r'\bdckr_pat_[A-Za-z0-9_\-]{27,}'),
    RedactionPattern(
      'jwt',
      r'\beyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}',
    ),
  ];

  static const RedactionPattern urlCredentialsPattern = RedactionPattern(
    'url-credentials',
    r'\b((?:https?|ftp|ssh|git|postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqps?)://)[^/\s:@]+:[^/\s@]+@',
    caseSensitive: false,
  );

  static const List<RedactionPattern> assignmentPatterns = [
    RedactionPattern(
      'header',
      r'''\b(authorization|private-token|job-token|x-api-key|api-key|x-goog-api-key)\b\s*[:=]\s*(?:bearer\s+|basic\s+)?[^\s"']+''',
      caseSensitive: false,
    ),
    RedactionPattern(
      'generic',
      r'''\b(password|passwd|pwd|secret|client_secret|token|api[_-]?key|access[_-]?key|private[_-]?key)\b\s*[:=]\s*["']?[^\s"']{8,}''',
      caseSensitive: false,
    ),
  ];

  final KnownSecretsSource _secrets;
  final List<RedactionPattern> _patternDefinitions;
  final Set<String> _knownSecrets = {};
  List<RegExp>? _patterns;
  List<RegExp>? _assignments;
  RegExp? _urlCredentials;

  RedactionResult redact(String input) {
    try {
      _refreshSecrets();
      _compilePatterns();
      var text = input;
      var count = 0;

      final secrets = _knownSecrets.toList()
        ..sort((left, right) => right.length.compareTo(left.length));
      for (final secret in secrets) {
        final occurrences = _literalOccurrences(text, secret);
        if (occurrences == 0) continue;
        text = text.replaceAll(secret, _redacted);
        count += occurrences;
      }

      (text, count) = _replacePatterns(text, count, _patterns!);

      final pem = _redactPemBlocks(text);
      text = pem.text;
      count += pem.redactions;

      final urlMatches = _urlCredentials!.allMatches(text).toList();
      if (urlMatches.isNotEmpty) {
        text = text.replaceAllMapped(
          _urlCredentials!,
          (match) => '${match.group(1)}[REDACTED:url_credentials]@',
        );
        count += urlMatches.length;
      }
      (text, count) = _replacePatterns(text, count, _assignments!);
      return RedactionResult(text, count);
    } on AiFailure {
      rethrow;
    } catch (_) {
      throw const AiFailure(AiFailureKind.policyBlocked);
    }
  }

  void _refreshSecrets() {
    for (final secret in _secrets.current) {
      if (secret.isNotEmpty) _knownSecrets.add(secret);
    }
  }

  void _compilePatterns() {
    if (_patterns != null) return;
    _patterns = [
      for (final definition in _patternDefinitions)
        RegExp(definition.pattern, caseSensitive: definition.caseSensitive),
    ];
    _urlCredentials = RegExp(
      urlCredentialsPattern.pattern,
      caseSensitive: urlCredentialsPattern.caseSensitive,
    );
    _assignments = [
      for (final definition in assignmentPatterns)
        RegExp(definition.pattern, caseSensitive: definition.caseSensitive),
    ];
  }
}

(String, int) _replacePatterns(String text, int count, List<RegExp> patterns) {
  for (final pattern in patterns) {
    final matches = pattern.allMatches(text).length;
    if (matches == 0) continue;
    text = text.replaceAll(pattern, _redacted);
    count += matches;
  }
  return (text, count);
}

int _literalOccurrences(String text, String needle) {
  var count = 0;
  var offset = 0;
  while (true) {
    final match = text.indexOf(needle, offset);
    if (match < 0) return count;
    count += 1;
    offset = match + needle.length;
  }
}

RedactionResult _redactPemBlocks(String input) {
  final begin = RegExp(r'-----BEGIN ([A-Z0-9 ]*PRIVATE KEY)-----');
  var offset = 0;
  var count = 0;
  final output = StringBuffer();
  while (true) {
    final match = begin.firstMatch(input.substring(offset));
    if (match == null) {
      output.write(input.substring(offset));
      break;
    }
    final start = offset + match.start;
    final contentStart = offset + match.end;
    output.write(input.substring(offset, start));

    final endMarker = '-----END ${match.group(1)}-----';
    final firstLineEnd = _lineEnd(input, contentStart);
    var cursor = firstLineEnd.nextOffset;
    var redactionEnd = cursor;
    var lines = 0;
    while (cursor < input.length && lines < 100) {
      final lineEnd = _lineEnd(input, cursor);
      final line = input.substring(cursor, lineEnd.contentEnd);
      lines += 1;
      if (line == endMarker) {
        redactionEnd = lineEnd.nextOffset;
        break;
      }
      if (line.isEmpty) {
        redactionEnd = cursor;
        break;
      }
      redactionEnd = lineEnd.nextOffset;
      cursor = lineEnd.nextOffset;
    }
    output.write(_redacted);
    count += 1;
    offset = redactionEnd;
  }
  return RedactionResult(output.toString(), count);
}

({int contentEnd, int nextOffset}) _lineEnd(String text, int start) {
  for (var index = start; index < text.length; index += 1) {
    final unit = text.codeUnitAt(index);
    if (unit == 0x0a) return (contentEnd: index, nextOffset: index + 1);
    if (unit == 0x0d) {
      final next = index + 1;
      return (
        contentEnd: index,
        nextOffset: next < text.length && text.codeUnitAt(next) == 0x0a
            ? next + 1
            : next,
      );
    }
  }
  return (contentEnd: text.length, nextOffset: text.length);
}
