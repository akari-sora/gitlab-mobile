import 'dart:convert';

import 'instance.dart';
import 'pagination.dart';
import 'read_cache_disk_contract.dart';

/// Evidence assembled by the same verified client, never by a disk/list row.
/// Projection is synchronous; the I/O owner must recheck its lease and this
/// scope/privacy evidence again immediately before committing the entry.
final class ReadCacheProjectionContext {
  ReadCacheProjectionContext({
    required this.instance,
    required this.binding,
    required this.now,
    this.privacyEpoch = 0,
    Map<String, int> scopeVersions = const {},
    Iterable<ReadCachePublicIssueProof> publicIssues = const [],
    Set<ReadCacheIssueIdentity> confidentialIssues = const {},
    Set<String> confirmedShas = const {},
    Map<String, int> verifiedProjectAliases = const {},
    Map<(int, int), int> verifiedMergeRequestIds = const {},
    this.terminalJob,
  }) : scopeVersions = Map.unmodifiable(scopeVersions),
       publicIssues = List.unmodifiable(publicIssues),
       confidentialIssues = Set.unmodifiable(confidentialIssues),
       confirmedShas = Set.unmodifiable(confirmedShas),
       verifiedProjectAliases = Map.unmodifiable(verifiedProjectAliases),
       verifiedMergeRequestIds = Map.unmodifiable(verifiedMergeRequestIds);

  final GitLabInstance instance;
  final DiskBinding binding;
  final DateTime now;
  final int privacyEpoch;
  final Map<String, int> scopeVersions;
  final List<ReadCachePublicIssueProof> publicIssues;
  final Set<ReadCacheIssueIdentity> confidentialIssues;
  final Set<String> confirmedShas;
  final Map<String, int> verifiedProjectAliases;

  /// Same-client verified global MR ids, keyed by (projectId, iid).
  final Map<(int, int), int> verifiedMergeRequestIds;
  final ReadCacheTerminalJobProof? terminalJob;

  bool freshPublicIssue(ReadCacheIssueIdentity identity) =>
      !confidentialIssues.contains(identity) &&
      publicIssues.any(
        (proof) =>
            proof.binding == binding &&
            proof.identity == identity &&
            proof.singleIssue &&
            proof.lineage == ReadCacheProofLineage.network &&
            proof.confidential == false &&
            proof.privacyEpoch == privacyEpoch &&
            _fresh(now, proof.fetchedAt) &&
            _versionsCurrent(proof.scopeVersions, scopeVersions, {
              'global',
              'project:${identity.projectId}',
            }),
      );
}

/// Durable identity has no session generation. All semantic query pairs and
/// the logical representation remain in it; only project detail uses aliases.
String? readCacheDurableKey({
  required DiskBinding binding,
  required GitLabInstance instance,
  required Uri uri,
  required String logicalAccept,
  Map<String, int> verifiedProjectAliases = const {},
}) {
  if (!_validRequest(instance, uri) ||
      !_validBinding(binding, instance) ||
      !const {'application/json', 'text/plain'}.contains(logicalAccept)) {
    return null;
  }
  final path = _path(instance, uri);
  final query = {...uri.queryParameters};
  if (path.length >= 2 && path.first == 'projects') {
    if (!_positiveSegment(path[1])) {
      if (path.length != 2) return null;
      final id = verifiedProjectAliases[path[1]];
      if (id == null || id <= 0) return null;
      path[1] = '$id';
    }
    if (path.length == 2) query['license'] = 'true';
  }
  final names = query.keys.toList()..sort();
  return jsonEncode([
    binding.accountKey,
    'GET',
    instance.api(path).path,
    [
      for (final name in names) [name, query[name]!],
    ],
    logicalAccept,
  ]);
}

