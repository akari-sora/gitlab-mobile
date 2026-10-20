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

  RedactionResult redact(String input) {
    try {
      _refreshSecrets();
      _compilePatterns();
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
          ranges.add((start: start, end: start + secret.length));
          offset = start + 1; // Include overlapping exact matches.
        }
      }
      for (final pattern in _patterns!) {
        for (final match in pattern.allMatches(input)) {
          ranges.add((start: match.start, end: match.end));
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

typedef _RedactionRange = ({int start, int end});

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
      merged.add((
        start: previous.start,
        end: range.end > previous.end ? range.end : previous.end,
      ));
    } else {
      merged.add(range);
    }
  }
  final output = StringBuffer();
  var offset = 0;
  for (final range in merged) {
    output
      ..write(input.substring(offset, range.start))
      ..write(_redacted);
    offset = range.end;
  }
  output.write(input.substring(offset));
  return RedactionResult(output.toString(), merged.length);
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
    yield (start: match.end, end: separator);
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
    yield (start: start, end: cursor);
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

Iterable<_RedactionRange> _pemRanges(String input) sync* {
  final begin = RegExp(r'-----BEGIN ([A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?)-----');
  // Bound both indexOf's search and retained UTF-16 text to 64 KiB. Reuse the
  // window for adjacent blocks; copying a window for every BEGIN is costly.
  const windowChars = 32 * 1024;
  var windowStart = 0;
  var windowEnd = 0;
  var window = '';
  var offset = 0;
  for (final match in begin.allMatches(input)) {
    if (match.start < offset) continue;
    final endMarker = '-----END ${match.group(1)}-----';
    final limit = match.start + windowChars;
    final boundedEnd = limit < input.length ? limit : input.length;
    var end = match.end <= windowEnd
        ? window.indexOf(endMarker, match.end - windowStart)
        : -1;
    if (end < 0 && windowEnd < boundedEnd) {
      // A refill happens only when the block will advance past the old window
      // (or fail closed through the new one). Total search/copy work is linear.
      windowStart = match.start;
      windowEnd = boundedEnd;
      window = input.substring(windowStart, windowEnd);
      end = match.end <= windowEnd
          ? window.indexOf(endMarker, match.end - windowStart)
          : -1;
    }
    offset = end < 0 ? windowEnd : windowStart + end + endMarker.length;
    // A pathological overlong BEGIN is itself sensitive, even beyond the cap.
    if (offset < match.end) offset = match.end;
    if (end < 0) offset = _extendPemRange(input, offset, match.start);
    if (end >= 0 && offset < input.length) {
      // Inspect only the immediate terminator; never rescan the rest of a line.
      if (input.codeUnitAt(offset) == 0x0d) {
        offset++;
        if (offset < input.length && input.codeUnitAt(offset) == 0x0a) offset++;
      } else if (input.codeUnitAt(offset) == 0x0a) {
        offset++;
      }
    }
    yield (start: match.start, end: offset);
  }
}

final _pemBoundary = RegExp(
  r'-----(BEGIN|END) [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----',
);
final _armorHeader = RegExp(r'[A-Za-z][A-Za-z0-9-]{0,63}:');

int _extendPemRange(String input, int offset, int blockStart) {
  // Recover the current line when the search window splits armor or a marker.
  var lineStart = offset;
  final lookback = offset - 32 * 1024;
  while (lineStart > blockStart && lineStart > lookback) {
    final unit = input.codeUnitAt(lineStart - 1);
    if (unit == 0x0a || unit == 0x0d) break;
    lineStart--;
  }
  const extensionChars = 1024 * 1024;
  final limit = offset + extensionChars;
  final boundedEnd = limit < input.length ? limit : input.length;
  final tail = input.substring(lineStart, boundedEnd);
  var cursor = offset - lineStart;
  var start = 0;
  // A split inline BEGIN/END may follow other content on the current line.
  final beginAt = tail.lastIndexOf('-----BEGIN ', cursor);
  final endAt = tail.lastIndexOf('-----END ', cursor);
  final markerAt = beginAt > endAt ? beginAt : endAt;
  if (markerAt >= 0) {
    final marker = _pemBoundary.matchAsPrefix(tail, markerAt);
    if (marker != null && marker.end > cursor) start = markerAt;
  }
  while (cursor < tail.length) {
    final boundary =
        _pemBoundary.matchAsPrefix(tail, cursor) ??
        _pemBoundary.matchAsPrefix(tail, start);
    if (boundary != null && boundary.end > cursor) {
      cursor = boundary.end;
      if (boundary.group(1) == 'END') {
        if (cursor < tail.length && tail.codeUnitAt(cursor) == 0x0d) cursor++;
        if (cursor < tail.length && tail.codeUnitAt(cursor) == 0x0a) cursor++;
        return lineStart + cursor;
      }
    } else if (_armorHeader.matchAsPrefix(tail, start) != null) {
      while (cursor < tail.length &&
          tail.codeUnitAt(cursor) != 0x0a &&
          tail.codeUnitAt(cursor) != 0x0d) {
        cursor++;
      }
    } else if (tail.startsWith('-----BEGIN ', cursor) ||
        tail.startsWith('-----END ', cursor)) {
      // A malformed marker or one cut by the cap cannot expose a following key.
      return input.length;
    }
    // Includes CRC lines (=XXXX), blank lines and CRLF without rescanning lines.
    while (cursor < tail.length) {
      final unit = tail.codeUnitAt(cursor);
      if (unit == 0x0a || unit == 0x0d) {
        start = ++cursor;
        break;
      }
      final base64 =
          (unit >= 0x41 && unit <= 0x5a) ||
          (unit >= 0x61 && unit <= 0x7a) ||
          (unit >= 0x30 && unit <= 0x39) ||
          unit == 0x2b ||
          unit == 0x2f ||
          unit == 0x3d;
      if (!base64) return lineStart + cursor;
      cursor++;
    }
  }
  // Stop inspecting at the cap, but suppress the rest rather than leak a key
  // longer than the cap. Each extension advances offset; total work is linear.
  return input.length;
}
