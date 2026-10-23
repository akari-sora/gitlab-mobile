import '../../instance.dart';
import '../intent_lexicon.dart';
import 'write_ledger.dart';

enum AiTargetKind {
  project,
  issue,
  mergeRequest,
  groupWorkItem,
  branch,
  tag,
  path,
  ref,
  pipeline,
  job,
  note,
  emoji,
  todo,
  upload,
  label,
  milestone,
  release,
  snippet,
  file,
  merge,
  newBranch,
  other,
}

enum AiResourceSide { none, issue, mergeRequest, project, group, account }

/// App-owned provenance. [proposed] and [toolResult] do not bind a target.
/// The other values are assigned by the app and must not be copied from model arguments.
enum AiTargetOrigin {
  proposed,
  currentResource,
  uiAdded,
  createdInSegment,
  toolResult,
}

final class AiTargetRef {
  AiTargetRef({
    required this.kind,
    AiResourceSide? side,
    this.origin = AiTargetOrigin.proposed,
    this.projectId,
    this.projectPath,
    this.iid,
    this.parentIid,
    this.noteId,
    this.refName,
    this.path,
    this.sourceRef,
    this.targetRef,
    this.pipelineId,
    this.jobId,
    this.jobBelongsToBoundPipeline = false,
    this.pipelineCreatedInSegment = false,
    this.groupFullPath,
    this.groupId,
    this.name,
  }) : side = side ?? _defaultSide(kind);

  final AiTargetKind kind;
  final AiResourceSide side;
  final AiTargetOrigin origin;
  final int? projectId;
  final String? projectPath;
  final int? iid;
  final int? parentIid;
  final int? noteId;
  final String? refName;
  final String? path;
  final String? sourceRef;
  final String? targetRef;
  final int? pipelineId;
  final int? jobId;
  final bool jobBelongsToBoundPipeline;
  final bool pipelineCreatedInSegment;
  final String? groupFullPath;
  final int? groupId;
  final String? name;
}

AiResourceSide _defaultSide(AiTargetKind kind) {
  switch (kind) {
    case AiTargetKind.issue:
    case AiTargetKind.note:
    case AiTargetKind.emoji:
      return AiResourceSide.issue;
    case AiTargetKind.mergeRequest:
    case AiTargetKind.merge:
      return AiResourceSide.mergeRequest;
    case AiTargetKind.groupWorkItem:
      return AiResourceSide.group;
    case AiTargetKind.todo:
      return AiResourceSide.account;
    case AiTargetKind.project:
    case AiTargetKind.upload:
    case AiTargetKind.file:
    case AiTargetKind.newBranch:
    case AiTargetKind.label:
    case AiTargetKind.milestone:
    case AiTargetKind.release:
    case AiTargetKind.snippet:
    case AiTargetKind.branch:
    case AiTargetKind.tag:
    case AiTargetKind.path:
    case AiTargetKind.ref:
    case AiTargetKind.pipeline:
    case AiTargetKind.job:
      return AiResourceSide.project;
    case AiTargetKind.other:
      return AiResourceSide.none;
  }
}

final class AiBindingResult {
  const AiBindingResult({
    required this.userMessage,
    required this.allBound,
    required this.intentAuthorizesLowRisk,
    this.restoredFromHistory = false,
    this.interfaceLanguage = '',
    this.deviceLanguages = const <String>[],
    this.reasons = const <AiFixedConfirmReason>[],
    this.missingComponents = const <String>[],
    this.redactedReason,
    this.matchedDirection,
  });

  /// Original user text for the card. Not a projection and not restored history.
  final String userMessage;
  final bool allBound;
  final bool intentAuthorizesLowRisk;
  final bool restoredFromHistory;
  final String interfaceLanguage;
  final List<String> deviceLanguages;
  final List<AiFixedConfirmReason> reasons;
  final List<String> missingComponents;

  /// Already-redacted model reason. This layer does not redact or render it.
  final String? redactedReason;
  final AiIntentDirection? matchedDirection;
}

