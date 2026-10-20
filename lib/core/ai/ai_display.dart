import 'ai_events.dart';
import 'ai_transcript.dart';

final class AiContextChip {
  const AiContextChip({
    required this.source,
    required this.preview,
    required this.sizeChars,
    this.blocked = false,
    this.type,
    this.resource,
    this.pinnedSha,
  });

  final String source;
  final String preview;
  final int sizeChars;
  final bool blocked;
  final String? type;
  final String? resource;
  final String? pinnedSha;
}

enum AiAssistantState {
  streaming,
  done,
  interrupted,
  refused,
  truncated,
  hidden,
}

enum AiToolRunStatus { pending, running, completed, failed, skipped }

enum AiNoticeKind {
  redacted,
  settingsChanged,
  segmentSummary,
  historyLimit,
  stopped,
  notSent,
}

sealed class AiChatItem {
  const AiChatItem();
}

final class AiUserItem extends AiChatItem {
  AiUserItem({required this.text, List<AiContextChip> chips = const []})
    : chips = List.unmodifiable(chips);

  final String text;
  final List<AiContextChip> chips;
}

final class AiAssistantItem extends AiChatItem {
  const AiAssistantItem({required this.text, required this.state, this.usage});

  final String text;
  final AiAssistantState state;
  final AiUsage? usage;
}

final class AiToolRunItem extends AiChatItem {
  const AiToolRunItem({
    required this.name,
    required this.argsPreview,
    required this.status,
    required this.sizeChars,
    required this.provenance,
    this.truncated = false,
    this.blocked = false,
    this.resultExcerpt = '',
  });

  final String name;
  final String argsPreview;
  final AiToolRunStatus status;
  final int sizeChars;
  final bool truncated;
  final bool blocked;
  final String provenance;
  final String resultExcerpt;
}

final class AiNoticeItem extends AiChatItem {
  const AiNoticeItem(this.kind, {this.count});

  final AiNoticeKind kind;
  final int? count;
}

final class AiConversation {
  AiConversation({
    required List<AiChatItem> items,
    List<AiSegment> segments = const [],
  }) : items = List.unmodifiable(items),
       segments = List.unmodifiable(segments);

  final List<AiChatItem> items;
  final List<AiSegment> segments;
}
