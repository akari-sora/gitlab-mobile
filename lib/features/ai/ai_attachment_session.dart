import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../core/ai/prompts.dart';
import '../../core/ai/redaction.dart';
import '../../core/ai/tools/attachment_budget.dart';
import '../../core/ai/tools/write_tier.dart';
import '../../core/ai/write_text.dart' show AttachmentSubstitution;
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/upload_names.dart';
import '../workspace/attachment_picker.dart';

/// File bytes held for one conversation. [bytes] is for the write port only.
final class AiStoredAttachment {
  AiStoredAttachment._({
    required this.id,
    required this.filename,
    required this.size,
    required this.mediaType,
    required this.sha256,
    required Uint8List bytes,
  }) : _bytes = bytes;

  final String id;
  final String filename;
  final int size;
  final String? mediaType;
  final String sha256;
  final Uint8List _bytes;

  List<int> get bytes => _bytes;

  String get sha256Prefix => sha256.substring(0, 8);
}

enum AiAttachStatus {
  stored,
  disabled,
  capacity,
  tooLarge,
  cancelled,
  readFailed,
  invalidName,
  expired,
}

enum AiAttachmentPick { image, file }

/// Where a public or internal upload warning is shown.
enum AiUploadNoticeSurface { none, card, audit }

final class AiAttachResult {
  const AiAttachResult({
    required this.status,
    required this.reasonCode,
    this.attachment,
  });

  final AiAttachStatus status;
  final String? reasonCode;
  final AiStoredAttachment? attachment;
}

final class AiAttachmentIdVerdict {
  const AiAttachmentIdVerdict.rejected(this.reasonCode)
    : accepted = false,
      attachment = null;

  AiAttachmentIdVerdict.accepted(AiStoredAttachment this.attachment)
    : accepted = true,
      reasonCode = null;

  final bool accepted;
  final String? reasonCode;
  final AiStoredAttachment? attachment;
}

/// Stream intake. [AttachmentPicker] reads at [GitLabApi.maxUploadBytes]
/// inside the plugin, so a tighter conversation or process cap uses this.
final class AiAttachmentIntake {
  const AiAttachmentIntake({
    required this.filename,
    required this.length,
    required this.open,
    this.mediaType,
    this.pickedCopyPath,
  });

  final String filename;
  final int? length;
  final Stream<List<int>> Function() open;
  final String? mediaType;
  final String? pickedCopyPath;
}

/// A proposal dropped before dispatch. [journal] is true only after prepared.
final class AiAttachmentInvalidation {
  const AiAttachmentInvalidation({
    required this.attachmentId,
    required this.reasonCode,
    required this.journal,
    required this.releaseName,
    required this.sha256,
    this.projectId,
    this.conflictKey,
  });

  final String attachmentId;
  final String reasonCode;
  final bool journal;
  final String releaseName;
  final String sha256;
  final int? projectId;
  final List<String>? conflictKey;

  Map<String, Object?> toJson() => <String, Object?>{
    'attachmentId': attachmentId,
    'reasonCode': reasonCode,
    'journal': journal,
    'releaseName': releaseName,
    'sha256': sha256,
    'projectId': projectId,
    'conflictKey': conflictKey,
  };
}

final class AiUploadVisibilityNotice {
  const AiUploadVisibilityNotice({required this.surface, this.reasonCode});

  final AiUploadNoticeSurface surface;
  final String? reasonCode;
}

/// Journal row supplied by packet 2. States are packet 5's classification.
abstract final class AiUploadRecordState {
  static const String succeeded = 'succeeded';
  static const String writeUncertain = 'writeUncertain';
  static const String dispatching = 'dispatching';
  static const String resolvedByUser = 'resolvedByUser';
}

final class AiPriorUpload {
  const AiPriorUpload({
    required this.accountKey,
    required this.projectId,
    required this.sha256,
    required this.state,
    required this.releaseName,
    this.confirmMark = false,
  });

  final String accountKey;
  final int projectId;
  final String sha256;
  final String state;
  final String releaseName;
  final bool confirmMark;
}

final class AiUploadPlan {
  const AiUploadPlan({
    required this.conflictKey,
    required this.releaseName,
    required this.blocked,
    required this.mayPropose,
    required this.forcesConfirmation,
    required this.reasonCodes,
  });

  final List<String> conflictKey;
  final String releaseName;
  final bool blocked;

  /// False when an unknown upload of this hash still isolates the project.
  final bool mayPropose;