bool scopeAdmits(
  AiWriteScope scope,
  AiCapability capability,
  AiTargetRef target,
) {
  if (capability.scopeClass == AiScopeClass.groupWorkItem ||
      target.kind == AiTargetKind.groupWorkItem) {
    return false;
  }
  for (final AiScopeGrant grant in scope.grants) {
    if (_grantAdmits(grant, capability, target)) return true;
  }
  return false;
}

AiBindingResult bindTargets({
  required String userMessage,
  required bool restoredFromHistory,
  required AiWriteScope scope,
  required List<AiTargetRef> targets,
  required String interfaceLanguage,
  required List<String> deviceLanguages,
  String? operationId,
  AiIntentDirection? requestedDirection,
  Map<String, Object?> arguments = const <String, Object?>{},
  String? redactedReason,
}) {
  final bool allowText = !restoredFromHistory;
  final _Parsed parsed = allowText
      ? _parse(aiProseForTargetBinding(userMessage), scope)
      : _Parsed();
  final List<String> missing = <String>[];
  var allBound = targets.isNotEmpty;
  if (targets.isEmpty) missing.add('target');
  for (final AiTargetRef target in targets) {
    final _ComponentCheck check = _bindOne(
      target: target,
      scope: scope,
      parsed: parsed,
      allowText: allowText,
    );
    if (!check.bound) {
      allBound = false;
      missing.addAll(check.missing);
    }
  }
  final AiIntentAssessment intent = assessIntent(
    message: userMessage,
    restoredFromHistory: restoredFromHistory,
    operationId: operationId ?? '',
    interfaceLanguage: interfaceLanguage,
    deviceLanguages: deviceLanguages,
    arguments: arguments,
    requestedDirection: requestedDirection,
  );
  final bool needsIntent = directionsFor(operationId ?? '').isNotEmpty;
  final List<AiFixedConfirmReason> reasons = <AiFixedConfirmReason>[
    if (!allBound) AiFixedConfirmReason.targetUnbound,
    if (needsIntent && !intent.authorizes) AiFixedConfirmReason.intentNotUnique,
  ];
  return AiBindingResult(
    userMessage: userMessage,
    allBound: allBound,
    intentAuthorizesLowRisk: intent.authorizes,
    restoredFromHistory: restoredFromHistory,
    interfaceLanguage: interfaceLanguage,
    deviceLanguages: List<String>.unmodifiable(deviceLanguages),
    reasons: List<AiFixedConfirmReason>.unmodifiable(reasons),
    missingComponents: List<String>.unmodifiable(missing),
    redactedReason: redactedReason,
    matchedDirection: intent.direction,
  );
}

bool _grantAdmits(
  AiScopeGrant grant,
  AiCapability capability,
  AiTargetRef target,
) {
  switch (capability.scopeClass) {
    case AiScopeClass.project:
      return grant.kind == AiScopeKind.project &&
          grant.projectId != null &&
          grant.projectId == target.projectId;
    case AiScopeClass.workItem:
      return _coversIssue(grant, target);
    case AiScopeClass.mergeRequest:
      return _coversMergeRequest(grant, target);
    case AiScopeClass.resource:
      if (target.side == AiResourceSide.mergeRequest) {
        return _coversMergeRequest(grant, target);
      }
      if (target.side == AiResourceSide.issue) {
        return _coversIssue(grant, target);
      }
      return false;
    case AiScopeClass.accountTodo:
      if (grant.kind == AiScopeKind.accountGlobal) return true;
      if (target.side == AiResourceSide.mergeRequest) {
        return _coversMergeRequest(grant, target);
      }
      if (target.side == AiResourceSide.issue ||
          target.iid != null ||
          target.parentIid != null) {
        return _coversIssue(grant, target);
      }
      return grant.kind == AiScopeKind.project &&
          grant.projectId != null &&
          grant.projectId == target.projectId;
    case AiScopeClass.groupWorkItem:
      return false;
    case AiScopeClass.projectUpload:
      return (grant.kind == AiScopeKind.project ||
              grant.kind == AiScopeKind.workItem ||
              grant.kind == AiScopeKind.mergeRequest) &&
          grant.projectId != null &&
          grant.projectId == target.projectId;
    case AiScopeClass.accountGlobalOnly:
      return grant.kind == AiScopeKind.accountGlobal;
    case AiScopeClass.personalNamespace:
      if (grant.kind != AiScopeKind.project) return false;
      if (capability.operationId == 'createProject') return true;
      if (capability.operationId == 'forkProject') {
        return grant.projectId != null && grant.projectId == target.projectId;
      }
      return false;
  }
}