/// Closed E01-E19 projection. A single unsafe row/guard rejects the response;
/// optional unsafe URLs and invalid colour strings alone are omitted (C2-D2).
ProjectedDiskEntry? projectReadCacheResponse(
  DiskWriteCandidate candidate,
  Object rawValue,
  ReadCacheProjectionContext context,
) {
  try {
    if (!candidate.cacheable ||
        candidate.method != 'GET' ||
        candidate.noStore ||
        !candidate.firstPage ||
        candidate.binding != context.binding ||
        !candidate.lease.isCurrent ||
        candidate.privacyEpoch != context.privacyEpoch ||
        (candidate.bodyKind != ReadCacheBodyKind.page &&
            candidate.next != null) ||
        candidate.fetchedAt.isAfter(context.now) ||
        candidate.responseBytes < 0) {
      return null;
    }
    final key = readCacheDurableKey(
      binding: candidate.binding,
      instance: context.instance,
      uri: candidate.uri,
      logicalAccept: candidate.logicalAccept,
      verifiedProjectAliases: context.verifiedProjectAliases,
    );
    if (key == null) return null;
    final endpoint = _endpoint(candidate, context);
    if (endpoint == null) return null;
    final requiredScopes = endpoint.pinned
        ? const <String>{}
        : {'global', _readScope(candidate, endpoint, context)};
    final limit = endpoint.id == 19
        ? readCacheTerminalLogLimit
        : readCacheEntryLimit;
    if (candidate.responseBytes > limit ||
        (!endpoint.pinned &&
            !_versionsCurrent(candidate.scopeVersions, context.scopeVersions, {
              ...requiredScopes,
              ...candidate.scopeTags,
            }))) {
      return null;
    }
    final identities = <ReadCacheIssueIdentity>{};
    if (endpoint.issueParent case final parent?) {
      if (!context.freshPublicIssue(parent)) return null;
      identities.add(parent);
    }
    Object body;
    if (endpoint.id == 19) {
      body = _terminalLog(rawValue, endpoint, context);
    } else if (candidate.bodyKind == ReadCacheBodyKind.text) {
      final text = rawValue;
      if (text is! String || utf8.decode(utf8.encode(text)) != text) {
        return null;
      }
      body = text;
    } else {
      _scanRaw(rawValue, endpoint.schema, endpoint.page, identities);
      if (endpoint.page) {
        final rows = rawValue;
        if (rows is! List<Object?>) return null;
        final items = <Object>[];
        for (final row in rows) {
          _validateEndpointIdentity(row, endpoint, candidate, context);
          items.add(_project(row, endpoint.schema!, context.instance));
        }
        body = Map<String, Object?>.unmodifiable({
          'items': List<Object>.unmodifiable(items),
          'next': _next(candidate, context.instance)?.toString(),
        });
      } else {
        if (candidate.next != null) return null;
        _validateEndpointIdentity(rawValue, endpoint, candidate, context);
        body = _project(rawValue, endpoint.schema!, context.instance);
      }
      _checkProjectedBounds(body);
    }
    ProjectedDiskEntry entry(Object value) => ProjectedDiskEntry(
      accountKey: candidate.binding.accountKey,
      canonicalKey: key,
      cacheClass: endpoint.cacheClass,
      bodyKind: candidate.bodyKind,
      fetchedAt: candidate.fetchedAt,
      body: value,
      privacyEpoch: candidate.privacyEpoch,
      issueIdentities: identities,
      scopeTags: endpoint.pinned
          ? const {}
          : {...requiredScopes, ...candidate.scopeTags},
      scopeVersions: endpoint.pinned ? const {} : candidate.scopeVersions,
    );
    var result = entry(body);
    // Only terminal tails may be truncated. Recompute metadata after changing
    // offsets: decimal widths and canonicalKey bytes consume the same cap.
    while (result.serializedLength > limit && body is ReadCacheTerminalLog) {
      var drop = result.serializedLength - limit;
      if (drop >= body.bytes.length) return null;
      while (drop < body.bytes.length && body.bytes[drop] & 0xc0 == 0x80) {
        drop++;
      }
      if (drop >= body.bytes.length) return null;
      body = ReadCacheTerminalLog(
        projectId: body.projectId,
        jobId: body.jobId,
        finishedAt: body.finishedAt,
        startOffset: body.startOffset + drop,
        nextOffset: body.nextOffset,
        totalBytes: body.totalBytes,
        isEof: body.isEof,
        truncated: true,
        bytes: body.bytes.sublist(drop),
      );
      result = entry(body);
    }
    if (result.serializedLength > limit ||
        !candidate.lease.isCurrent ||
        identities.any(context.confidentialIssues.contains)) {
      return null;
    }
    return result;
  } on _InvalidProjection {
    return null;
  } on FormatException {
    return null;
  }
}

bool _fresh(DateTime now, DateTime fetchedAt) {
  final age = now.difference(fetchedAt);
  return !age.isNegative && age < const Duration(seconds: 30);
}

bool _versionsCurrent(
  Map<String, int> snapshot,
  Map<String, int> current,
  Set<String> requiredScopes,
) =>
    requiredScopes.every(snapshot.containsKey) &&
    snapshot.entries.every(
      (entry) =>
          entry.value >= 0 &&
          current.containsKey(entry.key) &&
          entry.value == current[entry.key],
    );

String _readScope(
  DiskWriteCandidate candidate,
  _Endpoint endpoint,
  ReadCacheProjectionContext context,
) {
  if (endpoint.project != null) return 'project:${endpoint.project}';
  final path = _path(context.instance, candidate.uri);
  if (path.first == 'groups') return 'groupWorkItems';
  return path.first == 'projects' ? 'projectLists' : 'userLists';
}

bool _validBinding(DiskBinding binding, GitLabInstance instance) {
  final prefix = '${instance.key}#';
  return binding.generation >= 0 &&
      binding.accountKey.startsWith(prefix) &&
      _positiveSegment(binding.accountKey.substring(prefix.length));
}

final _positiveId = RegExp(r'^[1-9][0-9]*$');
final _sha = RegExp(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})$');
final _colour = RegExp(r'^#(?:[0-9A-Fa-f]{3}){1,2}$');
final _sensitiveQuery = RegExp(
  r'token|secret|password|authorization|credential|signature|api[_-]?key|jwt',
  caseSensitive: false,
);
// Pagination cursors (`id_after`, ...) and search (with its `search_in`
// modifier) are never admitted, so neither appears here.
const _semanticQueryKeys = {
  'per_page',
  'scope',
  'state',
  'order_by',
  'sort',
  'with_labels_details',
  'labels',
  'not[labels]',
  'assignee_id',
  'not[assignee_id]',
  'author_id',
  'not[author_id]',
  'reviewer_id',
  'milestone',
  'milestone_id',
  'weight',
  'due_date',
  'created_after',
  'created_before',
  'updated_after',
  'updated_before',
  'confidential',
  'include_subgroups',
  'non_archived',
  'iids[]',
  'iid',
  'epic_id',
  'iteration_id',
  'iteration_title',
  'my_reaction_emoji',
  'with_merge_status_recheck',
  'wip',
  'draft',
  'source_branch',
  'target_branch',
  'source_project_id',
  'target_project_id',
  'approver_ids[]',
  'approved_by_ids[]',
  'merge_user_id',
  'membership',
  'starred',
  'simple',
  'owned',
  'archived',
  'visibility',
  'min_access_level',
  'id_before',
  'last_activity_after',
  'last_activity_before',
  'with_issues_enabled',
  'with_merge_requests_enabled',
  'with_programming_language',
  'topic',
  'topic_id',
  'license',
  'statistics',
  'with_custom_attributes',
  'imported',
  'include_hidden',
  'repository_checksum_failed',
  'wiki_checksum_failed',
  'ref',
  'path',
  'recursive',
};