  /// True at every autonomy level, including bypass.
  final bool forcesConfirmation;
  final List<String> reasonCodes;
}

/// `(account, project:<id>, upload, sha256)` parts for the journal key.
List<String> attachmentConflictKey({
  required String accountKey,
  required int projectId,
  required String sha256,
}) => <String>[accountKey, 'project:$projectId', 'upload', sha256];

/// Filename half of [projectUploadNamesOk]. The secret is not known yet.
bool attachmentFilenameOk(String filename) =>
    projectUploadNamesOk('0123456789abcdef0123456789abcdef', filename);

/// Directional isolates are ignored. Other characters, including emoji and
/// RTL letters, are compared as stored.
bool attachmentReleaseNamesMatch(String typed, String releaseName) =>
    _stripIsolates(typed) == _stripIsolates(releaseName);

/// Stored journal name when [typed] matches, so an exact journal compare
/// receives the original filename rather than the isolated typing.
String? journalReleaseName({required String typed, required String stored}) {
  if (!attachmentReleaseNamesMatch(typed, stored)) return null;
  return stored;
}

String _stripIsolates(String value) => value.replaceAll(_isolates, '');

final RegExp _isolates = RegExp('[\u2066-\u2069]');

/// Packet 5 applies this as the per-request send timeout for an AI upload.
/// Screen uploads keep GitLab's default. Ceiling is four minutes.
Duration aiUploadSendTimeout(int sizeBytes) {
  const int floorSeconds = 15;
  const int ceilingSeconds = 4 * 60;
  const int bytesPerSecond = 128 * 1024;
  if (sizeBytes <= 0) return const Duration(seconds: floorSeconds);
  final int seconds = (sizeBytes + bytesPerSecond - 1) ~/ bytesPerSecond;
  if (seconds <= floorSeconds) return const Duration(seconds: floorSeconds);
  if (seconds >= ceilingSeconds) {
    return const Duration(seconds: ceilingSeconds);
  }
  return Duration(seconds: seconds);
}

/// Confirmation card for confirm-each and low-risk auto (T2 still asks).
/// Conversation grant and bypass record the same code on the audit row.
AiUploadVisibilityNotice uploadVisibilityNotice({
  required String visibility,
  required AiAutonomyLevel level,
}) {
  final String normalized = visibility.trim().toLowerCase();
  if (normalized != 'public' && normalized != 'internal') {
    return const AiUploadVisibilityNotice(surface: AiUploadNoticeSurface.none);
  }
  switch (level) {
    case AiAutonomyLevel.readOnly:
      return const AiUploadVisibilityNotice(
        surface: AiUploadNoticeSurface.none,
      );
    case AiAutonomyLevel.confirmEach:
    case AiAutonomyLevel.lowRiskAuto:
      return const AiUploadVisibilityNotice(
        surface: AiUploadNoticeSurface.card,
        reasonCode: uploadReadersCanFetch,
      );
    case AiAutonomyLevel.conversationGrant:
    case AiAutonomyLevel.bypass:
      return const AiUploadVisibilityNotice(
        surface: AiUploadNoticeSurface.audit,
        reasonCode: uploadReadersCanFetch,
      );
  }
}

const String uploadReadersCanFetch = 'uploadReadersCanFetch';

AiUploadPlan planAttachmentUpload({
  required String accountKey,
  required int projectId,
  required String sha256,
  required String filename,
  required Iterable<AiPriorUpload> prior,
}) {
  final List<String> key = attachmentConflictKey(
    accountKey: accountKey,
    projectId: projectId,
    sha256: sha256,
  );
  final List<AiPriorUpload> hits = <AiPriorUpload>[
    for (final AiPriorUpload row in prior)
      if (row.accountKey == accountKey &&
          row.projectId == projectId &&
          row.sha256 == sha256)
        row,
  ];
  final bool isolated = hits.any(
    (AiPriorUpload row) =>
        row.state == AiUploadRecordState.writeUncertain ||
        row.state == AiUploadRecordState.dispatching,
  );
  if (isolated) {
    return AiUploadPlan(
      conflictKey: List<String>.unmodifiable(key),
      releaseName: filename,
      blocked: true,
      mayPropose: false,
      forcesConfirmation: false,
      reasonCodes: const <String>['isolated'],
    );
  }
  final List<String> reasons = <String>[
    if (hits.any(
      (AiPriorUpload row) => row.state == AiUploadRecordState.succeeded,
    ))
      'possibleDuplicate',
    if (hits.any((AiPriorUpload row) => row.confirmMark)) 'confirmMark',
  ];
  return AiUploadPlan(
    conflictKey: List<String>.unmodifiable(key),
    releaseName: filename,
    blocked: false,
    mayPropose: true,
    forcesConfirmation: reasons.isNotEmpty,
    reasonCodes: List<String>.unmodifiable(reasons),
  );
}