bool _coversIssue(AiScopeGrant grant, AiTargetRef target) {
  if (grant.projectId == null ||
      target.projectId == null ||
      grant.projectId != target.projectId) {
    return false;
  }
  if (grant.kind == AiScopeKind.project) return true;
  final int? iid = _itemIid(target);
  return grant.kind == AiScopeKind.workItem && iid != null && grant.iid == iid;
}

bool _coversMergeRequest(AiScopeGrant grant, AiTargetRef target) {
  if (grant.projectId == null ||
      target.projectId == null ||
      grant.projectId != target.projectId) {
    return false;
  }
  if (grant.kind == AiScopeKind.project) return true;
  final int? iid = _itemIid(target);
  return grant.kind == AiScopeKind.mergeRequest &&
      iid != null &&
      grant.iid == iid;
}

int? _itemIid(AiTargetRef target) {
  switch (target.kind) {
    case AiTargetKind.note:
    case AiTargetKind.emoji:
    case AiTargetKind.todo:
      return target.parentIid ?? target.iid;
    case AiTargetKind.project:
    case AiTargetKind.issue:
    case AiTargetKind.mergeRequest:
    case AiTargetKind.groupWorkItem:
    case AiTargetKind.branch:
    case AiTargetKind.tag:
    case AiTargetKind.path:
    case AiTargetKind.ref:
    case AiTargetKind.pipeline:
    case AiTargetKind.job:
    case AiTargetKind.upload:
    case AiTargetKind.label:
    case AiTargetKind.milestone:
    case AiTargetKind.release:
    case AiTargetKind.snippet:
    case AiTargetKind.file:
    case AiTargetKind.merge:
    case AiTargetKind.newBranch:
    case AiTargetKind.other:
      return target.iid ?? target.parentIid;
  }
}

final class _ComponentCheck {
  const _ComponentCheck(this.bound, this.missing);
  final bool bound;
  final List<String> missing;
}

bool _appAsserts(AiTargetRef target) {
  switch (target.origin) {
    case AiTargetOrigin.currentResource:
    case AiTargetOrigin.uiAdded:
    case AiTargetOrigin.createdInSegment:
      return true;
    case AiTargetOrigin.proposed:
    case AiTargetOrigin.toolResult:
      return false;
  }
}

