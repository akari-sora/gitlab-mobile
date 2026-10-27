/// U-add (MR6b-3g §6.1, decision D27): a group work item the user adds to a
/// conversation's write scope. The link is parsed here, before any read; the
/// reads, the grant and the segment belong to the chat controller.
library;

import '../../core/ai/tools/target_binding.dart' show isValidAiGroupPath;
import '../../core/failure.dart';
import '../../core/instance.dart';

/// Why a typed link is refused before any request is made.
enum AiGroupWorkItemLinkRefusal {
  /// Not a complete HTTPS link, or one with an unusable path or iid.
  malformed,

  /// Another origin, another installation path, or not HTTPS.
  otherInstance,

  /// A project's resource, never a group's own work item.
  projectLink,

  /// A group link that does not name one work item (lists, epics, pages).
  notWorkItem,
}

sealed class AiGroupWorkItemLinkResult {
  const AiGroupWorkItemLinkResult();
}

/// A group work-item link exactly as typed. [fullPath] only selects the fresh
/// reads: it is neither ownership evidence nor a source of the Group ID.
final class AiGroupWorkItemLink extends AiGroupWorkItemLinkResult {
  const AiGroupWorkItemLink._(this.fullPath, this.iid);

  final String fullPath;
  final int iid;
}

final class AiGroupWorkItemLinkRefused extends AiGroupWorkItemLinkResult {
  const AiGroupWorkItemLinkRefused(this.reason);

  final AiGroupWorkItemLinkRefusal reason;
}

const _tokenKeys = {'access_token', 'private_token', 'token', 'job_token'};

/// Accepts only `https://<instance>/groups/<full path>/-/work_items/<iid>`
/// on [instance] (same origin and installation path), optionally with a
/// trailing slash, a query without credentials and a fragment. Epic and
/// group issue routes are refused: their numbers are not proven to be the
/// work item's iid.
AiGroupWorkItemLinkResult parseAiGroupWorkItemLink(
  String input,
  GitLabInstance instance,
) {
  const malformed = AiGroupWorkItemLinkRefused(
    AiGroupWorkItemLinkRefusal.malformed,
  );
  final text = input.trim();
  if (text.isEmpty ||
      text.length > 2048 ||
      RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(text)) {
    return malformed;
  }
  final scheme = RegExp(r'^([A-Za-z][A-Za-z0-9+.-]*)://').firstMatch(text);
  if (scheme == null) return malformed;
  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty) return malformed;
  if (scheme.group(1)!.toLowerCase() != 'https' ||
      uri.userInfo.isNotEmpty ||
      !instance.sameOrigin(uri)) {
    return const AiGroupWorkItemLinkRefused(
      AiGroupWorkItemLinkRefusal.otherInstance,
    );
  }
  // The raw path, before Uri normalization can hide traversal or encoding.
  // GitLab group paths never need percent-encoding, so any is refused.
  final rawPath =
      RegExp(
        r'^https://[^/?#]+([^?#]*)',
        caseSensitive: false,
      ).firstMatch(text)?.group(1) ??
      '';
  // Same rule as GitLabInstance.parse: Uri removes `.`/`..` segments, so a
  // traversal that normalises to a valid group link is refused here.
  if (rawPath.contains('\\') ||
      rawPath.contains('%') ||
      rawPath.contains('//') ||
      rawPath.split('/').any((part) => part == '.' || part == '..')) {
    return malformed;
  }
  try {
    if (uri.queryParameters.keys.any(
      (key) => _tokenKeys.contains(key.toLowerCase()),
    )) {
      return malformed;
    }
  } on FormatException {
    return malformed;
  }
  final segments = uri.pathSegments.toList();
  if (segments.isNotEmpty && segments.last.isEmpty) segments.removeLast();
  if (segments.any((part) => part.isEmpty || part == '.' || part == '..')) {
    return malformed;
  }
  final base = instance.base.pathSegments.where((part) => part.isNotEmpty);
  final prefix = base.toList();
  if (segments.length < prefix.length) {
    return const AiGroupWorkItemLinkRefused(
      AiGroupWorkItemLinkRefusal.otherInstance,
    );
  }
  for (var i = 0; i < prefix.length; i++) {
    if (segments[i] != prefix[i]) {
      return const AiGroupWorkItemLinkRefused(
        AiGroupWorkItemLinkRefusal.otherInstance,
      );
    }
  }
  final rest = segments.sublist(prefix.length);
  if (rest.isEmpty) return malformed;
  if (rest.first != 'groups') {
    return AiGroupWorkItemLinkRefused(
      rest.contains('-')
          ? AiGroupWorkItemLinkRefusal.projectLink
          : AiGroupWorkItemLinkRefusal.notWorkItem,
    );
  }
  final dash = rest.indexOf('-', 1);
  if (dash < 0) {
    return const AiGroupWorkItemLinkRefused(
      AiGroupWorkItemLinkRefusal.notWorkItem,
    );
  }
  final fullPath = rest.sublist(1, dash).join('/');
  if (fullPath.isEmpty || !isValidAiGroupPath(fullPath)) return malformed;
  final tail = rest.sublist(dash + 1);
  if (tail.length != 2 || tail.first != 'work_items') {
    return const AiGroupWorkItemLinkRefused(
      AiGroupWorkItemLinkRefusal.notWorkItem,
    );
  }
  final number = tail.last;
  final iid = RegExp(r'^[1-9][0-9]{0,9}$').hasMatch(number)
      ? int.tryParse(number)
      : null;
  if (iid == null || iid > 0x7fffffff) return malformed;
  return AiGroupWorkItemLink._(fullPath, iid);
}