enum _Phase { none, proposed, prepared, dispatched }

final class _NoSecrets implements KnownSecretsSource {
  const _NoSecrets();

  @override
  Iterable<String> get current => const <String>[];
}

final class _Held {
  _Held({required this.view, required this.bytes, required this.reservation});

  final AiStoredAttachment view;
  final Uint8List bytes;
  final AiAttachmentReservation reservation;
  _Phase phase = _Phase.none;
  bool uploading = false;
  bool dropAfterUpload = false;
  bool invalidated = false;
  int? projectId;

  String get id => view.id;
  String get filename => view.filename;
  String get sha256 => view.sha256;
}

/// In-memory attachments for one account and conversation.
///
/// Bytes stay in this process. Model metadata is an untrusted-data block
/// without bytes. Ending the conversation, switching accounts, or removing
/// a row wipes those bytes.
final class AiAttachmentSession {
  AiAttachmentSession({
    required this.accountKey,
    required this.conversationId,
    AiAttachmentBudget? budget,
    Redactor? redactor,
    int? fileCapBytes,
    Random? random,
  }) : _budget = budget ?? AiAttachmentBudget.shared,
       _redactor = redactor ?? Redactor(secrets: const _NoSecrets()),
       fileCapBytes = fileCapBytes ?? GitLabApi.maxUploadBytes,
       _random = random ?? Random.secure() {
    if (this.fileCapBytes < 1) {
      throw ArgumentError.value(this.fileCapBytes, 'fileCapBytes');
    }
    _live.add(this);
  }

  static const int maxCountPerConversation =
      AiAttachmentBudget.maxCountPerConversation;
  static const int maxBytesPerConversation =
      AiAttachmentBudget.maxBytesPerConversation;
  static const int maxBytesPerProcess = AiAttachmentBudget.maxBytesPerProcess;

  static final List<AiAttachmentSession> _live = <AiAttachmentSession>[];

  final String accountKey;
  final String conversationId;
  final int fileCapBytes;
  final AiAttachmentBudget _budget;
  final Redactor _redactor;
  final Random _random;
  final Map<String, _Held> _items = <String, _Held>{};
  final Set<String> _issued = <String>{};
  final List<AiAttachmentReservation> _inFlight = <AiAttachmentReservation>[];
  final List<AiAttachmentInvalidation> _invalidations =
      <AiAttachmentInvalidation>[];

  /// Succeeded uploads of this conversation: attachment id, then project id,
  /// then GitLab's `markdown` (null when it cannot be quoted). Memory only;
  /// removing the file's row keeps them, [discardAll] drops them.
  final Map<String, Map<int, String?>> _uploads = <String, Map<int, String?>>{};
  int _nextId = 1;
  int _generation = 0;
  bool _closed = false;

  static final RegExp _modelId = RegExp(r'^att-[1-9][0-9]*$');
  static final RegExp _metadataBlock = RegExp(
    r'<gitlab_data source="attachment_metadata"[^>]*>[\s\S]*?</gitlab_data>',
  );

  /// Budget identity for this account and conversation.
  String get capacityKey => '$accountKey\u0000$conversationId';

  /// Held files, oldest first.
  List<AiStoredAttachment> get items => List<AiStoredAttachment>.unmodifiable([
    for (final _Held held in _items.values) held.view,
  ]);

  /// Non-null when another positive-size file cannot be reserved.
  String? get capacityReason {
    if (_closed) return 'attachmentExpired';
    if (_budget.conversationCount(capacityKey) >= _budget.countLimit) {
      return 'attachmentCapacity';
    }
    if (_slice() <= 0) return 'attachmentCapacity';
    return null;
  }

  static void discardAccount(String accountKey) {
    final List<AiAttachmentSession> victims = <AiAttachmentSession>[
      for (final AiAttachmentSession session in _live)
        if (session.accountKey == accountKey) session,
    ];
    for (final AiAttachmentSession session in victims) {
      session.discardAll();
    }
  }

