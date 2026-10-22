import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:markdown/markdown.dart' as md;

import '../instance.dart';
import '../upload_names.dart';
import 'ai_failure.dart';
import 'draft_mentions.dart';
import 'quick_actions.dart';
import 'redaction.dart';

/// (A) quick-action Markdown versus (B) plain content. See plan section 5.
enum AiTextClass { quickActionMarkdown, plainContent }

/// Canonical field names the outgoing layer will number.
///
/// Release notes, milestone descriptions and snippet descriptions are accepted
/// here. MR6b-2 registers the tools that write them. Work item descriptions
/// and notes are accepted for the same reason and land with MR6b-3.
abstract final class AiWritableField {
  static const issueDescription = 'issueDescription';
  static const mergeRequestDescription = 'mergeRequestDescription';
  static const note = 'note';
  static const discussion = 'discussion';
  static const workItemDescription = 'workItemDescription';
  static const workItemNote = 'workItemNote';
  static const releaseDescription = 'releaseDescription';
  static const milestoneDescription = 'milestoneDescription';
  static const snippetDescription = 'snippetDescription';

  static const restorable = <String>{
    issueDescription,
    mergeRequestDescription,
    note,
    discussion,
    workItemDescription,
    workItemNote,
    releaseDescription,
    milestoneDescription,
    snippetDescription,
  };
}

/// Local stand-in for the conflict key owned by the journal packet.
///
/// Identity is the canonical string the caller supplies. Issue descriptions
/// reached through REST and GraphQL must share one key. Merge replaces this
/// type with that packet's `AiConflictKey` when the constructor matches.
final class AiConflictKey {
  const AiConflictKey(this.canonical);

  final String canonical;

  @override
  bool operator ==(Object other) =>
      other is AiConflictKey && other.canonical == canonical;

  @override
  int get hashCode => canonical.hashCode;

  @override
  String toString() => 'AiConflictKey';
}

/// Provenance for one complete field value sent to a provider.
///
/// [completeValue] is false for excerpts, summaries, clips and
/// `restoreFromDisplay`. [resourceWeb] is the verified web URL of the source
/// resource, used only to resolve `./` and `../` upload targets.
final class AiFieldProvenance {
  const AiFieldProvenance({
    required this.resourceKey,
    required this.fieldName,
    required this.completeValue,
    this.resourceWeb,
    this.projectId,
    this.groupId,
    this.projectFullPath,
    this.groupFullPath,
  });

  final AiConflictKey resourceKey;
  final String fieldName;
  final bool completeValue;
  final Uri? resourceWeb;
  final int? projectId;
  final int? groupId;
  final String? projectFullPath;
  final String? groupFullPath;

  bool sameField(AiFieldProvenance other) =>
      resourceKey == other.resourceKey && fieldName == other.fieldName;

  /// The provenance of an issue or merge request description ([noteId]
  /// null) or of one note's body on it. The read port and the write side
  /// both build it here, so a placeholder issued for one field can only be
  /// restored into that same field. A note is keyed by its numeric ID alone,
  /// which plain and discussion note endpoints share.
  factory AiFieldProvenance.gitLab({
    required GitLabInstance instance,
    required int projectId,
    required String? projectPath,
    required String resource,
    required int iid,
    int? noteId,
  }) {
    final issue = switch (resource) {
      'issues' => true,
      'merge_requests' => false,
      _ => throw ArgumentError.value(resource, 'resource'),
    };
    final path = projectPath == null || projectPath.isEmpty
        ? null
        : projectPath;
    return AiFieldProvenance(
      resourceKey: noteId != null
          ? AiConflictKey('note:$noteId')
          : AiConflictKey(
              'project:$projectId/${issue ? 'issue' : 'merge_request'}:$iid',
            ),
      fieldName: noteId != null
          ? AiWritableField.note
          : issue
          ? AiWritableField.issueDescription
          : AiWritableField.mergeRequestDescription,
      completeValue: true,
      resourceWeb: path == null
          ? null
          : instance.projectWeb('$path/-/$resource/$iid'),
      projectId: projectId,
      projectFullPath: path,
    );
  }
}

/// Reasons that stay on the fixed confirmation list at every level, including
/// bypass. Packet 3 owns the canonical enum; until that import exists this
/// declaration is the local list the text layer returns.
enum AiFixedConfirmReason {
  massMention,
  externalMedia,
  closingOrCrossProject,
  hiddenContentRemoved,
}

/// Confirmation that the policy gate skips while bypass is on.
enum AiLevelConfirmReason { visibilityPollution, unseenExternalLink }

/// Stable reason codes. The lead maps these to localized sentences.
abstract final class AiTextBlockCode {
  static const rereadField = 'rereadField';
  static const fieldTooLong = 'fieldTooLong';
  static const pasteOnScreen = 'pasteOnScreen';
  static const tooManyUploadLinks = 'tooManyUploadLinks';
  static const quickAction = 'quickAction';
  static const externalMedia = 'externalMedia';
  static const secret = 'secret';
  static const redactionMarker = 'redactionMarker';
  static const badPlaceholderPosition = 'badPlaceholderPosition';
  static const attachmentScope = 'attachmentScope';
  static const attachmentUnknown = 'attachmentUnknown';
  static const attachmentUnusable = 'attachmentUnusable';
  static const rawUpload = 'rawUpload';
}

/// Caller-supplied visibility and scope facts. This layer does not read
/// GitLab and does not remember which projects the conversation opened.
final class AiVisibilityContext {
  const AiVisibilityContext({
    this.polluted = false,
    this.visibilityUnreadable = false,
    this.userMessageDomains = const <String>{},
    this.targetProjectPath,
    this.renderedMarkdown = false,
  });

  /// A stricter source was read, and the write target is wider.
  final bool polluted;

  /// Source or target visibility could not be read.
  final bool visibilityUnreadable;

  /// Hosts that already appeared in the user's own messages.
  final Set<String> userMessageDomains;

  /// `namespace/project` of the write target. Null means a path-qualified
  /// reference cannot be proved in scope.
  final String? targetProjectPath;

  /// (B) body GitLab renders as Markdown, such as a `.md` file.
  final bool renderedMarkdown;
}