bool _positiveSegment(String value) =>
    _positiveId.hasMatch(value) && int.tryParse(value) != null;

bool _safeSegments(Uri uri) =>
    !uri.path.contains('//') &&
    !RegExp(r'%(?:2e|5c)', caseSensitive: false).hasMatch(uri.path) &&
    uri.pathSegments.every(
      (segment) =>
          segment.isNotEmpty &&
          !segment.contains(RegExp(r'[\x00-\x1f\x7f\\%?#]')) &&
          !segment
              .split('/')
              .any((part) => part.isEmpty || part == '.' || part == '..'),
    );

bool _validRequest(GitLabInstance instance, Uri uri) =>
    instance.allowsApi(uri) &&
    _safeSegments(uri) &&
    uri.queryParametersAll.values.every((values) => values.length == 1) &&
    uri.queryParameters.entries.every(
      (entry) =>
          !_sensitiveQuery.hasMatch(entry.key) &&
          !paginationKeys.contains(entry.key.toLowerCase()) &&
          _semanticQueryKeys.contains(entry.key) &&
          !entry.value.contains(RegExp(r'[\x00-\x1f\x7f]')),
    );

List<String> _path(GitLabInstance instance, Uri uri) => uri.pathSegments
    .skip(instance.base.pathSegments.where((s) => s.isNotEmpty).length + 2)
    .toList();

Uri? _next(DiskWriteCandidate candidate, GitLabInstance instance) {
  final supplied = candidate.next;
  if (supplied == null) return null;
  // Resolution removes relative dot segments, so reject them first.
  if (!_safeSegments(supplied)) throw const _InvalidProjection();
  final uri = supplied.hasScheme
      ? supplied
      : candidate.uri.resolveUri(supplied);
  if (!instance.allowsApi(uri) ||
      !_safeSegments(uri) ||
      uri.queryParametersAll.values.any((values) => values.length != 1) ||
      uri.queryParameters.keys.any(
        (key) =>
            _sensitiveQuery.hasMatch(key) ||
            (!paginationKeys.contains(key) &&
                !_semanticQueryKeys.contains(key)),
      )) {
    throw const _InvalidProjection();
  }
  // The existing validator binds the endpoint and original non-pagination
  // query and rejects a non-progressing cursor. Store its normalized URI.
  return checkedPageUri(instance, candidate.uri, uri);
}

final class _Endpoint {
  const _Endpoint(
    this.id,
    this.schema,
    this.cacheClass, {
    this.page = false,
    this.project,
    this.resource,
    this.child,
    this.issueParent,
  });
  final int id;
  final _Schema? schema;
  final ReadCacheDiskClass cacheClass;
  final bool page;
  final int? project, resource;
  final String? child;
  final ReadCacheIssueIdentity? issueParent;
  bool get pinned => cacheClass == ReadCacheDiskClass.pinned;
}