_ComponentCheck _bindOne({
  required AiTargetRef target,
  required AiWriteScope scope,
  required _Parsed parsed,
  required bool allowText,
}) {
  switch (target.kind) {
    case AiTargetKind.file:
      if (_appAsserts(target)) return const _ComponentCheck(true, <String>[]);
      final List<String> missing = <String>[
        if (!_projectGranted(scope, target)) 'project',
        if (!_refHit(target.refName, parsed, allowText)) 'ref',
        if (!_pathHit(target.path, parsed, allowText)) 'path',
      ];
      return _ComponentCheck(missing.isEmpty, missing);
    case AiTargetKind.merge:
      if (_appAsserts(target)) return const _ComponentCheck(true, <String>[]);
      final List<String> missing = <String>[
        if (!_resourceBound(
          target,
          scope,
          parsed,
          allowText,
          _IssueKind.mergeRequest,
        ))
          'mergeRequest',
        if (!_refHit(target.sourceRef, parsed, allowText)) 'source',
        if (!_refHit(target.targetRef, parsed, allowText)) 'target',
      ];
      return _ComponentCheck(missing.isEmpty, missing);
    case AiTargetKind.newBranch:
      final List<String> missing = <String>[
        if (!_projectGranted(scope, target)) 'project',
        if (!_nameHit(target.name, parsed, allowText)) 'name',
        if (!_refHit(target.sourceRef, parsed, allowText)) 'source',
      ];
      return _ComponentCheck(missing.isEmpty, missing);
    case AiTargetKind.job:
      final bool bound = _jobBound(target, scope, parsed, allowText);
      return _ComponentCheck(bound, bound ? const <String>[] : <String>['job']);
    case AiTargetKind.groupWorkItem:
      final bool bound = _groupBound(target, scope, parsed, allowText);
      return _ComponentCheck(
        bound,
        bound ? const <String>[] : <String>['groupWorkItem'],
      );
    case AiTargetKind.project:
    case AiTargetKind.upload:
      final bool bound = _appAsserts(target) || _projectGranted(scope, target);
      return _ComponentCheck(
        bound,
        bound ? const <String>[] : <String>[target.kind.name],
      );
    case AiTargetKind.note:
      if (target.noteId != null) {
        final bool bound = allowText &&
            _projectIdInScope(scope, target.projectId) &&
            parsed.noteIds.contains(target.noteId);
        return _ComponentCheck(bound, bound ? const [] : const ['note']);
      }
      final bool bound = _resourceBound(target, scope, parsed, allowText,
          target.side == AiResourceSide.mergeRequest
              ? _IssueKind.mergeRequest : _IssueKind.issue);
      return _ComponentCheck(bound, bound ? const [] : const ['note']);
    case AiTargetKind.issue:
    case AiTargetKind.emoji:
      final bool bound = _resourceBound(
        target,
        scope,
        parsed,
        allowText,
        _IssueKind.issue,
      );
      return _ComponentCheck(
        bound,
        bound ? const <String>[] : <String>[target.kind.name],
      );
    case AiTargetKind.mergeRequest:
      final bool bound = _resourceBound(
        target,
        scope,
        parsed,
        allowText,
        _IssueKind.mergeRequest,
      );
      return _ComponentCheck(
        bound,
        bound ? const <String>[] : <String>['mergeRequest'],
      );
    case AiTargetKind.pipeline:
      final bool bound =
          _appAsserts(target) ||
          (allowText && _pipelineUrl(target, scope, parsed));
      return _ComponentCheck(
        bound,
        bound ? const <String>[] : <String>['pipeline'],
      );
    case AiTargetKind.todo:
      final bool bound = _appAsserts(target);
      return _ComponentCheck(
        bound,
        bound ? const <String>[] : <String>['todo'],
      );
    case AiTargetKind.branch:
    case AiTargetKind.tag:
    case AiTargetKind.label:
    case AiTargetKind.milestone:
    case AiTargetKind.release:
    case AiTargetKind.snippet:
    case AiTargetKind.path:
    case AiTargetKind.ref:
      final bool bound = _namedBound(target, scope, parsed, allowText);
      return _ComponentCheck(
        bound,
        bound ? const <String>[] : <String>[target.kind.name],
      );
    case AiTargetKind.other:
      return const _ComponentCheck(false, <String>['other']);
  }
}

bool _projectGranted(AiWriteScope scope, AiTargetRef target) {
  return scope.grants.any(
    (AiScopeGrant grant) =>
        grant.kind == AiScopeKind.project &&
        grant.projectId != null &&
        grant.projectId == target.projectId,
  );
}

