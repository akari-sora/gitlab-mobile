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
    this.sentText,
    this.block,
  });

  final String source;

  /// A short excerpt; this is what saved history keeps.
  final String preview;
  final int sizeChars;
  final bool blocked;
  final String? type;
  final String? resource;
  final String? pinnedSha;

  /// Everything this block sent, redacted, for "What was sent". Kept in
  /// memory only; a restored conversation has just [preview].
  final String? sentText;

  /// The redacted block [sentText] encodes, kept in memory only. A later
  /// redaction pass works on its plain text and encodes again, because an
  /// encoded secret (`&amp;` for `&`) no longer matches the secret itself.
  final AiContextBlock? block;
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

  /// Content that looked like a private key was held back and not sent.
  privateKeyWithheld,
  settingsChanged,
  segmentSummary,
  historyLimit,
  stopped,
  notSent,

  /// The provider's settings changed, so later questions start a new
  /// conversation; the items above stay for reading but are not sent again.
  newConversation,
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
