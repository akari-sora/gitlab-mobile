/// Model and parser for GitLab Code Suggestions in MR diff discussions.
final class SuggestedChange {
  const SuggestedChange({
    this.id,
    this.fromContent = '',
    this.toContent = '',
    this.appliable = true,
    this.applied = false,
  });

  final int? id;
  final String fromContent;
  final String toContent;
  final bool appliable;
  final bool applied;

  factory SuggestedChange.fromJson(Map<String, dynamic> json) {
    return SuggestedChange(
      id: json['id'] is int ? json['id'] as int : int.tryParse('${json['id']}'),
      fromContent: json['from_content'] as String? ?? '',
      toContent: json['to_content'] as String? ?? '',
      appliable: json['appliable'] as bool? ?? (json['applicable'] as bool? ?? true),
      applied: json['applied'] as bool? ?? false,
    );
  }

  SuggestedChange copyWith({
    int? id,
    String? fromContent,
    String? toContent,
    bool? appliable,
    bool? applied,
  }) {
    return SuggestedChange(
      id: id ?? this.id,
      fromContent: fromContent ?? this.fromContent,
      toContent: toContent ?? this.toContent,
      appliable: appliable ?? this.appliable,
      applied: applied ?? this.applied,
    );
  }
}

/// Parses suggestions from a GitLab note payload or markdown body.
List<SuggestedChange> parseNoteSuggestions(Map<String, dynamic> note) {
  final rawList = note['suggestions'];
  final fromApi = <SuggestedChange>[];
  if (rawList is List) {
    for (final item in rawList) {
      if (item is Map<String, dynamic>) {
        fromApi.add(SuggestedChange.fromJson(item));
      }
    }
  }

  final body = note['body'] as String? ?? '';
  final regex = RegExp(r'```suggestion(?::-?\d+\+?\d*)?\r?\n([\s\S]*?)```');
  final matches = regex.allMatches(body).toList();

  if (fromApi.isNotEmpty) {
    if (fromApi.length == matches.length) {
      return [
        for (var i = 0; i < fromApi.length; i++)
          fromApi[i].toContent.isEmpty
              ? fromApi[i].copyWith(toContent: matches[i].group(1) ?? '')
              : fromApi[i]
      ];
    }
    return fromApi;
  }

  if (matches.isNotEmpty) {
    return [
      for (final m in matches)
        SuggestedChange(
          toContent: m.group(1) ?? '',
          appliable: false,
          applied: false,
        )
    ];
  }

  return const [];
}