_Endpoint? _endpoint(
  DiskWriteCandidate candidate,
  ReadCacheProjectionContext c,
) {
  final p = _path(c.instance, candidate.uri);
  final page = candidate.bodyKind == ReadCacheBodyKind.page;
  final json = candidate.bodyKind == ReadCacheBodyKind.json;
  final accept = candidate.logicalAccept;
  if (p.isEmpty ||
      ((json || page) && accept != 'application/json') ||
      ((!json && !page) && accept != 'text/plain')) {
    return null;
  }
  _Endpoint? result;
  if (p.length == 1) {
    if (p[0] == 'projects' && page) {
      result = _Endpoint(
        1,
        _projectSchema,
        ReadCacheDiskClass.list,
        page: true,
      );
    } else if (p[0] == 'issues' && page) {
      result = _Endpoint(2, _issue, ReadCacheDiskClass.list, page: true);
    } else if (p[0] == 'merge_requests' && page) {
      result = _Endpoint(9, _mr, ReadCacheDiskClass.list, page: true);
    }
  } else if (p[0] == 'groups' &&
      p.length == 3 &&
      _positiveSegment(p[1]) &&
      page) {
    if (p[2] == 'issues' || p[2] == 'merge_requests') {
      result = _Endpoint(
        p[2] == 'issues' ? 2 : 9,
        p[2] == 'issues' ? _issue : _mr,
        ReadCacheDiskClass.list,
        page: true,
      );
    }
  } else if (p[0] == 'projects' && p.length == 2 && json) {
    if (candidate.uri.queryParameters['license'] != 'true') return null;
    final id = _positiveSegment(p[1])
        ? int.parse(p[1])
        : c.verifiedProjectAliases[p[1]];
    if (id != null) {
      result = _Endpoint(
        1,
        _projectSchema,
        ReadCacheDiskClass.projectMeta,
        project: id,
      );
    }
  } else if (p[0] == 'projects' && p.length >= 3 && _positiveSegment(p[1])) {
    final project = int.parse(p[1]);
    if (p[2] == 'issues' || p[2] == 'merge_requests') {
      final issue = p[2] == 'issues';
      if (p.length == 3 && page) {
        result = _Endpoint(
          issue ? 2 : 9,
          issue ? _issue : _mr,
          ReadCacheDiskClass.list,
          page: true,
          project: project,
        );
      } else if (p.length >= 4 && _positiveSegment(p[3])) {
        final resource = int.parse(p[3]);
        final parent = issue ? ReadCacheIssueIdentity(project, resource) : null;
        if (p.length == 4 && json) {
          result = _Endpoint(
            issue ? 3 : 10,
            issue ? _issue : _mr,
            ReadCacheDiskClass.detail,
            project: project,
            resource: resource,
          );
        } else if ((p.length == 5 && page) || (p.length == 6 && json)) {
          final sub = p[4];
          if (sub == 'notes' && (p.length == 5 || _positiveSegment(p[5]))) {
            result = _Endpoint(
              issue ? 4 : 12,
              _note,
              ReadCacheDiskClass.thread,
              page: page,
              project: project,
              resource: resource,
              child: p.length == 6 ? p[5] : null,
              issueParent: parent,
            );
          } else if (sub == 'discussions') {
            result = _Endpoint(
              issue ? 5 : 13,
              _discussion,
              ReadCacheDiskClass.thread,
              page: page,
              project: project,
              resource: resource,
              child: p.length == 6 ? p[5] : null,
              issueParent: parent,
            );
          } else if (p.length == 5 && issue && page) {
            if (sub == 'award_emoji' ||
                sub == 'related_merge_requests' ||
                sub == 'links') {
              result = _Endpoint(
                sub == 'award_emoji'
                    ? 6
                    : sub == 'links'
                    ? 8
                    : 7,
                sub == 'award_emoji'
                    ? _emoji
                    : sub == 'links'
                    ? _linkedIssue
                    : _relatedMr,
                ReadCacheDiskClass.thread,
                page: true,
                project: project,
                resource: resource,
                issueParent: parent,
              );
            }
          }
        }
        if (!issue && p.length == 5 && p[4] == 'approvals' && json) {
          result = _Endpoint(
            11,
            _approvals,
            ReadCacheDiskClass.thread,
            project: project,
            resource: resource,
          );
        }
        if (!issue &&
            p.length == 6 &&
            p[4] == 'versions' &&
            _positiveSegment(p[5]) &&
            json &&
            candidate.typedPinned) {
          result = _Endpoint(
            18,
            _mrVersion,
            ReadCacheDiskClass.pinned,
            project: project,
            resource: resource,
            child: p[5],
          );
        }
      }
    } else if (p.length == 4 && json && _positiveSegment(p[3])) {
      if (p[2] == 'pipelines' || p[2] == 'jobs') {
        result = _Endpoint(
          p[2] == 'pipelines' ? 14 : 15,
          p[2] == 'pipelines' ? _pipeline : _job,
          ReadCacheDiskClass.detail,
          project: project,
          resource: int.parse(p[3]),
        );
      }
    } else if (p[2] == 'repository' && p.length >= 4) {
      final ref = candidate.uri.queryParameters['ref'];
      if (ref != null && _sha.hasMatch(ref) && c.confirmedShas.contains(ref)) {
        if (p.length == 4 && p[3] == 'tree' && page) {
          result = _Endpoint(
            16,
            _tree,
            ReadCacheDiskClass.pinned,
            page: true,
            project: project,
          );
        } else if (p[3] == 'files' &&
            // C2-D5: the app's text read is the same files path keyed by a
            // text/plain Accept; the /raw variant stays admissible for it.
            ((p.length == 5 &&
                    (json ||
                        candidate.bodyKind == ReadCacheBodyKind.text)) ||
                (p.length == 6 &&
                    p[5] == 'raw' &&
                    candidate.bodyKind == ReadCacheBodyKind.text))) {
          result = _Endpoint(
            17,
            json ? _file : null,
            ReadCacheDiskClass.pinned,
            project: project,
            child: p[4],
          );
        }
      }
    } else if (p.length == 5 &&
        p[2] == 'jobs' &&
        _positiveSegment(p[3]) &&
        p[4] == 'trace' &&
        candidate.bodyKind == ReadCacheBodyKind.terminalLog &&
        candidate.typedPinned &&
        candidate.uri.queryParameters.isEmpty) {
      result = _Endpoint(
        19,
        null,
        ReadCacheDiskClass.pinned,
        project: project,
        resource: int.parse(p[3]),
      );
    }
  }
  return result;
}

void _validateEndpointIdentity(
  Object? value,
  _Endpoint e,
  DiskWriteCandidate candidate,
  ReadCacheProjectionContext context,
) {
  if (value is! Map<String, Object?>) throw const _InvalidProjection();
  void matches(String key, Object? expected, {bool required = false}) {
    if ((required || value.containsKey(key)) && value[key] != expected) {
      throw const _InvalidProjection();
    }
  }

  if (e.id == 1) {
    final deletion = value['marked_for_deletion_on'];
    if (deletion != null && deletion != '') throw const _InvalidProjection();
    if (!e.page) {
      matches('id', e.project, required: true);
      final requested = _path(context.instance, candidate.uri)[1];
      if (!_positiveSegment(requested)) {
        matches('path_with_namespace', requested, required: true);
      }
    }
  }
  if (const {2, 3, 9, 10}.contains(e.id)) {
    if (e.project != null) matches('project_id', e.project, required: true);
    if (e.resource != null) matches('iid', e.resource, required: true);
  }
  if (const {4, 12}.contains(e.id) && e.child != null) {
    matches('id', int.parse(e.child!), required: true);
  }
  if (const {5, 13}.contains(e.id) && e.child != null) {
    matches('id', e.child, required: true);
  }
  if (e.id == 11) {
    matches('project_id', e.project);
    matches('iid', e.resource);
    // A route iid cannot establish the global MR id returned by approvals.
    if (value.containsKey('id')) {
      final expected =
          context.verifiedMergeRequestIds[(e.project!, e.resource!)];
      if (expected == null || expected <= 0) throw const _InvalidProjection();
      matches('id', expected);
    }
  }
  if (e.id == 14) {
    matches('id', e.resource, required: true);
    matches('project_id', e.project, required: true);
  }
  if (e.id == 15) {
    matches('id', e.resource, required: true);
    final pipeline = value['pipeline'];
    if (pipeline is Map<String, Object?> &&
        pipeline.containsKey('project_id') &&
        pipeline['project_id'] != e.project) {
      throw const _InvalidProjection();
    }
  }
  if (e.id == 17) {
    matches('file_path', e.child, required: true);
    matches('ref', candidate.uri.queryParameters['ref'], required: true);
    matches('encoding', 'base64', required: true);
    final content = value['content'];
    if (content is! String) throw const _InvalidProjection();
    final decoded = base64.decode(content);
    if (decoded.length > readCacheEntryLimit ||
        value['size'] != decoded.length) {
      throw const _InvalidProjection();
    }
    utf8.decode(decoded, allowMalformed: false);
  }
  if (e.id == 18) matches('id', int.parse(e.child!), required: true);
}