  Future<AiAttachResult> reserveAndRead({
    required AttachmentPicker picker,
    required bool uploadToolInSegment,
    AiAttachmentPick pick = AiAttachmentPick.file,
    AiAttachmentIntake? intake,
  }) async {
    final String? copyPath = intake?.pickedCopyPath;
    if (_closed) {
      await discardPickedCopy(copyPath);
      return _status(AiAttachStatus.expired, 'attachmentExpired');
    }
    if (!uploadToolInSegment) {
      await discardPickedCopy(copyPath);
      return _status(AiAttachStatus.disabled, 'uploadToolDisabled');
    }
    if (intake != null && !attachmentFilenameOk(intake.filename)) {
      await discardPickedCopy(copyPath);
      return _status(AiAttachStatus.invalidName, 'attachmentInvalidName');
    }
    final int? known = intake?.length;
    if (known != null && known > _effectiveFileCap) {
      await discardPickedCopy(copyPath);
      return _status(AiAttachStatus.tooLarge, 'attachmentTooLarge');
    }
    final int reserveBytes;
    if (known != null) {
      reserveBytes = known;
    } else {
      final int slice = _slice();
      if (slice <= 0) {
        await discardPickedCopy(copyPath);
        return _status(AiAttachStatus.capacity, 'attachmentCapacity');
      }
      reserveBytes = slice;
    }
    final int generation = _generation;
    final AiAttachmentReservation? reservation = _budget.tryReserve(
      conversation: capacityKey,
      bytes: reserveBytes,
    );
    if (reservation == null) {
      await discardPickedCopy(copyPath);
      return _status(AiAttachStatus.capacity, 'attachmentCapacity');
    }
    _inFlight.add(reservation);
    var adopted = false;
    PickedAttachment? picked;
    try {
      if (generation != _generation) {
        return _status(AiAttachStatus.expired, 'attachmentExpired');
      }
      if (intake != null) {
        picked = await _readIntake(intake, reserveBytes);
      } else if (pick == AiAttachmentPick.image) {
        picked = await picker.pickImage();
      } else {
        picked = await picker.pickFile();
      }
      if (generation != _generation) {
        _wipeLoose(picked?.bytes);
        return _status(AiAttachStatus.expired, 'attachmentExpired');
      }
      if (picked == null) {
        return _status(AiAttachStatus.cancelled, 'attachmentCancelled');
      }
      if (!attachmentFilenameOk(picked.filename)) {
        _wipeLoose(picked.bytes);
        return _status(AiAttachStatus.invalidName, 'attachmentInvalidName');
      }
      if (picked.bytes.length > _effectiveFileCap) {
        _wipeLoose(picked.bytes);
        return _status(AiAttachStatus.tooLarge, 'attachmentTooLarge');
      }
      if (picked.bytes.length > reservation.bytes) {
        _wipeLoose(picked.bytes);
        return _status(AiAttachStatus.capacity, 'attachmentCapacity');
      }
      if (picked.bytes.length < reservation.bytes) {
        _budget.shrink(reservation, picked.bytes.length);
      }
      final AiStoredAttachment stored = _adopt(picked, reservation);
      adopted = true;
      return AiAttachResult(
        status: AiAttachStatus.stored,
        reasonCode: null,
        attachment: stored,
      );
    } on ApiFailure catch (failure) {
      _wipeLoose(picked?.bytes);
      if (failure.kind == FailureKind.attachmentTooLarge) {
        return _status(AiAttachStatus.tooLarge, 'attachmentTooLarge');
      }
      return _status(AiAttachStatus.readFailed, 'attachmentReadFailed');
    } on Exception {
      _wipeLoose(picked?.bytes);
      return _status(AiAttachStatus.readFailed, 'attachmentReadFailed');
    } finally {
      await discardPickedCopy(copyPath);
      if (!adopted) {
        _inFlight.remove(reservation);
        _budget.release(reservation);
      }
    }
  }

  void noteProposed(String id) {
    final _Held? held = _items[id];
    if (held == null || held.phase != _Phase.none) return;
    held.phase = _Phase.proposed;
  }

  void notePrepared(String id, {required int projectId}) {
    final _Held? held = _items[id];
    if (held == null || held.phase == _Phase.dispatched) return;
    held.phase = _Phase.prepared;
    held.projectId = projectId;
  }

  /// Keeps the reservation until [finishUpload]. Removal during the upload
  /// does not free the bytes.
  void beginUpload(String id) {
    final _Held? held = _items[id];
    if (held == null) return;
    held.phase = _Phase.dispatched;
    held.uploading = true;
  }

  void finishUpload(String id) {
    final _Held? held = _items[id];
    if (held == null) return;
    held.uploading = false;
    if (held.dropAfterUpload) {
      _drop(held, invalidate: false);
    }
  }