/// Result of preparing one write payload.
///
/// [finalText] is null when [policyBlocked] is true, and the caller must not
/// dispatch. Non-empty [confirmReasons] also hold the dispatch until the
/// user confirms, including at bypass. [levelConfirmReasons] hold it at every
/// level except bypass.
final class AiTextOutcome {
  const AiTextOutcome({
    required this.finalText,
    required this.policyBlocked,
    required this.confirmReasons,
    required this.hiddenSpanCount,
    required this.blockedReasonCode,
    this.levelConfirmReasons = const <AiLevelConfirmReason>[],
    this.externalDomains = const <String>[],
  });

  final String? finalText;
  final bool policyBlocked;
  final List<AiFixedConfirmReason> confirmReasons;
  final List<AiLevelConfirmReason> levelConfirmReasons;
  final int hiddenSpanCount;
  final String blockedReasonCode;
  final List<String> externalDomains;

  factory AiTextOutcome.ready(
    String text, {
    List<AiFixedConfirmReason> confirmReasons = const <AiFixedConfirmReason>[],
    List<AiLevelConfirmReason> levelConfirmReasons =
        const <AiLevelConfirmReason>[],
    int hiddenSpanCount = 0,
    List<String> externalDomains = const <String>[],
  }) => AiTextOutcome(
    finalText: text,
    policyBlocked: false,
    confirmReasons: List<AiFixedConfirmReason>.unmodifiable(confirmReasons),
    levelConfirmReasons: List<AiLevelConfirmReason>.unmodifiable(
      levelConfirmReasons,
    ),
    hiddenSpanCount: hiddenSpanCount,
    blockedReasonCode: '',
    externalDomains: List<String>.unmodifiable(externalDomains),
  );

  factory AiTextOutcome.block(
    String code, {
    List<String> externalDomains = const <String>[],
  }) => AiTextOutcome(
    finalText: null,
    policyBlocked: true,
    confirmReasons: const <AiFixedConfirmReason>[],
    hiddenSpanCount: 0,
    blockedReasonCode: code,
    externalDomains: List<String>.unmodifiable(externalDomains),
  );
}

/// Line appended to class A bodies when attribution is on.
///
/// The lead replaces this English sentence with a localized one. This packet
/// does not edit catalogs.
const aiAttributionLine = 'Written by the AI assistant';

/// One in-memory upload-placeholder table for a conversation.
///
/// Entries are not written to chat history, the journal, or the provider.
/// The same target string in the same field keeps its number. A different
/// resource or field gets a new number. Existing numbers are never reused
/// for a different target.
final class UploadPlaceholderTable {
  UploadPlaceholderTable({required this.instance});

  static const maxEntries = 1000;

  final GitLabInstance instance;
  final List<_UploadEntry> _entries = <_UploadEntry>[];
  final Set<String> _userMessageTargets = <String>{};
  bool _exceeded = false;
  int _limitHits = 0;

  /// True after a new target was general-masked because the table is full.
  /// The read port should surface [AiTextBlockCode.tooManyUploadLinks].
  bool get exceededEntryLimit => _exceeded;

  /// How many new targets were general-masked because the table was full.
  /// A caller compares it before and after one field to tell whether that
  /// field lost a restorable link to the limit.
  int get limitHits => _limitHits;

  int get length => _entries.length;

  /// Masks upload targets in provider-bound [text].
  ///
  /// A complete restorable field receives `[[upload:u-<n>]]` for this
  /// instance's own upload link targets. Everything else, including text
  /// that already contained a placeholder, becomes an ordinary marker.
  /// [userMessage] remembers the original targets so a later write can return
  /// [AiTextBlockCode.pasteOnScreen].
  String redactOutgoing(
    String text, {
    AiFieldProvenance? field,
    Set<String> knownSecrets = const <String>{},
    bool userMessage = false,
  }) {
    final neutralized = neutralizeUploadPlaceholderLiterals(text);
    if (userMessage) {
      for (final span in uploadSecretMaskSpans(neutralized)) {
        _userMessageTargets.add(neutralized.substring(span.start, span.end));
      }
    }
    final rewritten = _rewriteTargets(
      neutralized,
      field: field,
      userMessage: userMessage,
    );
    return Redactor(
      secrets: _FixedSecrets(knownSecrets),
    ).redactSource(rewritten, keepAppPlaceholders: true).text;
  }

  /// Restores placeholders that belong to [field]. Any other id, field or
  /// position blocks the whole string.
  AiTextOutcome restoreIntoSameField(String text, AiFieldProvenance field) {
    if (!field.completeValue) {
      return AiTextOutcome.block(AiTextBlockCode.fieldTooLong);
    }
    if (!AiWritableField.restorable.contains(field.fieldName)) {
      return AiTextOutcome.block(AiTextBlockCode.rereadField);
    }
    final matches = _uploadPlaceholder.allMatches(text).toList();
    final replacements = <_SpanReplacement>[];
    for (final match in matches) {
      if (_forbiddenNeighbor(text, match.start, match.end, upload: true) ||
          !_legalUploadPosition(text, match.start, match.end)) {
        return AiTextOutcome.block(AiTextBlockCode.badPlaceholderPosition);
      }
      final id = int.parse(match.group(1)!);
      final entry = _entryForId(id);
      if (entry == null ||
          entry.resourceKey != field.resourceKey ||
          entry.fieldName != field.fieldName) {
        return AiTextOutcome.block(AiTextBlockCode.rereadField);
      }
      replacements.add(
        _SpanReplacement(match.start, match.end, entry.rawTarget),
      );
    }
    return AiTextOutcome.ready(_applyReplacements(text, replacements));
  }

  bool containsUserMessageTarget(String text) {
    for (final target in _userMessageTargets) {
      if (target.isNotEmpty && text.contains(target)) return true;
    }
    return false;
  }

  @override
  String toString() => 'UploadPlaceholderTable(${_entries.length})';

