import 'dart:convert';
import 'dart:typed_data';

/// Plaintext framing: a four-byte big-endian metadata length, UTF-8 metadata
/// JSON, then body bytes. Encryption and all I/O belong to later packets.
const readCacheDiskSchemaVersion = 1;
const readCacheMetadataLengthBytes = 4;
const readCacheEntryLimit = 1024 * 1024;
const readCacheTerminalLogLimit = 2 * 1024 * 1024;
const readCacheMaxDepth = 32;
const readCacheMaxArrayLength = 4096;
const readCacheMaxValueNodes = 32768;

enum ReadCacheDiskClass { projectMeta, list, detail, thread, pinned }

enum ReadCacheBodyKind { json, page, text, terminalLog }

enum ReadCacheProofLineage { network, disk }

/// Obtained only after account verification. Generation stays in process; it
/// is deliberately excluded from durable keys and serialized metadata.
final class DiskBinding {
  const DiskBinding({required this.accountKey, required this.generation});

  final String accountKey;
  final int generation;

  @override
  bool operator ==(Object other) =>
      other is DiskBinding &&
      accountKey == other.accountKey &&
      generation == other.generation;

  @override
  int get hashCode => Object.hash(accountKey, generation);
}

final class ReadCacheIssueIdentity {
  const ReadCacheIssueIdentity(this.projectId, this.iid);

  final int projectId;
  final int iid;

  @override
  bool operator ==(Object other) =>
      other is ReadCacheIssueIdentity &&
      projectId == other.projectId &&
      iid == other.iid;

  @override
  int get hashCode => Object.hash(projectId, iid);
}

/// The owner checks this lease at every isolate/temporary-write/rename/index
/// boundary. A revoked lease never authorizes a late publication.
abstract interface class DiskCommitLease {
  bool get isCurrent;
  void revoke();
}

/// Publication evidence for a network result accepted by the cache owner.
/// The raw response is passed directly to the projector, never into this DTO
/// or the backend. Only the separate projected entry crosses that boundary.
final class DiskWriteCandidate {
  DiskWriteCandidate({
    required this.binding,
    required this.uri,
    required this.logicalAccept,
    required this.bodyKind,
    required this.fetchedAt,
    required this.responseBytes,
    required this.lease,
    // Safety gates have no permissive default: the owner states each one.
    required this.cacheable,
    required this.noStore,
    required this.firstPage,
    this.method = 'GET',
    this.typedPinned = false,
    this.next,
    this.privacyEpoch = 0,
    Map<String, int> scopeVersions = const {},
    Set<String> scopeTags = const {},
  }) : scopeVersions = Map.unmodifiable(scopeVersions),
       scopeTags = Set.unmodifiable(scopeTags);

  final DiskBinding binding;
  final Uri uri;
  final String logicalAccept;
  final ReadCacheBodyKind bodyKind;
  final DateTime fetchedAt;
  final int responseBytes;
  final DiskCommitLease lease;
  final String method;
  final bool cacheable, noStore, firstPage, typedPinned;
  final Uri? next;
  final int privacyEpoch;
  final Map<String, int> scopeVersions;
  final Set<String> scopeTags;
}

/// Trusted evidence must come from a same-client, single-issue memory entry,
/// with network lineage and a still-current scope/privacy snapshot.
final class ReadCachePublicIssueProof {
  ReadCachePublicIssueProof({
    required this.binding,
    required this.identity,
    required this.fetchedAt,
    required this.lineage,
    required this.singleIssue,
    required this.confidential,
    required this.privacyEpoch,
    Map<String, int> scopeVersions = const {},
  }) : scopeVersions = Map.unmodifiable(scopeVersions);

  final DiskBinding binding;
  final ReadCacheIssueIdentity identity;
  final DateTime fetchedAt;
  final ReadCacheProofLineage lineage;
  final bool singleIssue;
  final bool? confidential;
  final int privacyEpoch;
  final Map<String, int> scopeVersions;
}

