import '../../l10n/l10n.dart';

/// Closed T1 directions. Other operations have no intent phrases.
enum AiIntentDirection {
  star,
  unstar,
  subscribe,
  unsubscribe,
  addEmoji,
  removeEmoji,
  workItemReactionAdd,
  workItemReactionRemove,
  workItemNotificationsOn,
  workItemNotificationsOff,
  markTodoDone,
  snoozeTodo,
  unsnoozeTodo,
}

/// A pasted line longer than this cannot by itself authorize a T1 intent.
/// The plan names "long pasted text" without a number; 400 is the cut used here.
const int aiIntentPasteLineLength = 400;

const Map<String, List<AiIntentDirection>> aiIntentDirectionsByOperation =
    <String, List<AiIntentDirection>>{
      'setStar': <AiIntentDirection>[
        AiIntentDirection.star,
        AiIntentDirection.unstar,
      ],
      'setSubscribed': <AiIntentDirection>[
        AiIntentDirection.subscribe,
        AiIntentDirection.unsubscribe,
      ],
      'addAwardEmoji': <AiIntentDirection>[AiIntentDirection.addEmoji],
      'removeAwardEmoji': <AiIntentDirection>[AiIntentDirection.removeEmoji],
      'setWorkItemActivityNoteReaction': <AiIntentDirection>[
        AiIntentDirection.workItemReactionAdd,
        AiIntentDirection.workItemReactionRemove,
      ],
      'setWorkItemNotifications': <AiIntentDirection>[
        AiIntentDirection.workItemNotificationsOn,
        AiIntentDirection.workItemNotificationsOff,
      ],
      'markTodoDone': <AiIntentDirection>[AiIntentDirection.markTodoDone],
      'snoozeTodo': <AiIntentDirection>[AiIntentDirection.snoozeTodo],
      'unsnoozeTodo': <AiIntentDirection>[AiIntentDirection.unsnoozeTodo],
    };

List<AiIntentDirection> directionsFor(String operationId) =>
    aiIntentDirectionsByOperation[operationId] ?? const <AiIntentDirection>[];

AiIntentDirection? oppositeIntent(AiIntentDirection direction) {
  switch (direction) {
    case AiIntentDirection.star:
      return AiIntentDirection.unstar;
    case AiIntentDirection.unstar:
      return AiIntentDirection.star;
    case AiIntentDirection.subscribe:
      return AiIntentDirection.unsubscribe;
    case AiIntentDirection.unsubscribe:
      return AiIntentDirection.subscribe;
    case AiIntentDirection.addEmoji:
      return AiIntentDirection.removeEmoji;
    case AiIntentDirection.removeEmoji:
      return AiIntentDirection.addEmoji;
    case AiIntentDirection.workItemReactionAdd:
      return AiIntentDirection.workItemReactionRemove;
    case AiIntentDirection.workItemReactionRemove:
      return AiIntentDirection.workItemReactionAdd;
    case AiIntentDirection.workItemNotificationsOn:
      return AiIntentDirection.workItemNotificationsOff;
    case AiIntentDirection.workItemNotificationsOff:
      return AiIntentDirection.workItemNotificationsOn;
    case AiIntentDirection.markTodoDone:
      return null;
    case AiIntentDirection.snoozeTodo:
      return AiIntentDirection.unsnoozeTodo;
    case AiIntentDirection.unsnoozeTodo:
      return AiIntentDirection.snoozeTodo;
  }
}

AiIntentDirection? requestedIntentDirection(
  String operationId,
  Map<String, Object?> arguments,
  AiIntentDirection? explicit,
) {
  if (explicit != null) return explicit;
  switch (operationId) {
    case 'setStar':
      final Object? starred = arguments['starred'];
      if (starred is bool) {
        return starred ? AiIntentDirection.star : AiIntentDirection.unstar;
      }
      return null;
    case 'setSubscribed':
      final Object? subscribed = arguments['subscribed'];
      if (subscribed is bool) {
        return subscribed
            ? AiIntentDirection.subscribe
            : AiIntentDirection.unsubscribe;
      }
      return null;
    case 'addAwardEmoji':
      return AiIntentDirection.addEmoji;
    case 'removeAwardEmoji':
      return AiIntentDirection.removeEmoji;
    case 'setWorkItemActivityNoteReaction':
      final Object? add = arguments['add'];
      if (add is bool) {
        return add
            ? AiIntentDirection.workItemReactionAdd
            : AiIntentDirection.workItemReactionRemove;
      }
      return null;
    case 'setWorkItemNotifications':
      final Object? enabled = arguments['enabled'];
      if (enabled is bool) {
        return enabled
            ? AiIntentDirection.workItemNotificationsOn
            : AiIntentDirection.workItemNotificationsOff;
      }
      return null;
    case 'markTodoDone':
      return AiIntentDirection.markTodoDone;
    case 'snoozeTodo':
      return AiIntentDirection.snoozeTodo;
    case 'unsnoozeTodo':
      return AiIntentDirection.unsnoozeTodo;
    default:
      return null;
  }
}