  _UploadEntry? _entryForId(int id) {
    for (final entry in _entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  String _rewriteTargets(
    String text, {
    required AiFieldProvenance? field,
    required bool userMessage,
  }) {
    final eligible =
        !userMessage &&
        field != null &&
        field.completeValue &&
        AiWritableField.restorable.contains(field.fieldName);
    final replacements = <_SpanReplacement>[];
    for (final target in _linkTargets(text)) {
      final upload =
          _containsUploadSecret(target.raw) ||
          _containsUploadSecret(target.classifyText);
      if (!upload) continue;
      if (field != null &&
          eligible &&
          _ownsUpload(target.classifyText, field)) {
        final existing = _existing(field, target.raw);
        if (existing == null && _entries.length >= maxEntries) {
          _exceeded = true;
          _limitHits++;
          replacements.add(
            _SpanReplacement(target.start, target.end, _redactedMarker),
          );
          continue;
        }
        final id = existing?.id ?? _allocate(field, target.raw);
        replacements.add(
          _SpanReplacement(target.start, target.end, '[[upload:u-$id]]'),
        );
      } else {
        replacements.add(
          _SpanReplacement(target.start, target.end, _redactedMarker),
        );
      }
    }
    return _applyReplacements(text, replacements);
  }

  _UploadEntry? _existing(AiFieldProvenance field, String raw) {
    for (final entry in _entries) {
      if (entry.resourceKey == field.resourceKey &&
          entry.fieldName == field.fieldName &&
          entry.rawTarget == raw) {
        return entry;
      }
    }
    return null;
  }

  int _allocate(AiFieldProvenance field, String raw) {
    final id = _entries.length + 1;
    _entries.add(
      _UploadEntry(
        id: id,
        resourceKey: field.resourceKey,
        fieldName: field.fieldName,
        rawTarget: raw,
      ),
    );
    return id;
  }

  bool _ownsUpload(String destination, AiFieldProvenance field) {
    if (destination.isEmpty || _hasControl(destination)) return false;
    if (_isStandardUpload(destination)) return true;
    if (destination.startsWith('//')) {
      final uri = Uri.tryParse('https:$destination');
      if (uri == null) return false;
      return _absoluteOwn(uri, field);
    }
    if (destination.startsWith('/')) return false;
    final parsed = Uri.tryParse(destination);
    if (parsed != null && parsed.hasScheme) return _absoluteOwn(parsed, field);
    final web = field.resourceWeb;
    if (web == null) return false;
    return _absoluteOwn(web.resolve(destination), field);
  }

  bool _absoluteOwn(Uri uri, AiFieldProvenance field) {
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !instance.sameOrigin(uri)) {
      return false;
    }
    final segments = _segments(uri);
    if (segments.any((segment) => segment == '.' || segment == '..')) {
      return false;
    }
    if (segments.length < 3 || segments[segments.length - 3] != 'uploads') {
      return false;
    }
    final secret = segments[segments.length - 2];
    final filename = segments.last;
    if (!projectUploadNamesOk(secret, filename)) return false;
    final head = segments.sublist(0, segments.length - 3);
    final base = _segments(instance.base);
    if (head.length < base.length) return false;
    for (var i = 0; i < base.length; i++) {
      if (head[i] != base[i]) return false;
    }
    final rest = head.sublist(base.length);
    if (_sameSegments(rest, _pathSegments(field.projectFullPath))) return true;
    if (field.projectId != null &&
        _sameSegments(rest, <String>['-', 'project', '${field.projectId}'])) {
      return true;
    }
    if (_sameSegments(rest, _pathSegments(field.groupFullPath))) return true;
    if (field.groupId != null &&
        _sameSegments(rest, <String>['-', 'group', '${field.groupId}'])) {
      return true;
    }
    return false;
  }
}

final class _UploadEntry {
  const _UploadEntry({
    required this.id,
    required this.resourceKey,
    required this.fieldName,
    required this.rawTarget,
  });

  final int id;
  final AiConflictKey resourceKey;
  final String fieldName;
  final String rawTarget;
}

/// Replaces `[[attachment:att-<n>]]` with the rebuilt image markdown.
///
/// [markdownById] maps `att-1` to the server `markdown` string. Null means the
/// upload was accepted but the response cannot be quoted.
final class AttachmentSubstitution {
  AttachmentSubstitution(Map<String, String?> markdownById)
    : _markdownById = Map<String, String?>.unmodifiable(markdownById);

  final Map<String, String?> _markdownById;