ReadCacheTerminalLog _terminalLog(
  Object value,
  _Endpoint e,
  ReadCacheProjectionContext c,
) {
  final proof = c.terminalJob;
  if (value is! ReadCacheTerminalLog ||
      proof == null ||
      proof.binding != c.binding ||
      proof.projectId != e.project ||
      proof.jobId != e.resource ||
      proof.lineage != ReadCacheProofLineage.network ||
      proof.erased ||
      !_fresh(c.now, proof.fetchedAt) ||
      !const {
        'success',
        'failed',
        'canceled',
        'skipped',
      }.contains(proof.status) ||
      proof.finishedAt.isAfter(c.now) ||
      value.projectId != e.project ||
      value.jobId != e.resource ||
      value.finishedAt != proof.finishedAt ||
      value.startOffset < 0 ||
      value.nextOffset < value.startOffset ||
      value.nextOffset != value.totalBytes ||
      !value.isEof ||
      value.bytes.length != value.nextOffset - value.startOffset ||
      value.truncated != (value.startOffset > 0)) {
    throw const _InvalidProjection();
  }
  utf8.decode(value.bytes, allowMalformed: false);
  return value;
}

final class _InvalidProjection implements Exception {
  const _InvalidProjection();
}

void _checkProjectedBounds(Object root) {
  var nodes = 0;
  void visit(Object? value, int depth) {
    if (++nodes > readCacheMaxValueNodes || depth > readCacheMaxDepth) {
      throw const _InvalidProjection();
    }
    if (value is List<Object?>) {
      if (value.length > readCacheMaxArrayLength) {
        throw const _InvalidProjection();
      }
      for (final child in value) {
        visit(child, depth + 1);
      }
    } else if (value is Map<String, Object?>) {
      for (final child in value.values) {
        visit(child, depth + 1);
      }
    }
  }

  visit(root, 1);
}

enum _Type {
  string,
  integer,
  number,
  boolean,
  time,
  sha,
  url,
  colour,
  object,
  array,
  labels,
}

final class _Field {
  const _Field(this.type, {this.schema, this.nullable = false});
  final _Type type;
  final _Schema? schema;
  final bool nullable;
}

final class _Schema {
  const _Schema(
    this.fields, {
    this.required = const {},
    this.issue = false,
    this.note = false,
    this.name = '',
    this.walkHints = const {},
  });
  final Map<String, _Field> fields;
  final Set<String> required;
  final bool issue, note;
  final String name;

  /// Raw-walker-only hints for GitLab objects that projection strips. They
  /// never reach [_project], so they add no projected key to §3.
  final Map<String, _Schema> walkHints;
}

Map<String, _Field> _fields(
  _Type type,
  String names, {
  bool nullable = false,
}) => {
  for (final name in names.split(' ')) name: _Field(type, nullable: nullable),
};

final _actor = _Schema(
  {
    ..._fields(_Type.integer, 'id'),
    ..._fields(_Type.string, 'username name'),
    ..._fields(_Type.url, 'avatar_url web_url', nullable: true),
  },
  required: {'id', 'username', 'name'},
);
final _label = _Schema(
  {
    'id': const _Field(_Type.integer),
    'name': const _Field(_Type.string),
    ..._fields(_Type.colour, 'color text_color'),
  },
  required: {'name', 'color'},
);
final _references = _Schema(_fields(_Type.string, 'short relative full'));
final _license = _Schema(_fields(_Type.string, 'name key'));
final _namespace = _Schema({
  'id': const _Field(_Type.integer),
  ..._fields(_Type.string, 'name full_path kind'),
});
final _projectSchema = _Schema(
  {
    ..._fields(_Type.integer, 'id star_count forks_count open_issues_count'),
    ..._fields(_Type.string, 'name path_with_namespace visibility'),
    ..._fields(_Type.string, 'description default_branch', nullable: true),
    'last_activity_at': const _Field(_Type.time, nullable: true),
    'license': _Field(_Type.object, schema: _license, nullable: true),
    ..._fields(_Type.url, 'web_url avatar_url', nullable: true),
    'archived': const _Field(_Type.boolean),
    'namespace': _Field(_Type.object, schema: _namespace),
  },
  required: {'id', 'name', 'path_with_namespace'},
  name: 'project',
);
final _milestone = _Schema(
  {
    ..._fields(_Type.integer, 'id iid'),
    ..._fields(_Type.string, 'title state'),
    'due_date': const _Field(_Type.time, nullable: true),
  },
  required: {'id', 'iid', 'title'},
  name: 'milestone',
);
final _timeStats = _Schema({
  ..._fields(_Type.integer, 'time_estimate total_time_spent'),
  ..._fields(
    _Type.string,
    'human_time_estimate human_total_time_spent',
    nullable: true,
  ),
});
final _completion = _Schema(_fields(_Type.integer, 'count completed_count'));

// Known GitLab non-issue objects, used only by the raw walker. Their keys are
// all scalars (PipelineBasic: id iid project_id sha ref status source
// created_at updated_at web_url; EpicBase: id iid title url group_id ...;
// Iteration: id iid sequence group_id title ...), so no field hints: a nested
// object inside them is still unknown. A `confidential` key or Issue `type`
// keeps the issue guard, and a value that is not an object/null rejects.
const _pipelineBasicWalk = _Schema({}, name: 'pipelineBasic');
const _epicWalk = _Schema({}, name: 'epic');
const _iterationWalk = _Schema({}, name: 'iteration');
const _issueWalkHints = {'epic': _epicWalk, 'iteration': _iterationWalk};
const _mrWalkHints = {'pipeline': _pipelineBasicWalk};