  void remove(String id) {
    final _Held? held = _items[id];
    if (held == null) return;
    if (held.uploading) {
      held.dropAfterUpload = true;
      return;
    }
    _drop(held, invalidate: true);
  }

  /// Remembers that [id] was uploaded to [projectId] and the journal says
  /// `succeeded` (§3.1, placeholder substitution). [markdown] is kept only
  /// when it is one attachment token the app can rebuild (no CR, LF or
  /// other control character, no `[ ] ( )` in the name or file name, no
  /// second token); otherwise the upload stays a success that cannot be
  /// quoted. Returns whether `[[attachment:<id>]]` can be used.
  bool recordUpload(
    String id, {
    required int projectId,
    required String? markdown,
  }) {
    if (_closed || !_modelId.hasMatch(id)) return false;
    // The same rebuild the write uses decides: a markdown it cannot rebuild
    // is never handed to a later write.
    final bool referable =
        markdown != null &&
        !AttachmentSubstitution(<String, String?>{id: markdown})
            .substitute('[[attachment:$id]]', sameProjectClassA: true)
            .policyBlocked;
    (_uploads[id] ??= <int, String?>{})[projectId] = referable
        ? markdown
        : null;
    return referable;
  }

  /// Projects [id] was uploaded to in this conversation.
  Set<int> uploadedProjects(String id) =>
      Set<int>.unmodifiable(_uploads[id]?.keys ?? const <int>[]);

  /// The uploads into [projectId] a later write in that project may quote.
  /// Null when there are none.
  AttachmentSubstitution? substitutionFor(int projectId) {
    final Map<String, String?> markdown = <String, String?>{
      for (final MapEntry<String, Map<int, String?>> upload in _uploads.entries)
        if (upload.value.containsKey(projectId))
          upload.key: upload.value[projectId],
    };
    return markdown.isEmpty ? null : AttachmentSubstitution(markdown);
  }

  void discardAll() {
    _generation += 1;
    _closed = true;
    _uploads.clear();
    for (final _Held held in _items.values.toList()) {
      _invalidate(held);
      _wipe(held);
      _budget.release(held.reservation);
    }
    _items.clear();
    for (final AiAttachmentReservation reservation in _inFlight.toList()) {
      _budget.release(reservation);
    }
    _inFlight.clear();
    _live.remove(this);
  }

  AiStoredAttachment? lookup(String id) {
    if (!_modelId.hasMatch(id)) return null;
    return _items[id]?.view;
  }

  /// Model ids from this conversation only. URLs and other strings are
  /// rejected. Removed and discarded ids are expired.
  AiAttachmentIdVerdict resolveModelId(String id) {
    if (!_modelId.hasMatch(id)) {
      return const AiAttachmentIdVerdict.rejected('attachmentRejected');
    }
    final _Held? held = _items[id];
    if (held != null) return AiAttachmentIdVerdict.accepted(held.view);
    if (_issued.contains(id)) {
      return const AiAttachmentIdVerdict.rejected('attachmentExpired');
    }
    return const AiAttachmentIdVerdict.rejected('attachmentUnknown');
  }

  /// Untrusted-data block for the model. Filenames are redacted. No bytes.
  Map<String, Object?> metadataForModel() {
    final List<Map<String, Object?>> rows = <Map<String, Object?>>[
      for (final _Held held in _items.values)
        <String, Object?>{
          'id': held.id,
          'filename': _redactor.redactSource(held.filename).text,
          'size': held.view.size,
          'mediaType': held.view.mediaType,
        },
    ];
    final String nonce = _nonce();
    final String block = wrapUntrustedGitLabData(
      source: 'attachment_metadata',
      nonce: nonce,
      text: jsonEncode(rows),
    );
    return <String, Object?>{
      'source': 'attachment_metadata',
      'nonce': nonce,
      'block': block,
      'attachments': rows,
    };
  }

  /// User text for [bindTargets]. Attachment metadata blocks are removed
  /// so a filename's `#iid` or intent word is not a target-binding input.
  String textForTargetBinding(String userMessage) =>
      userMessage.replaceAll(_metadataBlock, ' ');

  /// Journal fields for a live attachment. Bytes, url, and markdown are
  /// omitted. Null after the row is gone.
  Map<String, Object?>? journalMetadata(String id, {required int projectId}) {
    final _Held? held = _items[id];
    if (held == null) return null;
    return <String, Object?>{
      'attachmentId': held.id,
      'releaseName': held.filename,
      'sha256': held.sha256,
      'size': held.view.size,
      'mediaType': held.view.mediaType,
      'conflictKey': attachmentConflictKey(
        accountKey: accountKey,
        projectId: projectId,
        sha256: held.sha256,
      ),
    };
  }