  AiTextOutcome substitute(String text, {required bool sameProjectClassA}) {
    final matches = _attachmentPlaceholder.allMatches(text).toList();
    if (matches.isEmpty) return AiTextOutcome.ready(text);
    if (!sameProjectClassA) {
      return AiTextOutcome.block(AiTextBlockCode.attachmentScope);
    }
    final replacements = <_SpanReplacement>[];
    for (final match in matches) {
      if (_forbiddenNeighbor(text, match.start, match.end, upload: false) ||
          !_standalone(text, match.start, match.end)) {
        return AiTextOutcome.block(AiTextBlockCode.badPlaceholderPosition);
      }
      final id = 'att-${match.group(1)!}';
      if (!_markdownById.containsKey(id)) {
        return AiTextOutcome.block(AiTextBlockCode.attachmentUnknown);
      }
      final rebuilt = _rebuildAttachmentMarkdown(_markdownById[id]);
      if (rebuilt == null) {
        return AiTextOutcome.block(AiTextBlockCode.attachmentUnusable);
      }
      replacements.add(_SpanReplacement(match.start, match.end, rebuilt));
    }
    return AiTextOutcome.ready(_applyReplacements(text, replacements));
  }
}

/// Prepares model text for a GitLab write.
///
/// [secretFragments] is the MR6b-2 seam: when it is non-null, secret and
/// marker checks scan those `new` strings instead of the whole payload.
/// MR6b-1 callers leave it null and scan the whole field.
AiTextOutcome prepareWriteText({
  required AiTextClass textClass,
  required String modelText,
  required AiFieldProvenance? field,
  required UploadPlaceholderTable placeholders,
  required Set<String> knownSecrets,
  required bool aiAttribution,
  required AiVisibilityContext visibility,
  AttachmentSubstitution? attachments,
  bool sameProjectClassA = true,
  String? currentFieldValue,
  List<String>? secretFragments,
}) {
  if (field != null && !field.completeValue) {
    return AiTextOutcome.block(AiTextBlockCode.fieldTooLong);
  }
  var text = modelText;
  final classA = textClass == AiTextClass.quickActionMarkdown;
  if (classA) {
    try {
      text = neutralizeForGitLabDraft(text);
    } on StateError {
      return AiTextOutcome.block(AiTextBlockCode.quickAction);
    }
    text = analyzeDraftMentions(text).text;
  }
  if (_attachmentPlaceholder.hasMatch(text)) {
    if (!classA || !sameProjectClassA) {
      return AiTextOutcome.block(AiTextBlockCode.attachmentScope);
    }
    if (attachments == null) {
      return AiTextOutcome.block(AiTextBlockCode.attachmentUnknown);
    }
    final substituted = attachments.substitute(text, sameProjectClassA: true);
    if (substituted.policyBlocked || substituted.finalText == null) {
      return substituted;
    }
    text = substituted.finalText!;
  }
  final restoredTargets = <String>[];
  if (_uploadPlaceholder.hasMatch(text)) {
    if (field == null) {
      return AiTextOutcome.block(
        placeholders.containsUserMessageTarget(text)
            ? AiTextBlockCode.pasteOnScreen
            : AiTextBlockCode.rereadField,
      );
    }
    final restored = placeholders.restoreIntoSameField(text, field);
    if (restored.policyBlocked || restored.finalText == null) {
      return restored;
    }
    for (final match in _uploadPlaceholder.allMatches(text)) {
      final id = int.parse(match.group(1)!);
      for (final entry in placeholders._entries) {
        if (entry.id == id) restoredTargets.add(entry.rawTarget);
      }
    }
    text = restored.finalText!;
  }
  if (classA && aiAttribution) text = _appendAttribution(text);
  if (classA && quickActionLineCount(text) > 0) {
    return AiTextOutcome.block(AiTextBlockCode.quickAction);
  }
  if (text.contains('[[upload:') || text.contains('[[attachment:')) {
    return AiTextOutcome.block(AiTextBlockCode.rereadField);
  }
  final exempt = <String>[...restoredTargets, ..._rebuiltUploads(text)];
  if (placeholders.containsUserMessageTarget(text) &&
      !_coveredByExempt(text, placeholders, exempt)) {
    return AiTextOutcome.block(AiTextBlockCode.pasteOnScreen);
  }
  if (_rawUploadOutsideExempt(text, exempt)) {
    return AiTextOutcome.block(AiTextBlockCode.rawUpload);
  }
  final domains = _externalDomains(text, placeholders.instance);
  final media = _externalEmbeds(text, placeholders.instance);
  if (media.isNotEmpty && classA) {
    return AiTextOutcome.block(
      AiTextBlockCode.externalMedia,
      externalDomains: media,
    );
  }
  final scanTargets = secretFragments ?? <String>[text];
  for (final piece in scanTargets) {
    if (_hasMarker(piece)) {
      return AiTextOutcome.block(AiTextBlockCode.redactionMarker);
    }
    if (_secretHit(piece, knownSecrets, exempt)) {
      return AiTextOutcome.block(AiTextBlockCode.secret);
    }
  }
  final fixed = <AiFixedConfirmReason>[];
  final level = <AiLevelConfirmReason>[];
  if (_massMention(
    text,
    classA: classA,
    field: field,
    visibility: visibility,
  )) {
    fixed.add(AiFixedConfirmReason.massMention);
  }
  final renderedB =
      !classA &&
      (visibility.renderedMarkdown ||
          field?.fieldName == AiWritableField.releaseDescription ||
          field?.fieldName == AiWritableField.snippetDescription);
  if (media.isNotEmpty && renderedB) {
    fixed.add(AiFixedConfirmReason.externalMedia);
  }
  if (_hasCrossProject(text, placeholders.instance, visibility)) {
    fixed.add(AiFixedConfirmReason.closingOrCrossProject);
  }
  if (visibility.polluted || visibility.visibilityUnreadable) {
    level.add(AiLevelConfirmReason.visibilityPollution);
  }
  final unseen = _unseenDomains(domains, visibility.userMessageDomains);
  if (unseen.isNotEmpty) level.add(AiLevelConfirmReason.unseenExternalLink);
  final hidden = currentFieldValue == null
      ? 0
      : _hiddenSpanCount(currentFieldValue, text, knownSecrets);
  if (hidden > 0) fixed.add(AiFixedConfirmReason.hiddenContentRemoved);
  return AiTextOutcome.ready(
    text,
    confirmReasons: fixed,
    levelConfirmReasons: level,
    hiddenSpanCount: hidden,
    externalDomains: <String>{...domains, ...media}.toList(),
  );
}

String _appendAttribution(String text) {
  if (text.isEmpty) return aiAttributionLine;
  if (text.endsWith('\n')) return '$text$aiAttributionLine';
  return '$text\n$aiAttributionLine';
}

bool _coveredByExempt(
  String text,
  UploadPlaceholderTable placeholders,
  List<String> exempt,
) {
  for (final target in placeholders._userMessageTargets) {
    if (target.isEmpty || !text.contains(target)) continue;
    if (!exempt.any((path) => path.contains(target) || target.contains(path))) {
      return false;
    }
  }
  return true;
}

bool _rawUploadOutsideExempt(String text, List<String> exempt) {
  final probe = _maskExempt(text, exempt);
  return _containsUploadSecret(probe);
}

bool _secretHit(String text, Set<String> secrets, List<String> exempt) {
  final probe = _maskExempt(text, exempt);
  try {
    final result = Redactor(
      secrets: _FixedSecrets(secrets),
    ).redactSource(probe, keepAppPlaceholders: true);
    return result.redactions > 0 || result.text != probe;
  } on AiFailure {
    return true;
  }
}

String _maskExempt(String text, List<String> exempt) {
  final paths = <String>[...exempt.where((path) => path.isNotEmpty)]
    ..sort((a, b) => b.length.compareTo(a.length));
  var probe = text;
  for (final path in paths) {
    probe = probe.replaceAll(path, 'x' * path.length);
  }
  return probe;
}

bool _hasMarker(String text) =>
    text.contains('[REDACTED') ||
    text.contains('<gitlab_data') ||
    text.contains('</gitlab_data>');

bool _massMention(
  String text, {
  required bool classA,
  required AiFieldProvenance? field,
  required AiVisibilityContext visibility,
}) {
  final renderedB =
      !classA &&
      (visibility.renderedMarkdown ||
          field?.fieldName == AiWritableField.releaseDescription ||
          field?.fieldName == AiWritableField.snippetDescription);
  if (!classA && !renderedB) return false;
  if (_broadcastMention.hasMatch(text)) return true;
  final users = <String>{};
  var mass = false;
  for (final match in _mentionPattern.allMatches(text)) {
    final name = match.group(1)!.replaceFirst(_trailingMentionPunctuation, '');
    if (name.isEmpty) continue;
    if (name.toLowerCase() == 'all' || name.toLowerCase() == 'here') {
      mass = true;
    } else if (name.contains('/')) {
      mass = true;
    } else {
      users.add(name);
    }
  }
  return mass || users.length > 5;
}

bool _hasCrossProject(
  String text,
  GitLabInstance instance,
  AiVisibilityContext visibility,
) {
  final target = visibility.targetProjectPath;
  for (final match in _qualifiedRef.allMatches(text)) {
    final path = match.group(1)!;
    if (target == null || path != target) return true;
  }
  for (final match in _bareUrl.allMatches(text)) {
    final raw = _trimTrailingUrlPunctuation(match.group(0)!);
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasScheme || !_looksLikeIssueUrl(uri)) continue;
    final project = _projectPathOfIssueUrl(uri, instance);
    if (project == null || target == null || project != target) return true;
  }
  return false;
}