Map<String, _Field> get _workItemFields => {
  ..._fields(
    _Type.integer,
    'id iid project_id user_notes_count upvotes downvotes',
  ),
  ..._fields(_Type.string, 'title state'),
  'description': const _Field(_Type.string, nullable: true),
  'references': _Field(_Type.object, schema: _references),
  ..._fields(_Type.time, 'created_at updated_at'),
  'closed_at': const _Field(_Type.time, nullable: true),
  'web_url': const _Field(_Type.url),
  'author': _Field(_Type.object, schema: _actor),
  'assignee': _Field(_Type.object, schema: _actor, nullable: true),
  'assignees': _Field(_Type.array, schema: _actor),
  'labels': const _Field(_Type.labels),
  'milestone': _Field(_Type.object, schema: _milestone, nullable: true),
  'time_stats': _Field(_Type.object, schema: _timeStats),
};
final _issue = _Schema(
  {
    ..._workItemFields,
    'confidential': const _Field(_Type.boolean),
    'due_date': const _Field(_Type.time, nullable: true),
    'task_completion_status': _Field(_Type.object, schema: _completion),
  },
  required: {'id', 'iid', 'project_id', 'title', 'confidential'},
  issue: true,
  name: 'issue',
  walkHints: _issueWalkHints,
);
final _diffRefs = _Schema(_fields(_Type.sha, 'base_sha head_sha start_sha'));
final _headPipeline = _Schema({
  'id': const _Field(_Type.integer),
  'status': const _Field(_Type.string),
});
final _mr = _Schema(
  {
    ..._workItemFields,
    'merge_user': _Field(_Type.object, schema: _actor, nullable: true),
    ..._fields(
      _Type.boolean,
      'merge_when_pipeline_succeeds auto_merge_enabled draft work_in_progress rebase_in_progress has_conflicts',
    ),
    'merged_at': const _Field(_Type.time, nullable: true),
    ..._fields(
      _Type.string,
      'source_branch target_branch merge_status detailed_merge_status changes_count',
    ),
    ..._fields(
      _Type.integer,
      'source_project_id target_project_id diverged_commits_count',
    ),
    'sha': const _Field(_Type.sha),
    'diff_refs': _Field(_Type.object, schema: _diffRefs, nullable: true),
    'reviewers': _Field(_Type.array, schema: _actor),
    'head_pipeline': _Field(
      _Type.object,
      schema: _headPipeline,
      nullable: true,
    ),
  },
  required: {'id', 'iid', 'project_id', 'title'},
  name: 'mr',
  walkHints: _mrWalkHints,
);
// C2-D4: one of old_line/new_line is null on every added or removed line,
// and type may be absent; all are display-only.
final _positionLine = _Schema({
  ..._fields(_Type.string, 'line_code'),
  ..._fields(_Type.string, 'type', nullable: true),
  ..._fields(_Type.integer, 'old_line new_line', nullable: true),
});
final _lineRange = _Schema({
  'start': _Field(_Type.object, schema: _positionLine),
  'end': _Field(_Type.object, schema: _positionLine),
});
final _position = _Schema({
  ..._fields(_Type.string, 'position_type old_path new_path'),
  ..._fields(_Type.sha, 'base_sha start_sha head_sha'),
  ..._fields(_Type.integer, 'old_line new_line', nullable: true),
  'line_range': _Field(_Type.object, schema: _lineRange, nullable: true),
});
final _note = _Schema(
  {
    ..._fields(_Type.integer, 'id noteable_id noteable_iid'),
    ..._fields(_Type.string, 'body noteable_type'),
    ..._fields(_Type.time, 'created_at updated_at'),
    ..._fields(
      _Type.boolean,
      'system internal confidential resolvable resolved',
    ),
    'author': _Field(_Type.object, schema: _actor),
    'resolved_by': _Field(_Type.object, schema: _actor, nullable: true),
    'position': _Field(_Type.object, schema: _position, nullable: true),
  },
  required: {'id', 'body'},
  note: true,
  name: 'note',
);
final _discussion = _Schema(
  {
    'id': const _Field(_Type.string),
    'individual_note': const _Field(_Type.boolean),
    'notes': _Field(_Type.array, schema: _note),
  },
  required: {'id', 'individual_note', 'notes'},
  name: 'discussion',
);
final _emoji = _Schema(
  {
    'id': const _Field(_Type.integer),
    'name': const _Field(_Type.string),
    'user': _Field(_Type.object, schema: _actor),
    ..._fields(_Type.time, 'created_at updated_at'),
  },
  required: {'id', 'name', 'user'},
);
final _linkedIssue = _Schema(
  {
    ..._issue.fields,
    'issue_link_id': const _Field(_Type.integer),
    'link_type': const _Field(_Type.string),
  },
  required: _issue.required,
  issue: true,
  name: 'issue',
  walkHints: _issueWalkHints,
);
final _relatedMr = _Schema(
  {
    ..._mr.fields,
    for (final name in ['issues', 'closes_issues', 'related_issues'])
      name: _Field(_Type.array, schema: _issue),
  },
  required: _mr.required,
  name: 'mr',
  walkHints: _mrWalkHints,
);
final _approvedBy = _Schema(
  {'user': _Field(_Type.object, schema: _actor)},
  required: {'user'},
);
final _approvals = _Schema(
  {
    ..._fields(
      _Type.integer,
      'id iid project_id approvals_required approvals_left',
    ),
    'approved_by': _Field(_Type.array, schema: _approvedBy),
  },
  required: {'approved_by'},
  name: 'approvals',
);
final _pipelineFields = <String, _Field>{
  ..._fields(_Type.integer, 'id iid project_id'),
  ..._fields(_Type.string, 'status ref'),
  'sha': const _Field(_Type.sha),
};
final _jobPipeline = _Schema(
  _pipelineFields,
  required: {'id'},
  name: 'pipeline',
);
final _pipeline = _Schema(
  {
    ..._pipelineFields,
    // C2-D4: no workflow:name means GitLab answers "name": null.
    'name': const _Field(_Type.string, nullable: true),
    ..._fields(_Type.string, 'source'),
    'web_url': const _Field(_Type.url),
    ..._fields(_Type.time, 'created_at updated_at'),
    ..._fields(_Type.time, 'started_at finished_at', nullable: true),
    ..._fields(_Type.number, 'duration queued_duration', nullable: true),
    'user': _Field(_Type.object, schema: _actor),
  },
  required: {'id', 'project_id', 'status'},
  name: 'pipeline',
);
final _artifacts = _Schema({
  'filename': const _Field(_Type.string),
  'size': const _Field(_Type.integer),
});
final _job = _Schema(
  {
    ..._fields(_Type.integer, 'id'),
    ..._fields(_Type.string, 'name status stage ref'),
    'created_at': const _Field(_Type.time),
    ..._fields(_Type.time, 'started_at finished_at erased_at', nullable: true),
    ..._fields(_Type.number, 'duration queued_duration', nullable: true),
    'failure_reason': const _Field(_Type.string, nullable: true),
    'web_url': const _Field(_Type.url),
    'user': _Field(_Type.object, schema: _actor),
    'pipeline': _Field(_Type.object, schema: _jobPipeline),
    'artifacts_file': _Field(_Type.object, schema: _artifacts),
  },
  required: {'id', 'name', 'status'},
  name: 'job',
);
final _tree = _Schema(
  _fields(_Type.string, 'id name type path mode'),
  required: {'name', 'type', 'path'},
);
final _file = _Schema(
  {
    ..._fields(_Type.string, 'file_name file_path encoding content'),
    ..._fields(
      _Type.sha,
      'content_sha256 ref blob_id commit_id last_commit_id',
    ),
    'size': const _Field(_Type.integer),
    'execute_filemode': const _Field(_Type.boolean),
  },
  required: {'file_name', 'file_path', 'encoding', 'content', 'ref', 'size'},
);
final _diff = _Schema(
  {
    ..._fields(_Type.string, 'old_path new_path a_mode b_mode diff'),
    ..._fields(
      _Type.boolean,
      'new_file renamed_file deleted_file generated_file collapsed too_large',
    ),
  },
  required: {'old_path', 'new_path'},
);
final _mrVersion = _Schema(
  {
    'id': const _Field(_Type.integer),
    'created_at': const _Field(_Type.time),
    ..._fields(_Type.sha, 'base_commit_sha start_commit_sha head_commit_sha'),
    ..._fields(_Type.string, 'state real_size'),
    'diffs': _Field(_Type.array, schema: _diff),
  },
  required: {
    'id',
    'base_commit_sha',
    'start_commit_sha',
    'head_commit_sha',
    'diffs',
  },
);