final class AiIntentLexicon {
  const AiIntentLexicon._();

  static List<String> phrases(
    AppLanguage language,
    AiIntentDirection direction,
  ) {
    return _split(_phrase(AppStrings(language), direction));
  }

  static List<String> negations(AppLanguage language) =>
      _split(AppStrings(language).aiIntentNegation);

  static List<String> conditions(AppLanguage language) =>
      _split(AppStrings(language).aiIntentCondition);
}

final class AiIntentAssessment {
  const AiIntentAssessment({
    required this.authorizes,
    required this.negated,
    required this.conditional,
    this.direction,
  });

  final bool authorizes;
  final bool negated;
  final bool conditional;
  final AiIntentDirection? direction;
}

AiIntentAssessment assessIntent({
  required String message,
  required bool restoredFromHistory,
  required String operationId,
  required String interfaceLanguage,
  required List<String> deviceLanguages,
  Map<String, Object?> arguments = const <String, Object?>{},
  AiIntentDirection? requestedDirection,
}) {
  final List<AiIntentDirection> directions = directionsFor(operationId);
  if (directions.isEmpty) {
    return const AiIntentAssessment(
      authorizes: true,
      negated: false,
      conditional: false,
    );
  }
  if (restoredFromHistory) {
    return const AiIntentAssessment(
      authorizes: false,
      negated: false,
      conditional: false,
    );
  }
  final List<AppLanguage> languages = applicableLanguages(
    interfaceLanguage,
    deviceLanguages,
  );
  final String guards = aiProseForIntentGuards(message);
  final bool negated = _anyPhrase(guards, languages, _negationsOf);
  final bool conditional = _anyPhrase(guards, languages, _conditionsOf);
  final AiIntentDirection? requested = requestedIntentDirection(
    operationId,
    arguments,
    requestedDirection,
  );
  if (negated ||
      conditional ||
      requested == null ||
      !directions.contains(requested)) {
    return AiIntentAssessment(
      authorizes: false,
      negated: negated,
      conditional: conditional,
    );
  }
  final Set<AiIntentDirection> scan = <AiIntentDirection>{
    requested,
    ?oppositeIntent(requested),
  };
  final Set<AiIntentDirection> matched = _matchDirections(
    aiProseForIntentWords(message),
    languages,
    scan,
  );
  final AiIntentDirection? opposite = oppositeIntent(requested);
  final bool unique =
      matched.contains(requested) &&
      (opposite == null || !matched.contains(opposite));
  return AiIntentAssessment(
    authorizes: unique,
    negated: false,
    conditional: false,
    direction: unique ? requested : null,
  );
}

List<AppLanguage> applicableLanguages(
  String interfaceLanguage,
  List<String> deviceLanguages,
) {
  final List<AppLanguage> languages = <AppLanguage>[];
  final Set<String> seen = <String>{};
  void add(String tag) {
    final AppLanguage? language = languageForTag(tag) ?? _matchDeviceTag(tag);
    if (language == null || !seen.add(language.tag)) return;
    languages.add(language);
  }

  add(interfaceLanguage);
  for (final String tag in deviceLanguages) {
    add(tag);
  }
  return languages;
}

/// Fenced code removed. Negation and condition words are scanned here, so a
/// quoted "don't" still blocks automatic T1.
String aiProseForIntentGuards(String message) =>
    _stripFences(_normalize(message));

/// Quotes, inline code and long pasted lines removed, then intent phrases.
String aiProseForIntentWords(String message) {
  final String quoted = _dropLines(
    aiProseForIntentGuards(message),
    (String line) =>
        RegExp(r'^\s*>').hasMatch(line) ||
        line.length > aiIntentPasteLineLength,
  );
  return quoted.replaceAll(RegExp(r'`[^`\n]*`'), ' ');
}

/// Fenced code and quotes removed. Backticks stay: they are branch and path syntax.
String aiProseForTargetBinding(String message) {
  return _dropLines(
    aiProseForIntentGuards(message),
    (String line) => RegExp(r'^\s*>').hasMatch(line),
  );
}

String _phrase(AppStrings strings, AiIntentDirection direction) {
  switch (direction) {
    case AiIntentDirection.star:
      return strings.aiIntentStar;
    case AiIntentDirection.unstar:
      return strings.aiIntentUnstar;
    case AiIntentDirection.subscribe:
      return strings.aiIntentSubscribe;
    case AiIntentDirection.unsubscribe:
      return strings.aiIntentUnsubscribe;
    case AiIntentDirection.addEmoji:
      return strings.aiIntentAddEmoji;
    case AiIntentDirection.removeEmoji:
      return strings.aiIntentRemoveEmoji;
    case AiIntentDirection.workItemReactionAdd:
      return strings.aiIntentWorkItemReactionAdd;
    case AiIntentDirection.workItemReactionRemove:
      return strings.aiIntentWorkItemReactionRemove;
    case AiIntentDirection.workItemNotificationsOn:
      return strings.aiIntentWorkItemNotificationsOn;
    case AiIntentDirection.workItemNotificationsOff:
      return strings.aiIntentWorkItemNotificationsOff;
    case AiIntentDirection.markTodoDone:
      return strings.aiIntentMarkTodoDone;
    case AiIntentDirection.snoozeTodo:
      return strings.aiIntentSnoozeTodo;
    case AiIntentDirection.unsnoozeTodo:
      return strings.aiIntentUnsnoozeTodo;
  }
}