String? _projectPathOfIssueUrl(Uri uri, GitLabInstance instance) {
  if (uri.scheme != 'https' || !instance.sameOrigin(uri)) return null;
  final segments = _segments(uri);
  final base = _segments(instance.base);
  if (segments.length < base.length + 2) return null;
  for (var i = 0; i < base.length; i++) {
    if (segments[i] != base[i]) return null;
  }
  final rest = segments.sublist(base.length);
  for (var i = 0; i < rest.length - 1; i++) {
    final kind = rest[i];
    if (kind != 'issues' && kind != 'merge_requests' && kind != 'work_items') {
      continue;
    }
    if (!RegExp(r'^[0-9]+$').hasMatch(rest[i + 1])) continue;
    final project = rest.sublist(0, i);
    if (project.isNotEmpty && project.last == '-') project.removeLast();
    if (project.isEmpty) return null;
    return project.join('/');
  }
  return null;
}

bool _looksLikeIssueUrl(Uri uri) {
  final segments = _segments(uri);
  for (var i = 0; i < segments.length - 1; i++) {
    final kind = segments[i];
    if ((kind == 'issues' ||
            kind == 'merge_requests' ||
            kind == 'work_items') &&
        RegExp(r'^[0-9]+$').hasMatch(segments[i + 1])) {
      return true;
    }
  }
  return false;
}

List<String> _externalDomains(String text, GitLabInstance instance) {
  final hosts = <String>[];
  for (final target in _linkTargets(text)) {
    final host = _externalHost(target.classifyText, instance);
    if (host != null && !hosts.contains(host)) hosts.add(host);
  }
  return hosts;
}

List<String> _externalEmbeds(String text, GitLabInstance instance) {
  final hosts = <String>[];
  for (final target in _linkTargets(text)) {
    if (!target.embed) continue;
    final host = _externalHost(target.classifyText, instance);
    if (host != null && !hosts.contains(host)) hosts.add(host);
  }
  return hosts;
}

String? _externalHost(String destination, GitLabInstance instance) {
  if (destination.isEmpty || destination.startsWith('/')) return null;
  final uri = destination.startsWith('//')
      ? Uri.tryParse('https:$destination')
      : Uri.tryParse(destination);
  if (uri == null || !uri.hasScheme) return null;
  if (uri.scheme != 'https' && uri.scheme != 'http') return null;
  if (uri.host.isEmpty) return null;
  if (uri.scheme == 'https' && instance.sameOrigin(uri)) return null;
  return uri.host.toLowerCase();
}

List<String> _unseenDomains(List<String> domains, Set<String> seen) {
  final known = <String>{for (final host in seen) host.toLowerCase()};
  return <String>[
    for (final host in domains)
      if (!known.contains(host)) host,
  ];
}

int _hiddenSpanCount(
  String current,
  String finalText,
  Set<String> knownSecrets,
) {
  final spans = <String>[];
  final covered = <({int start, int end})>[];
  for (final target in _linkTargets(current)) {
    if (!_containsUploadSecret(target.raw) &&
        !_containsUploadSecret(target.classifyText)) {
      continue;
    }
    spans.add(target.raw);
    covered.add((start: target.start, end: target.end));
  }
  for (final span in uploadSecretMaskSpans(current)) {
    if (_overlaps(covered, span.start, span.end)) continue;
    spans.add(current.substring(span.start, span.end));
    covered.add(span);
  }
  for (final match in _redactionMarkerPattern.allMatches(current)) {
    spans.add(match.group(0)!);
  }
  for (final secret in knownSecrets) {
    if (secret.isEmpty) continue;
    var offset = 0;
    while (offset < current.length) {
      final index = current.indexOf(secret, offset);
      if (index < 0) break;
      if (!_overlaps(covered, index, index + secret.length)) {
        spans.add(secret);
      }
      offset = index + secret.length;
    }
  }
  return _countMissing(spans, finalText);
}

int _countMissing(List<String> spans, String finalText) {
  var remaining = finalText;
  var missing = 0;
  for (final span in spans) {
    if (span.isEmpty) continue;
    final index = remaining.indexOf(span);
    if (index < 0) {
      missing++;
    } else {
      remaining = remaining.replaceRange(index, index + span.length, '');
    }
  }
  return missing;
}

bool _overlaps(List<({int start, int end})> covered, int start, int end) {
  for (final span in covered) {
    if (start < span.end && end > span.start) return true;
  }
  return false;
}

List<String> _rebuiltUploads(String text) {
  final found = <String>[];
  for (final match in _rebuiltUpload.allMatches(text)) {
    found.add(match.group(0)!);
  }
  return found;
}

String? _rebuildAttachmentMarkdown(String? markdown) {
  if (markdown == null || _hasControl(markdown)) return null;
  final match = _attachmentMarkdown.firstMatch(markdown);
  if (match == null) return null;
  final name = match.group(1)!;
  final secret = match.group(2)!;
  final filename = match.group(3)!;
  if (!_attachmentLabelOk(name) || !_attachmentLabelOk(filename)) return null;
  if (!projectUploadNamesOk(secret, filename)) return null;
  if (filename.contains('?') || filename.contains('#')) return null;
  return '![$name](/uploads/$secret/$filename)';
}