  List<AiAttachmentInvalidation> takeInvalidations() {
    final List<AiAttachmentInvalidation> copy =
        List<AiAttachmentInvalidation>.of(_invalidations);
    _invalidations.clear();
    return List<AiAttachmentInvalidation>.unmodifiable(copy);
  }

  int get _effectiveFileCap {
    final int cap = fileCapBytes;
    if (cap > GitLabApi.maxUploadBytes) return GitLabApi.maxUploadBytes;
    return cap;
  }

  int _slice() {
    var limit = _effectiveFileCap;
    final int conversation = _budget.conversationRemaining(capacityKey);
    final int process = _budget.processRemaining;
    if (conversation < limit) limit = conversation;
    if (process < limit) limit = process;
    return limit < 0 ? 0 : limit;
  }

  Future<PickedAttachment> _readIntake(
    AiAttachmentIntake intake,
    int maxBytes,
  ) {
    if (maxBytes >= GitLabApi.maxUploadBytes) {
      return readLimitedAttachment(
        filename: intake.filename,
        length: intake.length,
        open: intake.open,
        contentType: intake.mediaType,
      );
    }
    return _readWithin(intake, maxBytes);
  }

  Future<PickedAttachment> _readWithin(
    AiAttachmentIntake intake,
    int maxBytes,
  ) async {
    final int? length = intake.length;
    if (length != null && length > maxBytes) {
      throw const ApiFailure(FailureKind.attachmentTooLarge);
    }
    final BytesBuilder builder = BytesBuilder(copy: false);
    var total = 0;
    try {
      await for (final List<int> chunk in intake.open()) {
        if (chunk.length > maxBytes - total) {
          throw const ApiFailure(FailureKind.attachmentTooLarge);
        }
        builder.add(chunk);
        total += chunk.length;
      }
    } catch (_) {
      _wipeLoose(builder.takeBytes());
      rethrow;
    }
    return PickedAttachment(
      filename: intake.filename,
      bytes: builder.takeBytes(),
      contentType: intake.mediaType,
    );
  }

  AiStoredAttachment _adopt(
    PickedAttachment picked,
    AiAttachmentReservation reservation,
  ) {
    _inFlight.remove(reservation);
    final Uint8List owned = Uint8List.fromList(picked.bytes);
    _wipeLoose(picked.bytes);
    final String id = 'att-$_nextId';
    _nextId += 1;
    final AiStoredAttachment view = AiStoredAttachment._(
      id: id,
      filename: picked.filename,
      size: owned.length,
      mediaType: picked.contentType,
      sha256: sha256.convert(owned).toString(),
      bytes: owned,
    );
    _items[id] = _Held(view: view, bytes: owned, reservation: reservation);
    _issued.add(id);
    return view;
  }

  void _drop(_Held held, {required bool invalidate}) {
    if (invalidate) _invalidate(held);
    _wipe(held);
    _items.remove(held.id);
    _budget.release(held.reservation);
  }

  void _invalidate(_Held held) {
    if (held.invalidated) return;
    if (held.phase == _Phase.none || held.phase == _Phase.dispatched) return;
    held.invalidated = true;
    final int? projectId = held.projectId;
    _invalidations.add(
      AiAttachmentInvalidation(
        attachmentId: held.id,
        reasonCode: 'notExecuted',
        journal: held.phase == _Phase.prepared,
        releaseName: held.filename,
        sha256: held.sha256,
        projectId: projectId,
        conflictKey: projectId == null
            ? null
            : attachmentConflictKey(
                accountKey: accountKey,
                projectId: projectId,
                sha256: held.sha256,
              ),
      ),
    );
  }

  void _wipe(_Held held) {
    held.bytes.fillRange(0, held.bytes.length, 0);
  }

  void _wipeLoose(List<int>? bytes) {
    if (bytes == null) return;
    for (var i = 0; i < bytes.length; i++) {
      try {
        bytes[i] = 0;
      } on UnsupportedError {
        return;
      }
    }
  }

  String _nonce() {
    final StringBuffer buffer = StringBuffer();
    for (var i = 0; i < 16; i++) {
      buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  AiAttachResult _status(AiAttachStatus status, String reasonCode) =>
      AiAttachResult(status: status, reasonCode: reasonCode);
}