bool _resourceBound(
  AiTargetRef target,
  AiWriteScope scope,
  _Parsed parsed,
  bool allowText,
  _IssueKind kind,
) {
  if (_appAsserts(target)) return true;
  final int? iid = _itemIid(target);
  if (iid == null || target.projectId == null) return false;
  final bool current = scope.grants.any((AiScopeGrant grant) {
    if (grant.projectId != target.projectId || grant.iid != iid) return false;
    return kind == _IssueKind.issue
        ? grant.kind == AiScopeKind.workItem
        : grant.kind == AiScopeKind.mergeRequest;
  });
  if (current) return true;
  if (!allowText) return false;
  if (_iidHit(parsed, scope, target, iid, kind)) return true;
  return parsed.urls.any(
    (_UrlRef url) =>
        url.issueKind == kind &&
        url.iid == iid &&
        _pathsEqual(url.projectPath, target.projectPath) &&
        _projectIdInScope(scope, target.projectId),
  );
}

bool _iidHit(
  _Parsed parsed,
  AiWriteScope scope,
  AiTargetRef target,
  int iid,
  _IssueKind kind,
) {
  final List<_IssueRef> refs = kind == _IssueKind.issue
      ? parsed.issues
      : parsed.mergeRequests;
  final Set<int> projects = _projectIds(scope);
  for (final _IssueRef ref in refs) {
    if (ref.iid != iid) continue;
    if (ref.projectPath == null) {
      if (projects.length == 1 && projects.single == target.projectId) {
        return true;
      }
      continue;
    }
    if (_pathsEqual(ref.projectPath, target.projectPath) &&
        _projectIdInScope(scope, target.projectId)) {
      return true;
    }
  }
  return false;
}

bool _groupBound(
  AiTargetRef target,
  AiWriteScope scope,
  _Parsed parsed,
  bool allowText,
) {
  if (_appAsserts(target)) return true;
  if (target.iid == null) return false;
  final bool current = scope.grants.any(
    (AiScopeGrant grant) =>
        grant.kind == AiScopeKind.groupWorkItem &&
        grant.iid == target.iid &&
        _pathsEqual(grant.groupFullPath, target.groupFullPath),
  );
  if (current) return true;
  if (!allowText) return false;
  final bool pathInScope = scope.grants.any(
    (AiScopeGrant grant) =>
        grant.kind == AiScopeKind.groupWorkItem &&
        _pathsEqual(grant.groupFullPath, target.groupFullPath),
  );
  if (!pathInScope) return false;
  return parsed.urls.any(
    (_UrlRef url) =>
        url.issueKind == _IssueKind.groupWorkItem &&
        url.iid == target.iid &&
        _pathsEqual(url.groupPath, target.groupFullPath),
  );
}

bool _jobBound(
  AiTargetRef target,
  AiWriteScope scope,
  _Parsed parsed,
  bool allowText,
) {
  if (_appAsserts(target)) return true;
  if (target.jobId == null) return false;
  if (allowText &&
      parsed.urls.any(
        (_UrlRef url) =>
            url.issueKind == _IssueKind.job &&
            url.jobId == target.jobId &&
            _pathsEqual(url.projectPath, target.projectPath) &&
            _projectIdInScope(scope, target.projectId),
      )) {
    return true;
  }
  if (!target.jobBelongsToBoundPipeline) return false;
  if (target.pipelineCreatedInSegment) {
    return _projectIdInScope(scope, target.projectId);
  }
  if (!allowText || target.pipelineId == null) return false;
  return _pipelineUrl(
    AiTargetRef(
      kind: AiTargetKind.pipeline,
      projectId: target.projectId,
      projectPath: target.projectPath,
      pipelineId: target.pipelineId,
    ),
    scope,
    parsed,
  );
}

bool _pipelineUrl(AiTargetRef target, AiWriteScope scope, _Parsed parsed) {
  if (target.pipelineId == null) return false;
  return parsed.urls.any(
    (_UrlRef url) =>
        url.issueKind == _IssueKind.pipeline &&
        url.pipelineId == target.pipelineId &&
        _pathsEqual(url.projectPath, target.projectPath) &&
        _projectIdInScope(scope, target.projectId),
  );
}