bool _attachmentLabelOk(String value) {
  if (value.contains('[') ||
      value.contains(']') ||
      value.contains('(') ||
      value.contains(')')) {
    return false;
  }
  return !_hasControl(value);
}

bool _hasControl(String value) {
  for (final unit in value.codeUnits) {
    if (unit < 0x20 || unit == 0x7f) return true;
  }
  return false;
}

bool _isStandardUpload(String destination) {
  if (destination.contains('://') ||
      destination.startsWith('//') ||
      destination.contains('?') ||
      destination.contains('#') ||
      destination.contains(' ') ||
      _hasControl(destination)) {
    return false;
  }
  final uri = Uri.tryParse(destination);
  if (uri == null ||
      uri.hasScheme ||
      uri.host.isNotEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return false;
  }
  final segments = _segments(uri);
  if (segments.length != 3 || segments[0] != 'uploads') return false;
  if (!projectUploadNamesOk(segments[1], segments[2])) return false;
  return destination == '/uploads/${segments[1]}/${segments[2]}';
}

bool _containsUploadSecret(String text) => _uploadSecretProbe.hasMatch(text);

bool _forbiddenNeighbor(
  String text,
  int start,
  int end, {
  required bool upload,
}) {
  if (start > 0 && _forbiddenUnit(text.codeUnitAt(start - 1), upload: upload)) {
    return true;
  }
  if (end < text.length &&
      _forbiddenUnit(text.codeUnitAt(end), upload: upload)) {
    return true;
  }
  return false;
}

bool _forbiddenUnit(int unit, {required bool upload}) {
  if (unit == 0x2f ||
      unit == 0x3f ||
      unit == 0x3d ||
      unit == 0x23 ||
      unit == 0x3a ||
      unit == 0x25) {
    return true;
  }
  if (!upload && (unit == 0x28 || unit == 0x29)) return true;
  return (unit >= 0x30 && unit <= 0x39) ||
      (unit >= 0x41 && unit <= 0x5a) ||
      (unit >= 0x61 && unit <= 0x7a);
}

bool _legalUploadPosition(String text, int start, int end) =>
    _markdownDestinationPosition(text, start, end) ||
    _htmlAttributePosition(text, start, end) ||
    _autolinkPosition(text, start, end) ||
    _standalone(text, start, end);

bool _markdownDestinationPosition(String text, int start, int end) {
  if (start < 2 ||
      text.codeUnitAt(start - 1) != 0x28 ||
      text.codeUnitAt(start - 2) != 0x5d) {
    return false;
  }
  var index = _skipWhitespace(text, end);
  if (index < text.length && _isQuote(text.codeUnitAt(index))) {
    final quote = text.codeUnitAt(index);
    index++;
    while (index < text.length && text.codeUnitAt(index) != quote) {
      if (text.codeUnitAt(index) == 0x5c && index + 1 < text.length) {
        index += 2;
        continue;
      }
      index++;
    }
    if (index >= text.length) return false;
    index = _skipWhitespace(text, index + 1);
  }
  return index < text.length && text.codeUnitAt(index) == 0x29;
}

bool _htmlAttributePosition(String text, int start, int end) {
  if (start == 0 || end >= text.length) return false;
  final quote = text.codeUnitAt(start - 1);
  if (!_isQuote(quote) || text.codeUnitAt(end) != quote) return false;
  final open = text.lastIndexOf('<', start);
  if (open < 0 || text.substring(open, start).contains('>')) return false;
  final close = text.indexOf('>', end);
  if (close < 0) return false;
  final tag = text.substring(open, close + 1);
  final fragment = html_parser.parseFragment(tag, generateSpans: true);
  for (final node in fragment.nodes) {
    if (node is! dom.Element || !_htmlMediaOrAnchor.contains(node.localName)) {
      continue;
    }
    final values = node.attributeValueSpans;
    if (values == null) continue;
    for (final entry in values.entries) {
      final name = entry.key.toString().toLowerCase();
      if (name != 'src' && name != 'href') continue;
      final span = entry.value;
      if (span.start.offset < 0 || span.end.offset > tag.length) continue;
      if (tag.substring(span.start.offset, span.end.offset) ==
          text.substring(start, end)) {
        return true;
      }
    }
  }
  return false;
}

bool _autolinkPosition(String text, int start, int end) =>
    start > 0 &&
    end < text.length &&
    text.codeUnitAt(start - 1) == 0x3c &&
    text.codeUnitAt(end) == 0x3e;

bool _standalone(String text, int start, int end) {
  final before = start == 0 || _isTokenBreak(text.codeUnitAt(start - 1));
  final after = end == text.length || _isTokenBreak(text.codeUnitAt(end));
  return before && after;
}

bool _isTokenBreak(int unit) =>
    unit == 0x20 ||
    unit == 0x09 ||
    unit == 0x0a ||
    unit == 0x0d ||
    unit == 0x0c;

bool _isQuote(int unit) => unit == 0x22 || unit == 0x27;

int _skipWhitespace(String text, int index) {
  while (index < text.length && _isTokenBreak(text.codeUnitAt(index))) {
    index++;
  }
  return index;
}

String _applyReplacements(String text, List<_SpanReplacement> replacements) {
  final ordered = <_SpanReplacement>[...replacements]
    ..sort((a, b) => b.start.compareTo(a.start));
  var result = text;
  for (final replacement in ordered) {
    result = result.replaceRange(
      replacement.start,
      replacement.end,
      replacement.text,
    );
  }
  return result;
}

final class _SpanReplacement {
  const _SpanReplacement(this.start, this.end, this.text);
  final int start;
  final int end;
  final String text;
}

final class _FixedSecrets implements KnownSecretsSource {
  const _FixedSecrets(this.current);
  @override
  final Iterable<String> current;
}

final class _LinkTarget {
  const _LinkTarget({
    required this.start,
    required this.end,
    required this.raw,
    required this.classifyText,
    required this.embed,
  });

  final int start;
  final int end;
  final String raw;
  final String classifyText;
  final bool embed;
}

List<_LinkTarget> _linkTargets(String source) {
  final spans = <_LinkTarget>[];
  final masked = _blankFences(source);
  final document = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
    inlineSyntaxes: <md.InlineSyntax>[
      _RecordingImage(spans),
      _RecordingLink(spans),
      _RecordingAutolink(spans),
      _RecordingHtml(spans),
      _RecordingExtendedAutolink(spans),
    ],
  );
  document.parseInline(masked);
  _addReferenceDefinitions(masked, source, spans);
  return _dropOverlaps(spans);
}