/// Walk the original, including fields that projection will remove. Schema
/// hints (and walker-only hints for stripped GitLab objects such as an MR's
/// PipelineBasic or an Issue's epic/iteration) distinguish non-issue
/// identities from embedded Issues; any other `iid` object stays suspect.
void _scanRaw(
  Object root,
  _Schema? schema,
  bool page,
  Set<ReadCacheIssueIdentity> identities,
) {
  var nodes = 0;
  void walk(
    Object? value,
    _Schema? hint,
    int depth, {
    bool list = false,
    bool issueNamed = false,
  }) {
    if (++nodes > readCacheMaxValueNodes || depth > readCacheMaxDepth) {
      throw const _InvalidProjection();
    }
    if (value is List<Object?>) {
      if (value.length > readCacheMaxArrayLength) {
        throw const _InvalidProjection();
      }
      for (final item in value) {
        if ((list || issueNamed) && item is! Map<String, Object?>) {
          throw const _InvalidProjection();
        }
        walk(item, hint, depth + 1, issueNamed: issueNamed);
      }
    } else if (value is Map<String, Object?>) {
      final namedIssue = issueNamed || hint?.issue == true;
      final looksIssue =
          (value.containsKey('confidential') && hint?.note != true) ||
          (hint == null &&
              (value.containsKey('iid') ||
                  (value.containsKey('project_id') &&
                      value.containsKey('title')))) ||
          _issueType(value['type']);
      if (namedIssue || looksIssue) {
        _requirePositive(value['project_id']);
        _requirePositive(value['iid']);
        if (value['confidential'] != false) throw const _InvalidProjection();
        identities.add(
          ReadCacheIssueIdentity(
            value['project_id']! as int,
            value['iid']! as int,
          ),
        );
      }
      if (hint?.note == true) _validateNote(value);
      if (_issueType(value['target_type']) &&
          value['target'] is! Map<String, Object?>) {
        throw const _InvalidProjection();
      }
      for (final entry in value.entries) {
        final field = hint?.fields[entry.key];
        final walkOnly = field == null ? hint?.walkHints[entry.key] : null;
        if (walkOnly != null &&
            entry.value != null &&
            entry.value is! Map<String, Object?>) {
          throw const _InvalidProjection();
        }
        final key = entry.key.toLowerCase();
        final issueKey =
            const {
              'issue',
              'issues',
              'linked_issue',
              'linked_issues',
              'related_issues',
              'closes_issues',
              'blocking_issues',
              'blocked_issues',
            }.contains(key) ||
            (key == 'target' && _issueType(value['target_type']));
        if (issueKey &&
            entry.value is! Map<String, Object?> &&
            entry.value is! List<Object?>) {
          throw const _InvalidProjection();
        }
        walk(
          entry.value,
          field?.schema ?? walkOnly,
          depth + 1,
          list: field?.type == _Type.array,
          issueNamed: issueKey,
        );
      }
    } else if (value != null &&
        value is! String &&
        value is! bool &&
        value is! int &&
        (value is! double || !value.isFinite)) {
      throw const _InvalidProjection();
    }
  }

  walk(root, schema, 1, list: page);
}