bool _namedBound(
  AiTargetRef target,
  AiWriteScope scope,
  _Parsed parsed,
  bool allowText,
) {
  if (_appAsserts(target)) return true;
  if (!_projectGranted(scope, target) || !allowText) return false;
  final String? name = target.name ?? target.refName ?? target.path;
  if (target.kind == AiTargetKind.path) {
    return _pathHit(target.path ?? target.name, parsed, true);
  }
  if (target.kind == AiTargetKind.ref || target.kind == AiTargetKind.branch) {
    return _refHit(target.refName ?? target.name, parsed, true);
  }
  if (target.kind == AiTargetKind.tag) {
    return _nameHit(name, parsed, true) || parsed.tags.contains(name) ||
        _verbatimHit(name, parsed);
  }
  return _nameHit(name, parsed, true);
}

bool _refHit(String? ref, _Parsed parsed, bool allowText) {
  if (!allowText || ref == null || ref.isEmpty) return false;
  if (parsed.refs.contains(ref) || parsed.tokens.contains(ref) ||
      _verbatimHit(ref, parsed)) {
    return true;
  }
  const String head = 'refs/heads/';
  if (ref.startsWith(head)) {
    return parsed.refs.contains(ref.substring(head.length));
  }
  return false;
}

bool _pathHit(String? path, _Parsed parsed, bool allowText) {
  if (!allowText) return false;
  final String? normal = _normalizeRepoPath(path);
  if (normal == null) return false;
  return parsed.paths.contains(normal) || _verbatimHit(path, parsed);
}

bool _nameHit(String? name, _Parsed parsed, bool allowText) {
  if (!allowText || name == null || name.isEmpty) return false;
  return parsed.tokens.contains(name) ||
      parsed.refs.contains(name) ||
      parsed.tags.contains(name);
}

bool _projectIdInScope(AiWriteScope scope, int? projectId) {
  if (projectId == null) return false;
  return _projectIds(scope).contains(projectId);
}

Set<int> _projectIds(AiWriteScope scope) {
  return <int>{
    for (final AiScopeGrant grant in scope.grants)
      if (grant.projectId != null &&
          grant.kind != AiScopeKind.groupWorkItem &&
          grant.kind != AiScopeKind.accountGlobal)
        grant.projectId!,
  };
}

bool _pathsEqual(String? left, String? right) {
  final String? a = _normalizeRepoPath(left);
  final String? b = _normalizeRepoPath(right);
  return a != null && a == b;
}

String? _normalizeRepoPath(String? raw) {
  if (raw == null) return null;
  final List<String> out = <String>[];
  for (final String part in raw.trim().replaceAll('\\', '/').split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') return null;
    out.add(part);
  }
  if (out.isEmpty) return null;
  return out.join('/');
}

enum _IssueKind { issue, mergeRequest, groupWorkItem, pipeline, job }

final class _IssueRef {
  const _IssueRef(this.projectPath, this.iid);
  final String? projectPath;
  final int iid;
}

final class _UrlRef {
  const _UrlRef({
    required this.issueKind,
    this.projectPath,
    this.groupPath,
    this.iid,
    this.pipelineId,
    this.jobId,
  });

  final _IssueKind issueKind;
  final String? projectPath;
  final String? groupPath;
  final int? iid;
  final int? pipelineId;
  final int? jobId;
}

final class _Span {
  const _Span(this.start, this.end);
  final int start;
  final int end;
  bool covers(int from, int to) => from < end && start < to;
}

bool _verbatimHit(String? name, _Parsed parsed) {
  if (name == null || name.isEmpty) return false;
  // A repo name is one complete token; "main" never matches "mainly".
  return RegExp('(?<![A-Za-z0-9_./~@%+\\-])${RegExp.escape(name)}'
      '(?![A-Za-z0-9_/~@%+\\-]|\\.[A-Za-z0-9_.-])')
      .hasMatch(parsed.prose);
}