String _blankFences(String text) {
  final lines = text.split('\n');
  final out = <String>[];
  String? fenceChar;
  var fenceLength = 0;
  for (final line in lines) {
    if (fenceChar == null) {
      final opening = _fenceOpening.firstMatch(line);
      if (opening != null) {
        fenceChar = opening.group(1)![0];
        fenceLength = opening.group(1)!.length;
        out.add(' ' * line.length);
        continue;
      }
      out.add(line);
    } else {
      out.add(' ' * line.length);
      final marker = RegExp.escape(fenceChar);
      if (RegExp('^[ ]{0,3}$marker{$fenceLength,}[ ]*\$').hasMatch(line)) {
        fenceChar = null;
      }
    }
  }
  return out.join('\n');
}

void _addReferenceDefinitions(
  String masked,
  String original,
  List<_LinkTarget> spans,
) {
  final lines = masked.split('\n');
  var offset = 0;
  for (final line in lines) {
    final bounds = _referenceDestination(line);
    if (bounds != null) {
      final raw = original.substring(
        offset + bounds.start,
        offset + bounds.end,
      );
      final classify =
          raw.startsWith('<') && raw.endsWith('>') && raw.length > 2
          ? raw.substring(1, raw.length - 1)
          : raw;
      spans.add(
        _LinkTarget(
          start: offset + bounds.start,
          end: offset + bounds.end,
          raw: raw,
          classifyText: classify,
          embed: false,
        ),
      );
    }
    offset += line.length + 1;
  }
}

({int start, int end})? _referenceDestination(String line) {
  final label = _referenceLabel.firstMatch(line);
  if (label == null) return null;
  var index = label.end;
  if (index >= line.length) return null;
  if (line.codeUnitAt(index) == 0x3c) {
    final start = index;
    index++;
    while (index < line.length && line.codeUnitAt(index) != 0x3e) {
      index++;
    }
    if (index >= line.length) return null;
    return (start: start, end: index + 1);
  }
  final start = index;
  while (index < line.length && line.codeUnitAt(index) > 0x20) {
    index++;
  }
  if (index == start) return null;
  return (start: start, end: index);
}

List<_LinkTarget> _dropOverlaps(List<_LinkTarget> spans) {
  spans.sort(
    (a, b) => a.start != b.start
        ? a.start.compareTo(b.start)
        : a.end.compareTo(b.end),
  );
  final kept = <_LinkTarget>[];
  var blockedUntil = -1;
  for (final span in spans) {
    if (span.start < blockedUntil) {
      if (span.end > blockedUntil) blockedUntil = span.end;
      continue;
    }
    if (kept.isNotEmpty &&
        span.start == kept.last.start &&
        span.end == kept.last.end) {
      continue;
    }
    if (kept.isNotEmpty && span.start < kept.last.end) {
      blockedUntil = span.end > kept.last.end ? span.end : kept.last.end;
      kept.removeLast();
      continue;
    }
    kept.add(span);
  }
  return kept;
}

void _recordMarkdownDestination(
  md.InlineParser parser,
  int bracketAt,
  List<_LinkTarget> spans, {
  required bool embed,
  required Iterable<md.Node>? nodes,
}) {
  if (nodes == null || bracketAt < 0 || bracketAt >= parser.source.length) {
    return;
  }
  if (parser.pos < bracketAt || parser.pos >= parser.source.length) return;
  if (parser.source.codeUnitAt(bracketAt) != 0x5d) return;
  final tail = parser.source.substring(bracketAt, parser.pos + 1);
  final bounds = _destinationInTail(tail);
  if (bounds == null) return;
  final raw = tail.substring(bounds.start, bounds.end);
  if (raw.isEmpty) return;
  final classify = raw.startsWith('<') && raw.endsWith('>') && raw.length > 2
      ? raw.substring(1, raw.length - 1)
      : raw;
  spans.add(
    _LinkTarget(
      start: bracketAt + bounds.start,
      end: bracketAt + bounds.end,
      raw: raw,
      classifyText: classify,
      embed: embed,
    ),
  );
}

({int start, int end})? _destinationInTail(String tail) {
  if (tail.length < 4 ||
      tail.codeUnitAt(0) != 0x5d ||
      tail.codeUnitAt(1) != 0x28) {
    return null;
  }
  var index = _skipWhitespace(tail, 2);
  if (index >= tail.length) return null;
  if (tail.codeUnitAt(index) == 0x3c) {
    final start = index;
    index++;
    while (index < tail.length &&
        tail.codeUnitAt(index) != 0x3e &&
        tail.codeUnitAt(index) != 0x0a &&
        tail.codeUnitAt(index) != 0x0d) {
      index++;
    }
    if (index >= tail.length || tail.codeUnitAt(index) != 0x3e) return null;
    final end = index + 1;
    if (!_closesDestination(tail, end)) return null;
    return (start: start, end: end);
  }
  final start = index;
  var depth = 1;
  while (index < tail.length) {
    final unit = tail.codeUnitAt(index);
    if (unit == 0x5c) {
      if (index + 1 >= tail.length) return null;
      index += 2;
      continue;
    }
    if (unit == 0x28) {
      depth++;
      index++;
      continue;
    }
    if (unit == 0x29) {
      depth--;
      if (depth == 0) return (start: start, end: index);
      index++;
      continue;
    }
    if (unit == 0x20 || unit == 0x0a || unit == 0x0d || unit == 0x09) {
      if (!_closesDestination(tail, index)) return null;
      return (start: start, end: index);
    }
    index++;
  }
  return null;
}

bool _closesDestination(String tail, int index) {
  var cursor = _skipWhitespace(tail, index);
  if (cursor < tail.length && _isQuote(tail.codeUnitAt(cursor))) {
    final quote = tail.codeUnitAt(cursor);
    cursor++;
    while (cursor < tail.length && tail.codeUnitAt(cursor) != quote) {
      if (tail.codeUnitAt(cursor) == 0x5c && cursor + 1 < tail.length) {
        cursor += 2;
        continue;
      }
      cursor++;
    }
    if (cursor >= tail.length) return false;
    cursor = _skipWhitespace(tail, cursor + 1);
  }
  return cursor < tail.length && tail.codeUnitAt(cursor) == 0x29;
}