/// A group work item in this conversation's scope, as the page shows it.
/// [title] is display-safe; [fullPath] and [iid] come from the verified read.
final class AiAddedGroupWorkItem {
  const AiAddedGroupWorkItem({
    required this.key,
    required this.fullPath,
    required this.iid,
    required this.title,
  });

  /// Stable within the conversation: numeric owner and iid, never a path.
  final String key;
  final String fullPath;
  final int iid;
  final String title;
}

/// Why a check or an add did not put anything in scope.
enum AiGroupWorkItemRefusal {
  malformed,
  otherInstance,
  projectLink,
  notWorkItem,

  /// The item is already in this conversation's scope.
  alreadyInScope,

  /// GitLab did not prove that the item belongs directly to the group the
  /// link names, or the identity changed between the reads.
  notGroupOwned,

  /// The conversation is running, waiting for approval, or busy.
  unavailable,

  /// The confirmed check is no longer the latest one, or the conversation,
  /// account or client changed since. Nothing is reused; check again.
  stale,

  /// A GitLab read or the request budget failed; see [AiGroupWorkItemRefused.failure].
  readFailed,
}

sealed class AiGroupWorkItemCheck {
  const AiGroupWorkItemCheck();
}

/// A fully verified item the user may confirm. Only the conversation that
/// issued it accepts it, once, while nothing changed in between.
final class AiGroupWorkItemCandidate extends AiGroupWorkItemCheck {
  AiGroupWorkItemCandidate({
    required this.fullPath,
    required this.iid,
    required this.title,
    required this.endsConversationGrant,
  });

  final String fullPath;
  final int iid;

  /// Display-safe GitLab title.
  final String title;

  /// Adding ends the conversation's own grant ("this conversation only"),
  /// which was given for the scope it had then.
  final bool endsConversationGrant;
}

final class AiGroupWorkItemRefused extends AiGroupWorkItemCheck {
  const AiGroupWorkItemRefused(
    this.reason, {
    this.failure,
    this.fullPath,
    this.iid,
  });

  final AiGroupWorkItemRefusal reason;

  /// For [AiGroupWorkItemRefusal.readFailed]: the GitLab failure (a 404
  /// stays ambiguous) or the budget's [UserFacingFailure].
  final UserFacingFailure? failure;

  /// The typed path and iid when the link parsed, to name the resource a
  /// failed read was about. Never ownership evidence.
  final String? fullPath;
  final int? iid;
}

/// Optional controls of a conversation that can take user-added group work
/// items. Models and tool results have no path to these methods.
abstract interface class AiScopeAddSession {
  /// Whether this conversation offers the action at all.
  bool get offersGroupWorkItemAdd;

  /// The account's instance, the only one a link may point to.
  String get scopeAddInstance;

  /// Whether a check or an add can start now: idle, nothing waiting.
  bool get canAddGroupWorkItem;

  List<AiAddedGroupWorkItem> get addedGroupWorkItems;

  /// Parses [link], then reads GitLab within the conversation's read budget.
  /// Changes nothing.
  Future<AiGroupWorkItemCheck> checkGroupWorkItem(String link);

  /// Puts [candidate] in scope after the user confirmed it. Null when added;
  /// otherwise why nothing was added.
  Future<AiGroupWorkItemRefusal?> addGroupWorkItem(
    AiGroupWorkItemCandidate candidate,
  );

  /// Takes [item] and its grant out of scope.
  void removeGroupWorkItem(AiAddedGroupWorkItem item);
}