List<String> _split(String raw) {
  return <String>[
    for (final String part in raw.split('|'))
      if (part.trim().isNotEmpty) part.trim(),
  ];
}

List<String> _negationsOf(AppLanguage language) =>
    AiIntentLexicon.negations(language);

List<String> _conditionsOf(AppLanguage language) =>
    AiIntentLexicon.conditions(language);

bool _anyPhrase(
  String text,
  List<AppLanguage> languages,
  List<String> Function(AppLanguage language) phrases,
) {
  final String folded = text.toLowerCase();
  for (final AppLanguage language in languages) {
    for (final String phrase in phrases(language)) {
      if (_phraseHits(folded, phrase.toLowerCase())) return true;
    }
  }
  return false;
}

Set<AiIntentDirection> _matchDirections(
  String text,
  List<AppLanguage> languages,
  Set<AiIntentDirection> directions,
) {
  final String folded = text.toLowerCase();
  final List<_Hit> hits = <_Hit>[];
  for (final AppLanguage language in languages) {
    for (final AiIntentDirection direction in directions) {
      for (final String phrase in AiIntentLexicon.phrases(
        language,
        direction,
      )) {
        hits.addAll(_hits(folded, phrase.toLowerCase(), direction));
      }
    }
  }
  hits.sort((_Hit a, _Hit b) {
    final int byLength = (b.end - b.start).compareTo(a.end - a.start);
    if (byLength != 0) return byLength;
    return a.start.compareTo(b.start);
  });
  final List<_Hit> kept = <_Hit>[];
  for (final _Hit hit in hits) {
    final bool overlaps = kept.any(
      (_Hit other) => hit.start < other.end && other.start < hit.end,
    );
    if (!overlaps) kept.add(hit);
  }
  return <AiIntentDirection>{for (final _Hit hit in kept) hit.direction};
}

final class _Hit {
  const _Hit(this.start, this.end, this.direction);
  final int start;
  final int end;
  final AiIntentDirection direction;
}

List<_Hit> _hits(String text, String phrase, AiIntentDirection direction) {
  if (phrase.isEmpty) return const <_Hit>[];
  final List<_Hit> found = <_Hit>[];
  if (_asciiPhrase(phrase)) {
    final RegExp pattern = RegExp(
      '(?<![A-Za-z0-9_])${RegExp.escape(phrase)}(?![A-Za-z0-9_])',
      caseSensitive: false,
    );
    for (final RegExpMatch match in pattern.allMatches(text)) {
      found.add(_Hit(match.start, match.end, direction));
    }
    return found;
  }
  var start = 0;
  while (start <= text.length) {
    final int index = text.indexOf(phrase, start);
    if (index < 0) break;
    found.add(_Hit(index, index + phrase.length, direction));
    start = index + 1;
  }
  return found;
}

bool _phraseHits(String text, String phrase) {
  if (phrase.isEmpty) return false;
  if (_asciiPhrase(phrase)) {
    return RegExp(
      '(?<![A-Za-z0-9_])${RegExp.escape(phrase)}(?![A-Za-z0-9_])',
      caseSensitive: false,
    ).hasMatch(text);
  }
  return text.contains(phrase);
}

bool _asciiPhrase(String phrase) =>
    RegExp(r"^[A-Za-z0-9][A-Za-z0-9 '\-]*$").hasMatch(phrase);

String _normalize(String message) =>
    message.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

String _stripFences(String message) {
  final StringBuffer out = StringBuffer();
  var index = 0;
  while (index < message.length) {
    final int start = message.indexOf('```', index);
    if (start < 0) {
      out.write(message.substring(index));
      break;
    }
    out.write(message.substring(index, start));
    final int end = message.indexOf('```', start + 3);
    if (end < 0) break;
    out.write('\n');
    index = end + 3;
  }
  return out.toString();
}

String _dropLines(String message, bool Function(String line) drop) {
  return message
      .split('\n')
      .map((String line) => drop(line) ? '' : line)
      .join('\n');
}

AppLanguage? _matchDeviceTag(String tag) {
  final List<String> parts = tag.split(RegExp('[-_]'));
  if (parts.isEmpty || parts.first.isEmpty) return null;
  String? script;
  String? country;
  if (parts.length >= 2) {
    final String second = parts[1];
    if (second.length == 4) {
      script = second;
      if (parts.length >= 3) country = parts[2];
    } else {
      country = second;
    }
  }
  return matchLanguage(
    parts.first,
    scriptCode: script,
    countryCode: country?.toUpperCase(),
  );
}