final class _RecordingImage extends md.ImageSyntax {
  _RecordingImage(this.spans);

  final List<_LinkTarget> spans;

  @override
  Iterable<md.Node>? close(
    md.InlineParser parser,
    covariant md.SimpleDelimiter opener,
    md.Delimiter? closer, {
    String? tag,
    required List<md.Node> Function() getChildren,
  }) {
    final bracketAt = parser.pos;
    final nodes = super.close(
      parser,
      opener,
      closer,
      tag: tag,
      getChildren: getChildren,
    );
    _recordMarkdownDestination(
      parser,
      bracketAt,
      spans,
      embed: true,
      nodes: nodes,
    );
    return nodes;
  }
}

final class _RecordingLink extends md.LinkSyntax {
  _RecordingLink(this.spans);

  final List<_LinkTarget> spans;

  @override
  Iterable<md.Node>? close(
    md.InlineParser parser,
    covariant md.SimpleDelimiter opener,
    md.Delimiter? closer, {
    String? tag,
    required List<md.Node> Function() getChildren,
  }) {
    final bracketAt = parser.pos;
    final nodes = super.close(
      parser,
      opener,
      closer,
      tag: tag,
      getChildren: getChildren,
    );
    _recordMarkdownDestination(
      parser,
      bracketAt,
      spans,
      embed: false,
      nodes: nodes,
    );
    return nodes;
  }
}

final class _RecordingAutolink extends md.AutolinkSyntax {
  _RecordingAutolink(this.spans);

  final List<_LinkTarget> spans;

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final url = match.group(1);
    if (url != null && url.isNotEmpty) {
      spans.add(
        _LinkTarget(
          start: match.start + 1,
          end: match.end - 1,
          raw: url,
          classifyText: url,
          embed: false,
        ),
      );
    }
    return super.onMatch(parser, match);
  }
}

final class _RecordingExtendedAutolink extends md.AutolinkExtensionSyntax {
  _RecordingExtendedAutolink(this.spans);

  final List<_LinkTarget> spans;

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    if (match.group(1) != null) {
      final url = match.group(1)!;
      spans.add(
        _LinkTarget(
          start: match.start,
          end: match.start + url.length,
          raw: url,
          classifyText: url,
          embed: false,
        ),
      );
    }
    return super.onMatch(parser, match);
  }
}

final class _RecordingHtml extends md.InlineHtmlSyntax {
  _RecordingHtml(this.spans);

  final List<_LinkTarget> spans;

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    _recordHtmlTag(parser.source, match.start, match.group(0) ?? '', spans);
    return super.onMatch(parser, match);
  }
}

void _recordHtmlTag(
  String source,
  int offset,
  String raw,
  List<_LinkTarget> spans,
) {
  final fragment = html_parser.parseFragment(raw, generateSpans: true);
  for (final node in fragment.nodes) {
    if (node is! dom.Element) continue;
    final embed = _htmlEmbedTags.contains(node.localName);
    final anchor = node.localName == 'a';
    if (!embed && !anchor) continue;
    final values = node.attributeValueSpans;
    if (values == null) continue;
    for (final entry in values.entries) {
      final name = entry.key.toString().toLowerCase();
      if (embed && name != 'src') continue;
      if (anchor && name != 'href') continue;
      final span = entry.value;
      if (span.start.offset < 0 || span.end.offset > raw.length) continue;
      final value = raw.substring(span.start.offset, span.end.offset);
      spans.add(
        _LinkTarget(
          start: offset + span.start.offset,
          end: offset + span.end.offset,
          raw: value,
          classifyText: value,
          embed: embed,
        ),
      );
    }
  }
  // `source` is the parser input. Offsets above already include [offset].
  if (source.isEmpty && spans.isEmpty) return;
}

List<String> _segments(Uri uri) => <String>[
  for (final segment in uri.pathSegments)
    if (segment.isNotEmpty) segment,
];

List<String> _pathSegments(String? path) {
  if (path == null || path.isEmpty) return const <String>[];
  return <String>[
    for (final segment in path.split('/'))
      if (segment.isNotEmpty) segment,
  ];
}

bool _sameSegments(List<String> left, List<String> right) {
  if (left.length != right.length || left.isEmpty) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}

String _trimTrailingUrlPunctuation(String value) =>
    value.replaceFirst(RegExp(r'[.,;:]+$'), '');

const _redactedMarker = '[REDACTED]';

final _uploadPlaceholder = RegExp(r'\[\[upload:u-([0-9]+)\]\]');
final _attachmentPlaceholder = RegExp(r'\[\[attachment:att-([0-9]+)\]\]');
final _uploadSecretProbe = RegExp(
  'uploads/[0-9a-fA-F]{32}(?![0-9a-fA-F])',
  caseSensitive: false,
);
final _mentionPattern = RegExp(
  r'(?<![A-Za-z0-9_])@([A-Za-z0-9_.][A-Za-z0-9_.\-/]*)',
);
final _broadcastMention = RegExp(
  r'@(?:all|here)(?![A-Za-z0-9_])',
  caseSensitive: false,
);
final _trailingMentionPunctuation = RegExp(r'[.\-/]+$');
final _qualifiedRef = RegExp(
  r'(?<![A-Za-z0-9_])([A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+)([#!])([0-9]+)',
);
final _bareUrl = RegExp(r'https?://[^\s<>()\]]+', caseSensitive: false);
final _redactionMarkerPattern = RegExp(r'\[REDACTED(?::[A-Za-z0-9_]+)?\]');
final _rebuiltUpload = RegExp(
  r'!\[[^\]\r\n]*\]\(/uploads/[0-9a-f]{32}/[^)\s]+\)',
);
final _attachmentMarkdown = RegExp(
  r'^!?\[([^\r\n\]]*)\]\(/uploads/([0-9a-f]{32})/([^)\s]+)\)\s*$',
);
final _fenceOpening = RegExp(r'^[ ]{0,3}(`{3,}|~{3,})');
final _referenceLabel = RegExp(r'^[ ]{0,3}\[[^\]\n]+\]:[ \t]*');
const _htmlEmbedTags = <String>{'img', 'video', 'audio', 'source'};
const _htmlMediaOrAnchor = <String>{'img', 'video', 'audio', 'source', 'a'};
