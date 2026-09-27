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
      fromContent: json['from_content']?.toString() ?? '',
      toContent: json['to_content']?.toString() ?? '',
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
      if (item is Map) {
        fromApi.add(SuggestedChange.fromJson(Map<String, dynamic>.from(item)));
      }
    }
  }

  final body = note['body'] as String? ?? '';
  final regex = RegExp(r'```suggestion(?::-?\d+\+?\d*)?[ \t]*\r?\n([\s\S]*?)```');
  final matches = regex.allMatches(body).toList();

  if (fromApi.isNotEmpty) {
    final combined = <SuggestedChange>[];
    for (var i = 0; i < fromApi.length; i++) {
      var item = fromApi[i];
      if (item.toContent.isEmpty && i < matches.length) {
        item = item.copyWith(toContent: matches[i].group(1) ?? '');
      }
      combined.add(item);
    }
    for (var i = fromApi.length; i < matches.length; i++) {
      combined.add(SuggestedChange(
        toContent: matches[i].group(1) ?? '',
        appliable: false,
        applied: false,
      ));
    }
    return combined;
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