final class _Parsed {
  final List<_IssueRef> issues = <_IssueRef>[];
  final List<_IssueRef> mergeRequests = <_IssueRef>[];
  final List<_UrlRef> urls = <_UrlRef>[];
  final Set<String> tokens = <String>{};
  final Set<String> refs = <String>{};
  final Set<String> paths = <String>{};
  final Set<String> tags = <String>{};
  final Set<int> noteIds = <int>{};
  String prose = '';
}

_Parsed _parse(String text, AiWriteScope scope) {
  final _Parsed parsed = _Parsed();
  final List<_Span> spans = <_Span>[];
  final RegExp ticks = RegExp(r'`([^`\n]+)`');
  for (final RegExpMatch match in ticks.allMatches(text)) {
    spans.add(_Span(match.start, match.end));
    _addTick(match.group(1)!, parsed);
  }
  final RegExp urls = RegExp("https://[^\\s<>()\"']+");
  for (final RegExpMatch match in urls.allMatches(text)) {
    if (_inside(spans, match.start, match.end)) continue;
    spans.add(_Span(match.start, match.end));
    _addUrl(match.group(0)!, scope, parsed);
  }
  final RegExp qualified = RegExp(
    r'(?<![A-Za-z0-9_./])([A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+)([#!])(\d+)',
  );
  for (final RegExpMatch match in qualified.allMatches(text)) {
    if (_inside(spans, match.start, match.end)) continue;
    spans.add(_Span(match.start, match.end));
    final String? path = _normalizeRepoPath(match.group(1));
    final int? iid = int.tryParse(match.group(3)!);
    if (path == null || iid == null) continue;
    final _IssueRef ref = _IssueRef(path, iid);
    if (match.group(2) == '!') {
      parsed.mergeRequests.add(ref);
    } else {
      parsed.issues.add(ref);
    }
  }
  final RegExp bare = RegExp(r'(?<![A-Za-z0-9_./])([#!])(\d+)');
  for (final RegExpMatch match in bare.allMatches(text)) {
    if (_inside(spans, match.start, match.end)) continue;
    final int? iid = int.tryParse(match.group(2)!);
    if (iid == null) continue;
    final _IssueRef ref = _IssueRef(null, iid);
    if (match.group(1) == '!') {
      parsed.mergeRequests.add(ref);
    } else {
      parsed.issues.add(ref);
    }
  }
  final prose = StringBuffer();
  var end = 0;
  for (final span in spans..sort((a, b) => a.start.compareTo(b.start))) {
    if (span.start < end) continue;
    prose.write(text.substring(end, span.start));
    prose.write(' ');
    end = span.end;
  }
  prose.write(text.substring(end));
  parsed.prose = prose.toString();
  final noteReference = RegExp(r'(?<![A-Za-z0-9_])(?:note:|note #|#note_)([1-9][0-9]*)(?![A-Za-z0-9_])');
  for (final match in noteReference.allMatches(parsed.prose)) {
    parsed.noteIds.add(int.parse(match.group(1)!));
  }
  return parsed;
}

bool _inside(List<_Span> spans, int start, int end) =>
    spans.any((_Span span) => span.covers(start, end));

void _addTick(String raw, _Parsed parsed) {
  final String text = raw.trim();
  if (text.isEmpty || text.contains('..')) return;
  const String head = 'refs/heads/';
  const String tag = 'refs/tags/';
  if (text.startsWith(head)) {
    final String name = text.substring(head.length).trim();
    if (name.isNotEmpty && !name.contains('..')) parsed.refs.add(name);
    return;
  }
  if (text.startsWith(tag)) {
    final String name = text.substring(tag.length).trim();
    if (name.isNotEmpty && !name.contains('..')) parsed.tags.add(name);
    return;
  }
  final note = RegExp(r'^(?:note:|note #|#note_)([1-9][0-9]*)$').firstMatch(text);
  if (note != null) parsed.noteIds.add(int.parse(note.group(1)!));
  parsed.tokens.add(text);
  parsed.refs.add(text);
  final String? path = _normalizeRepoPath(text);
  if (path != null) parsed.paths.add(path);
}

