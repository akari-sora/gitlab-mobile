/// The comment draft an answer can be appended to: the ordinary new-comment
/// draft of the issue or merge request the chat came from. The page that owns
/// that item supplies it, so it always describes the item as loaded now, even
/// when the chat itself was kept from an earlier visit.
final class AiDraftTarget {
  const AiDraftTarget({
    required this.existingText,
    required this.confidential,
    required this.insert,
  });

  /// The draft text the answer would follow, or '' when there is none.
  /// Throws when the draft cannot be read.
  final Future<String> Function() existingText;

  /// Whether the item is a confidential issue now.
  final bool Function() confidential;

  /// Opens the ordinary comment editor with the text appended. Never posts.
  final Future<void> Function(String text) insert;
}