/// A fresh network Job read, bound to this client/session and attempt. Running,
/// erased, foreign or old metadata cannot qualify a terminal log.
final class ReadCacheTerminalJobProof {
  const ReadCacheTerminalJobProof({
    required this.binding,
    required this.projectId,
    required this.jobId,
    required this.status,
    required this.finishedAt,
    required this.fetchedAt,
    required this.lineage,
    required this.erased,
  });

  final DiskBinding binding;
  final int projectId, jobId;
  final String status;
  final DateTime finishedAt, fetchedAt;
  final ReadCacheProofLineage lineage;
  final bool erased;
}

/// UTF-8 tail bytes and absolute offsets, never a localized truncation prefix.
/// The transport adapter must verify Range/EOF before constructing this DTO.
final class ReadCacheTerminalLog {
  ReadCacheTerminalLog({
    required this.projectId,
    required this.jobId,
    required this.finishedAt,
    required this.startOffset,
    required this.nextOffset,
    required this.totalBytes,
    required this.isEof,
    required this.truncated,
    required List<int> bytes,
  }) : bytes = Uint8List.fromList(bytes).asUnmodifiableView();

  final int projectId, jobId;
  final DateTime finishedAt;
  final int startOffset, nextOffset, totalBytes;
  final bool isEof, truncated;
  final Uint8List bytes;

  Map<String, Object> get metadata => {
    'projectId': projectId,
    'jobId': jobId,
    'finishedAt': finishedAt.toUtc().toIso8601String(),
    'startOffset': startOffset,
    'nextOffset': nextOffset,
    'totalBytes': totalBytes,
    'isEof': isEof,
    'truncated': truncated,
  };
}

/// Contains only closed-schema data. The commit lease stays on the candidate,
/// outside the persistent entry. Bodies supplied here must already be frozen.
final class ProjectedDiskEntry {
  ProjectedDiskEntry({
    required this.accountKey,
    required this.canonicalKey,
    required this.cacheClass,
    required this.bodyKind,
    required this.fetchedAt,
    required this.body,
    required this.privacyEpoch,
    required Set<ReadCacheIssueIdentity> issueIdentities,
    Map<String, int> scopeVersions = const {},
    Set<String> scopeTags = const {},
  }) : issueIdentities = Set.unmodifiable(issueIdentities),
       scopeVersions = Map.unmodifiable(scopeVersions),
       scopeTags = Set.unmodifiable(scopeTags);

  final String accountKey, canonicalKey;
  final ReadCacheDiskClass cacheClass;
  final ReadCacheBodyKind bodyKind;
  final DateTime fetchedAt;
  final Object body;
  final int privacyEpoch;
  final Set<ReadCacheIssueIdentity> issueIdentities;
  final Map<String, int> scopeVersions;
  final Set<String> scopeTags;

  bool get pinned => cacheClass == ReadCacheDiskClass.pinned;
  int get plaintextLimit => bodyKind == ReadCacheBodyKind.terminalLog
      ? readCacheTerminalLogLimit
      : readCacheEntryLimit;

  Map<String, Object> get metadata {
    final identities = issueIdentities.toList()
      ..sort((a, b) {
        final project = a.projectId.compareTo(b.projectId);
        return project == 0 ? a.iid.compareTo(b.iid) : project;
      });
    final tags = scopeTags.toList()..sort();
    final versions = scopeVersions.keys.toList()..sort();
    return {
      'schema': readCacheDiskSchemaVersion,
      'accountKey': accountKey,
      'canonicalKey': canonicalKey,
      'cacheClass': cacheClass.name,
      'bodyKind': bodyKind.name,
      'fetchedAt': fetchedAt.toUtc().toIso8601String(),
      'privacyEpoch': privacyEpoch,
      'scopeTags': tags,
      'scopeVersions': {for (final key in versions) key: scopeVersions[key]!},
      'issueIdentities': [
        for (final id in identities) [id.projectId, id.iid],
      ],
      if (body case ReadCacheTerminalLog log) 'terminalLog': log.metadata,
    };
  }

  Uint8List get bodyBytes => switch (body) {
    ReadCacheTerminalLog log => log.bytes,
    String text when bodyKind == ReadCacheBodyKind.text => Uint8List.fromList(
      utf8.encode(text),
    ),
    _ => Uint8List.fromList(utf8.encode(jsonEncode(body))),
  };