void _addUrl(String raw, AiWriteScope scope, _Parsed parsed) {
  var text = raw;
  while (text.isNotEmpty && '.,;:!?'.contains(text[text.length - 1])) {
    text = text.substring(0, text.length - 1);
  }
  final Uri? uri = Uri.tryParse(text);
  final GitLabInstance? instance = scope.resolvedInstance;
  if (uri == null || instance == null || !_verifiedInstance(instance, uri)) {
    return;
  }
  final List<String> prefix = instance.base.pathSegments
      .where((String s) => s.isNotEmpty)
      .toList();
  final List<String> segments = uri.pathSegments
      .where((String s) => s.isNotEmpty)
      .toList();
  if (segments.any((String s) => s == '.' || s == '..')) return;
  if (segments.length < prefix.length) return;
  for (var i = 0; i < prefix.length; i++) {
    if (segments[i] != prefix[i]) return;
  }
  final List<String> rest = segments.sublist(prefix.length);
  final int dash = rest.indexOf('-');
  if (dash <= 0 || dash + 1 >= rest.length) return;
  var owner = rest.sublist(0, dash).join('/');
  final String kind = rest[dash + 1];
  if (const {'issues', 'merge_requests'}.contains(kind) &&
      rest.length == dash + 3 && int.tryParse(rest.last) != null) {
    final note = RegExp(r'^note_([1-9][0-9]*)$').firstMatch(uri.fragment);
    if (note != null) parsed.noteIds.add(int.parse(note.group(1)!));
  }
  final List<String> tail = rest.sublist(dash + 2);
  var group = false;
  if (owner.startsWith('groups/')) {
    owner = owner.substring('groups/'.length);
    group = true;
  } else if (scope.grants.any(
    (AiScopeGrant grant) =>
        grant.kind == AiScopeKind.groupWorkItem &&
        _pathsEqual(grant.groupFullPath, owner),
  )) {
    group = true;
  }
  switch (kind) {
    case 'issues':
      final int? issueIid = tail.length == 1 ? int.tryParse(tail[0]) : null;
      if (issueIid == null) return;
      parsed.urls.add(
        _UrlRef(issueKind: _IssueKind.issue, projectPath: owner, iid: issueIid),
      );
    case 'merge_requests':
      final int? mergeIid = tail.length == 1 ? int.tryParse(tail[0]) : null;
      if (mergeIid == null) return;
      parsed.urls.add(
        _UrlRef(
          issueKind: _IssueKind.mergeRequest,
          projectPath: owner,
          iid: mergeIid,
        ),
      );
    case 'work_items':
      final int? workIid = tail.length == 1 ? int.tryParse(tail[0]) : null;
      if (workIid == null) return;
      if (group) {
        parsed.urls.add(
          _UrlRef(
            issueKind: _IssueKind.groupWorkItem,
            groupPath: owner,
            iid: workIid,
          ),
        );
      } else {
        parsed.urls.add(
          _UrlRef(
            issueKind: _IssueKind.issue,
            projectPath: owner,
            iid: workIid,
          ),
        );
      }
    case 'pipelines':
      final int? pipeline = tail.isEmpty ? null : int.tryParse(tail[0]);
      if (pipeline == null) return;
      parsed.urls.add(
        _UrlRef(
          issueKind: _IssueKind.pipeline,
          projectPath: owner,
          pipelineId: pipeline,
        ),
      );
    case 'jobs':
      final int? job = tail.length == 1 ? int.tryParse(tail[0]) : null;
      if (job == null) return;
      parsed.urls.add(
        _UrlRef(issueKind: _IssueKind.job, projectPath: owner, jobId: job),
      );
    default:
      return;
  }
}

bool _verifiedInstance(GitLabInstance instance, Uri uri) {
  if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.host.isEmpty) {
    return false;
  }
  if (!instance.sameOrigin(uri)) return false;
  try {
    final GitLabInstance parsed = GitLabInstance.parse(instance.key);
    return parsed.key == instance.key;
  } on FormatException {
    return false;
  }
}