void _requirePositive(Object? value) {
  if (value is! int || value <= 0) throw const _InvalidProjection();
}

bool _issueType(Object? value) =>
    value is String && value.toLowerCase() == 'issue';

void _validateNote(Map<String, Object?> value) {
  if (value.containsKey('internal')) {
    if (value['internal'] != false) throw const _InvalidProjection();
  } else if (value['confidential'] != false) {
    throw const _InvalidProjection();
  }
  if (value.containsKey('confidential') && value['confidential'] is! bool) {
    throw const _InvalidProjection();
  }
  if (value['confidential'] == true) throw const _InvalidProjection();
}

Map<String, Object?> _project(
  Object? raw,
  _Schema schema,
  GitLabInstance instance,
) {
  if (raw is! Map<String, Object?> ||
      schema.required.any((name) => !raw.containsKey(name))) {
    throw const _InvalidProjection();
  }
  if (schema.issue) {
    _requirePositive(raw['project_id']);
    _requirePositive(raw['iid']);
    if (raw['confidential'] != false) throw const _InvalidProjection();
  }
  if (schema.note) _validateNote(raw);
  final output = <String, Object?>{};
  for (final entry in schema.fields.entries) {
    if (!raw.containsKey(entry.key)) continue;
    final value = raw[entry.key], field = entry.value;
    if (value == null) {
      if (!field.nullable) throw const _InvalidProjection();
      output[entry.key] = null;
      continue;
    }
    Object? projected;
    switch (field.type) {
      case _Type.string:
        if (value is! String ||
            (schema.required.contains(entry.key) && value.isEmpty)) {
          throw const _InvalidProjection();
        }
        projected = value;
      case _Type.integer:
        if (value is! int) throw const _InvalidProjection();
        if (const {
          'id',
          'iid',
          'project_id',
          'noteable_id',
          'noteable_iid',
          'source_project_id',
          'target_project_id',
          'issue_link_id',
        }.contains(entry.key)) {
          _requirePositive(value);
        }
        projected = value;
      case _Type.number:
        if (value is! num || !value.isFinite) throw const _InvalidProjection();
        projected = value;
      case _Type.boolean:
        if (value is! bool) throw const _InvalidProjection();
        projected = value;
      case _Type.time:
        if (value is! String || !_isoDate(value)) {
          throw const _InvalidProjection();
        }
        projected = value;
      case _Type.sha:
        if (value is! String || !_sha.hasMatch(value)) {
          throw const _InvalidProjection();
        }
        projected = value;
      case _Type.url:
        if (value is! String) throw const _InvalidProjection();
        if (!_safeUrl(value, instance)) continue;
        projected = value;
      case _Type.colour:
        if (value is! String) throw const _InvalidProjection();
        if (!_colour.hasMatch(value)) continue;
        projected = value;
      case _Type.object:
        projected = _project(value, field.schema!, instance);
      case _Type.array:
        if (value is! List<Object?>) throw const _InvalidProjection();
        projected = List<Object>.unmodifiable([
          for (final item in value) _project(item, field.schema!, instance),
        ]);
      case _Type.labels:
        if (value is! List<Object?>) throw const _InvalidProjection();
        if (value.every((item) => item is String)) {
          projected = List<String>.unmodifiable(value.cast<String>());
        } else if (value.every((item) => item is Map<String, Object?>)) {
          projected = List<Object>.unmodifiable([
            for (final item in value) _project(item, _label, instance),
          ]);
        } else {
          throw const _InvalidProjection();
        }
    }
    output[entry.key] = projected;
  }
  return Map.unmodifiable(output);
}

bool _safeUrl(String value, GitLabInstance instance) {
  if (RegExp(r'[\x00-\x20\x7f\\]').hasMatch(value) ||
      RegExp(
        r'(?:^|/)\.{1,2}(?:/|$)|%(?:2e|5c|2f)',
        caseSensitive: false,
      ).hasMatch(value)) {
    return false;
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !instance.sameOrigin(uri) ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.path.contains('\\') ||
      uri.path.contains('//')) {
    return false;
  }
  final prefix = instance.base.pathSegments.where((s) => s.isNotEmpty).toList();
  return uri.pathSegments.length >= prefix.length &&
      List.generate(
        prefix.length,
        (i) => uri.pathSegments[i] == prefix[i],
      ).every((same) => same);
}

bool _isoDate(String value) {
  if (!RegExp(
    r'^\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2}))?$',
  ).hasMatch(value)) {
    return false;
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return false;
  final date = DateTime.utc(
    int.parse(value.substring(0, 4)),
    int.parse(value.substring(5, 7)),
    int.parse(value.substring(8, 10)),
  );
  if (date.toIso8601String().substring(0, 10) != value.substring(0, 10)) {
    return false;
  }
  if (value.length > 10 &&
      !value.endsWith('Z') &&
      (int.parse(value.substring(value.length - 5, value.length - 3)) >= 24 ||
          int.parse(value.substring(value.length - 2)) >= 60)) {
    return false;
  }
  return value.length == 10 ||
      (int.parse(value.substring(11, 13)) < 24 &&
          int.parse(value.substring(14, 16)) < 60 &&
          int.parse(value.substring(17, 19)) < 60);
}