  int get serializedLength =>
      readCacheMetadataLengthBytes +
      utf8.encode(jsonEncode(metadata)).length +
      bodyBytes.length;
}

final class DiskLookup {
  const DiskLookup({
    required this.binding,
    required this.canonicalKey,
    required this.bodyKind,
    required this.lease,
  });

  final DiskBinding binding;
  final String canonicalKey;
  final ReadCacheBodyKind bodyKind;
  final DiskCommitLease lease;
}

enum DiskInvalidationKind { mutation, privacy, permission, account }

final class DiskInvalidation {
  DiskInvalidation({
    required this.binding,
    required this.kind,
    Set<String> scopeTags = const {},
    Set<ReadCacheIssueIdentity> issueIdentities = const {},
    this.canonicalKey,
    this.path,
  }) : scopeTags = Set.unmodifiable(scopeTags),
       issueIdentities = Set.unmodifiable(issueIdentities);

  final DiskBinding binding;
  final DiskInvalidationKind kind;
  final Set<String> scopeTags;
  final Set<ReadCacheIssueIdentity> issueIdentities;
  final String? canonicalKey;
  final Uri? path;
}

/// Created synchronously: stale lookups/leases/queued work are fenced before
/// waiting for durable deletion. Timeout never implies I/O quiescence.
abstract interface class DiskInvalidationFence {
  bool get isCurrent;
  Future<DiskClearResult> get barrier;
  Future<void> get quiesced;
  void revoke();
}

final class DiskClearResult {
  /// [complete] requires both the key and the directory confirmed gone (§5.3);
  /// [markerDurable] is independent (a removal may keep its marker).
  const DiskClearResult({
    required this.keyGoneConfirmed,
    required this.directoryGoneConfirmed,
    required this.markerDurable,
    required this.complete,
  }) : assert(!complete || (keyGoneConfirmed && directoryGoneConfirmed));

  final bool keyGoneConfirmed, directoryGoneConfirmed, markerDurable, complete;
}

final class ReadCacheStartupDecision {
  const ReadCacheStartupDecision({
    required this.operationTicket,
    required this.accountListRevision,
    required this.accountsReadable,
    required this.signOutMarkerReadable,
    required this.lastActiveReadable,
    required this.signOutPending,
    required this.resumeAccountKey,
  });

  final int operationTicket, accountListRevision;
  final bool accountsReadable, signOutMarkerReadable, lastActiveReadable;
  final bool signOutPending;
  final String? resumeAccountKey;

  bool get readable =>
      accountsReadable && signOutMarkerReadable && lastActiveReadable;
}

enum ReadCacheCleanupOperation {
  mutation,
  privacyRead,
  accountRemoval,
  signOut,
  settingsClear,
  startup,
}

enum ReadCacheCleanupDisposition {
  requestBlockedBeforeSend,
  originalOutcomePreserved,
  legalNetworkValueReturned,
  accountRetained,
  signedOutCleanupPending,
  diskClosed,
}

enum ReadCacheCleanupCode { cleanupFailed, barrierTimedOut }

/// Deliberately contains no exception, stack, URI, path, content or identity.
final class ReadCacheCleanupState {
  const ReadCacheCleanupState({
    required this.operation,
    required this.disposition,
    required this.code,
    required this.clearResult,
  });

  final ReadCacheCleanupOperation operation;
  final ReadCacheCleanupDisposition disposition;
  final ReadCacheCleanupCode code;
  final DiskClearResult clearResult;
}

/// No implementation is installed by P-C2a. The feature adapter owns I/O and
/// notices; the core calls only this interface and these pure DTOs.
abstract interface class ReadCacheDiskBackend {
  Future<ProjectedDiskEntry?> lookup(DiskLookup lookup);
  void accept(DiskWriteCandidate candidate, ProjectedDiskEntry entry);
  DiskInvalidationFence invalidate(DiskInvalidation invalidation);
  void revoke(DiskBinding binding);
  Future<DiskClearResult> clear(
    DiskBinding binding,
    ReadCacheCleanupOperation operation,
  );
  void reportCleanup(ReadCacheCleanupState state);
}
