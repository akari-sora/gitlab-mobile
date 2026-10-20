import 'ai_failure.dart';

const _redacted = '[REDACTED]';
const _unterminatedPrivateKey = '[REDACTED:private_key_unterminated]';
const _unopenedPrivateKey = '[REDACTED:private_key_unopened]';
const _privateKeyFragment = '[REDACTED:private_key_fragment]';

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
  const RedactionResult(
    this.text,
    this.redactions, {
    this.withheldPrivateKeyContext = false,
  });

  final String text;
  final int redactions;

  /// Whether text around a private-key marker was withheld because the
  /// marker had no partner (a BEGIN without END, or an END without BEGIN).
  final bool withheldPrivateKeyContext;
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
      r'(?<![A-Za-z0-9_\-])eyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}',
    ),
  ];

  // Match only the scheme; scan each authority once, bounded by /, ? or #.
  static const RedactionPattern urlCredentialsPattern = RedactionPattern(
    'url-credentials',
    r'\b((?:https?|ftp|ssh|git|postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqps?)://)',
    caseSensitive: false,
  );

  // Applied to whole identifiers, never at every suffix of a long identifier.
  static const List<RedactionPattern> assignmentPatterns = [
    RedactionPattern(
      'header',
      r'(?:^|[_.\-])(?:authorization|private-token|job-token|x-api-key|api-key|x-goog-api-key)$',
      caseSensitive: false,
    ),
    RedactionPattern(
      'generic',
      r'(?:^|[_.\-])(?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key)(?:$|[_.\-])',
      caseSensitive: false,
    ),
  ];

  final KnownSecretsSource _secrets;
  final List<RedactionPattern> _patternDefinitions;
  final Set<String> _knownSecrets = {};
  List<RegExp>? _patterns;
  List<RegExp>? _assignments;
  RegExp? _urlCredentials;

  /// Redacts [input]. Pass [fragment] when [input] is part of a larger
  /// source cut at either end (a log read from an offset, a diff hunk, a
  /// line range): markers alone cannot tell which key a cut BEGIN or END
  /// belongs to, so a fragment holding any private-key marker is withheld
  /// whole. A complete source should be redacted before it is cut.
  RedactionResult redact(String input, {bool fragment = false}) {
    try {
      _refreshSecrets();
      _compilePatterns();
      if (fragment && _privateKeyMarker.hasMatch(input)) {
        if (_knownSecrets.any(_privateKeyFragment.contains)) {
          throw const AiFailure(AiFailureKind.policyBlocked);
        }
        return const RedactionResult(
          _privateKeyFragment,
          1,
          withheldPrivateKeyContext: true,
        );
      }
      // No detector sees another detector's replacement text.
      final ranges = <_RedactionRange>[];
      for (final secret in _knownSecrets) {
        if (_redacted.contains(secret)) {
          throw const AiFailure(AiFailureKind.policyBlocked);
        }
        var offset = 0;
        while (offset < input.length) {
          final start = input.indexOf(secret, offset);
          if (start < 0) break;
          ranges.add(_RedactionRange(start: start, end: start + secret.length));
          offset = start + 1; // Include overlapping exact matches.
        }
      }
      for (final pattern in _patterns!) {
        for (final match in pattern.allMatches(input)) {
          ranges.add(_RedactionRange(start: match.start, end: match.end));
        }
      }
      ranges
        ..addAll(_pemRanges(input))
        ..addAll(_urlRanges(input, _urlCredentials!))
        ..addAll(_assignmentRanges(input, _assignments!));
      final result = _replaceRanges(input, ranges);
      // A replacement must not introduce a known secret across its boundaries.
      if (_knownSecrets.any(result.text.contains)) {
        throw const AiFailure(AiFailureKind.policyBlocked);
      }
      return result;
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

final class _RedactionRange {
  const _RedactionRange({
    required this.start,
    required this.end,
    this.unterminatedPrivateKey = false,
    this.unopenedPrivateKey = false,
  });

  final int start;
  final int end;
  final bool unterminatedPrivateKey;
  final bool unopenedPrivateKey;
}

RedactionResult _replaceRanges(String input, List<_RedactionRange> ranges) {
  if (ranges.isEmpty) return RedactionResult(input, 0);
  ranges.sort(
    (a, b) => a.start != b.start
        ? a.start.compareTo(b.start)
        : b.end.compareTo(a.end),
  );
  final merged = <_RedactionRange>[];
  for (final range in ranges) {
    if (merged.isNotEmpty && range.start < merged.last.end) {
      final previous = merged.removeLast();
      merged.add(
        _RedactionRange(
          start: previous.start,
          end: range.end > previous.end ? range.end : previous.end,
          unterminatedPrivateKey:
              previous.unterminatedPrivateKey || range.unterminatedPrivateKey,
          unopenedPrivateKey:
              previous.unopenedPrivateKey || range.unopenedPrivateKey,
        ),
      );
    } else {
      merged.add(range);
    }
  }
  final output = StringBuffer();
  var offset = 0;
  var withheld = false;
  for (final range in merged) {
    withheld |= range.unterminatedPrivateKey || range.unopenedPrivateKey;
    output
      ..write(input.substring(offset, range.start))
      ..write(
        range.unterminatedPrivateKey
            ? _unterminatedPrivateKey
            : range.unopenedPrivateKey
            ? _unopenedPrivateKey
            : _redacted,
      );
    offset = range.end;
  }
  output.write(input.substring(offset));
  return RedactionResult(
    output.toString(),
    merged.length,
    withheldPrivateKeyContext: withheld,
  );
}

Iterable<_RedactionRange> _urlRanges(String input, RegExp scheme) sync* {
  var scannedThrough = 0;
  for (final match in scheme.allMatches(input)) {
    if (match.start < scannedThrough) continue;
    var end = match.end;
    var separator = -1;
    while (end < input.length) {
      final unit = input.codeUnitAt(end);
      if (unit <= 0x20 ||
          unit == 0x2f ||
          unit == 0x3f ||
          unit == 0x23 ||
          unit == 0x22 ||
          unit == 0x27 ||
          unit == 0x3c ||
          unit == 0x3e) {
        break;
      }
      if (unit == 0x40) separator = end;
      end += 1;
    }
    scannedThrough = end;
    if (separator <= match.end) continue;
    final userinfo = input.substring(match.end, separator);
    if (userinfo == _redacted) continue;
    // This conventional SSH username carries no password. Opaque tokens and
    // every password-bearing authority still require masking.
    if (match.group(1)!.toLowerCase() == 'ssh://' && userinfo == 'git') {
      continue;
    }
    yield _RedactionRange(start: match.end, end: separator);
  }
}

final _identifier = RegExp(r'[A-Za-z0-9_.\-]+');

Iterable<_RedactionRange> _assignmentRanges(
  String input,
  List<RegExp> names,
) sync* {
  var scannedThrough = 0;
  for (final match in _identifier.allMatches(input)) {
    if (match.start < scannedThrough) continue;
    final name = match.group(0)!;
    final header = names[0].hasMatch(name);
    if (!header && !names[1].hasMatch(name)) continue;
    var cursor = match.end;
    if (cursor < input.length && _isQuote(input.codeUnitAt(cursor))) cursor++;
    cursor = _skipHorizontalSpace(input, cursor);
    if (cursor == input.length ||
        (input.codeUnitAt(cursor) != 0x3a &&
            input.codeUnitAt(cursor) != 0x3d)) {
      continue;
    }
    cursor = _skipHorizontalSpace(input, cursor + 1);
    final quoted = cursor < input.length && _isQuote(input.codeUnitAt(cursor));
    final quote = quoted ? input.codeUnitAt(cursor++) : 0;
    final valueStart = cursor;
    while (cursor < input.length) {
      final unit = input.codeUnitAt(cursor);
      if (unit == 0x0a ||
          unit == 0x0d ||
          (quoted
              ? unit == quote
              : _isQuote(unit) || (!header && unit <= 0x20))) {
        break;
      }
      cursor++;
    }
    scannedThrough = cursor;
    final value = input.substring(valueStart, cursor);
    if (value.isEmpty || value == _redacted || (!header && value.length < 8)) {
      continue;
    }
    final start = match.start > 0 && _isQuote(input.codeUnitAt(match.start - 1))
        ? match.start - 1
        : match.start;
    if (quoted && cursor < input.length && input.codeUnitAt(cursor) == quote) {
      cursor++;
    }
    yield _RedactionRange(start: start, end: cursor);
  }
}

bool _isQuote(int unit) => unit == 0x22 || unit == 0x27;

int _skipHorizontalSpace(String input, int cursor) {
  while (cursor < input.length &&
      (input.codeUnitAt(cursor) == 0x20 || input.codeUnitAt(cursor) == 0x09)) {
    cursor++;
  }
  return cursor;
}

// A candidate starts with a fixed delimiter. Its variable label run cannot
// contain '-' and therefore cannot cross another candidate. The single greedy
// repetition can backtrack only over that disjoint run: O(input.length) total,
// including long labels that never contain PRIVATE KEY. The fixed five-hyphen
// lookahead leaves a shared delimiter available to the next marker candidate;
// only those five characters may be revisited between successful matches.
final _privateKeyMarker = RegExp(
  r'-----(BEGIN|END) ([A-Z0-9 ]*PRIVATE KEY|PGP PRIVATE KEY BLOCK)(?=-----)',
);

Iterable<_RedactionRange> _pemRanges(String input) sync* {
  // Consume only an immediately following CR, LF or CRLF.
  int afterLineBreak(int end) {
    if (end < input.length && input.codeUnitAt(end) == 0x0d) {
      end++;
      if (end < input.length && input.codeUnitAt(end) == 0x0a) end++;
    } else if (end < input.length && input.codeUnitAt(end) == 0x0a) {
      end++;
    }
    return end;
  }

  // One forward pass over the markers in text order, so pairing is linear.
  // A range closes only when every BEGIN in it has met an END with the same
  // label, so nested and interleaved keys stay inside one range. An END that
  // closes no open BEGIN (its key started before this text, a foreign label,
  // interleaving) withholds everything from the start of the input through
  // it; a BEGIN that never meets its END withholds everything after it.
  final open = <String, int>{};
  var openCount = 0;
  var rangeStart = 0;
  var beginMarkerEnd = 0;
  var unopenedThrough = -1;
  for (final marker in _privateKeyMarker.allMatches(input)) {
    final label = marker.group(2)!;
    final markerEnd = marker.end + 5;
    if (marker.group(1) == 'BEGIN') {
      if (openCount == 0) rangeStart = marker.start;
      open[label] = (open[label] ?? 0) + 1;
      openCount++;
      beginMarkerEnd = markerEnd;
      continue;
    }
    final count = open[label] ?? 0;
    // An END overlapping the BEGIN marker it follows cannot close it.
    if (count > 0 && marker.start >= beginMarkerEnd) {
      open[label] = count - 1;
      if (--openCount == 0) {
        yield _RedactionRange(
          start: rangeStart,
          end: afterLineBreak(markerEnd),
        );
      }
    } else {
      unopenedThrough = afterLineBreak(markerEnd);
    }
  }
  if (unopenedThrough >= 0) {
    yield _RedactionRange(
      start: 0,
      end: unopenedThrough,
      unopenedPrivateKey: true,
    );
  }
  if (openCount > 0) {
    yield _RedactionRange(
      start: rangeStart,
      end: input.length,
      unterminatedPrivateKey: true,
    );
  }
}
