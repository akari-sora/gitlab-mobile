import 'models.dart';

typedef BoardJson = Map<String, dynamic>;

enum BoardColumnKind { open, closed, label, assignee, milestone, unsupported }

final class BoardScope {
  const BoardScope({
    this.labels = const [],
    this.assigneeId,
    this.milestoneId,
    this.milestoneTitle,
    this.weight,
    this.unsupportedReason,
  });

  final List<String> labels;
  final int? assigneeId;
  final int? milestoneId;
  final String? milestoneTitle;
  final int? weight;
  final String? unsupportedReason;
}

final class BoardColumn {
  const BoardColumn({
    required this.key,
    required this.title,
    required this.kind,
    this.label,
    this.labelColor,
    this.assigneeId,
    this.milestoneId,
    this.milestoneTitle,
    this.unsupportedReason,
  });

  final String key;
  final String title;
  final BoardColumnKind kind;
  final String? label;
  final String? labelColor;
  final int? assigneeId;
  final int? milestoneId;
  final String? milestoneTitle;
  final String? unsupportedReason;
}

final class BoardDefinition {
  const BoardDefinition({
    required this.id,
    required this.name,
    required this.scope,
    required this.columns,
  });

  factory BoardDefinition.fromJson(BoardJson board, List<BoardJson> lists) {
    final id = requiredInt(board, 'id');
    final name = optionalString(board, 'name')?.trim();
    final labels = <String>[];
    String? unsupportedReason;
    final rawLabels = board['labels'];
    if (rawLabels is String) {
      labels.addAll(
        rawLabels
            .split(',')
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty),
      );
    } else if (rawLabels is List) {
      for (final raw in rawLabels) {
        final value = raw is String
            ? raw.trim()
            : raw is BoardJson
            ? optionalString(raw, 'name')?.trim() ?? ''
            : '';
        if (value.isEmpty) {
          unsupportedReason ??= '看板的標籤篩選格式不完整。';
        } else if (!labels.contains(value)) {
          labels.add(value);
        }
      }
    } else if (rawLabels != null) {
      unsupportedReason = '看板的標籤篩選格式不受支援。';
    }
    final assignee = board['assignee'];
    final milestone = board['milestone'];
    final assigneeId = assignee is BoardJson
        ? _positiveInt(assignee['id'])
        : _positiveInt(board['assignee_id']);
    if ((assignee != null || board['assignee_id'] != null) &&
        assigneeId == null) {
      unsupportedReason ??= '看板的指派對象篩選缺少有效 ID。';
    }
    final milestoneId = milestone is BoardJson
        ? _positiveInt(milestone['id'])
        : _positiveInt(board['milestone_id']);
    final milestoneTitle = milestone is BoardJson
        ? optionalString(milestone, 'title')?.trim()
        : milestone is String
        ? milestone.trim()
        : null;
    if ((milestone != null || board['milestone_id'] != null) &&
        (milestoneTitle == null || milestoneTitle.isEmpty)) {
      unsupportedReason ??= '看板的里程碑篩選缺少 title，無法建立 Issues API 的 milestone 查詢。';
    }
    final rawWeight = board['weight'];
    final weight = _nonNegativeInt(rawWeight);
    if (rawWeight != null && (weight == null || weight > 9)) {
      unsupportedReason ??= '看板的 weight 篩選格式不受支援。';
    }
    final scope = BoardScope(
      labels: List.unmodifiable(labels),
      assigneeId: assigneeId,
      milestoneId: milestoneId,
      milestoneTitle: milestoneTitle,
      weight: weight,
      unsupportedReason: unsupportedReason,
    );
    final sorted = [...lists]
      ..sort((a, b) {
        final left = _nonNegativeInt(a['position']) ?? 0;
        final right = _nonNegativeInt(b['position']) ?? 0;
        return left.compareTo(right);
      });
    return BoardDefinition(
      id: id,
      name: name?.isNotEmpty == true ? name! : '看板 $id',
      scope: scope,
      columns: List.unmodifiable([
        if (board['hide_backlog_list'] != true)
          const BoardColumn(
            key: 'open',
            title: 'Open',
            kind: BoardColumnKind.open,
          ),
        for (final list in sorted) _columnFromList(list),
        if (board['hide_closed_list'] != true)
          const BoardColumn(
            key: 'closed',
            title: 'Closed',
            kind: BoardColumnKind.closed,
          ),
      ]),
    );
  }

  final int id;
  final String name;
  final BoardScope scope;
  final List<BoardColumn> columns;
}

final class BoardIssueQuery {
  const BoardIssueQuery.supported(this.parameters)
    : supported = true,
      reason = null;
  const BoardIssueQuery.unsupported(this.reason)
    : supported = false,
      parameters = const {};

  final bool supported;
  final Map<String, String> parameters;
  final String? reason;
}

BoardIssueQuery boardIssueQuery(
  BoardDefinition board,
  BoardColumn column, {
  String search = '',
}) {
  final scopeError = board.scope.unsupportedReason;
  if (scopeError != null) return BoardIssueQuery.unsupported(scopeError);
  if (column.kind == BoardColumnKind.unsupported) {
    return BoardIssueQuery.unsupported(
      column.unsupportedReason ?? 'GitLab 回傳了目前不支援的看板清單類型。',
    );
  }
  if (column.kind == BoardColumnKind.open &&
      board.columns.any((value) => value.kind == BoardColumnKind.unsupported)) {
    return const BoardIssueQuery.unsupported(
      '這個看板含有目前不支援的欄位，無法可靠判斷哪些議題屬於 Open。未載入可能重複的議題。',
    );
  }
  final labels = <String>[...board.scope.labels];
  var assigneeId = board.scope.assigneeId;
  var milestoneId = board.scope.milestoneId;
  var milestoneTitle = board.scope.milestoneTitle;
  switch (column.kind) {
    case BoardColumnKind.open:
    case BoardColumnKind.closed:
      break;
    case BoardColumnKind.label:
      final label = column.label;
      if (label == null || label.isEmpty) {
        return const BoardIssueQuery.unsupported('這個標籤清單缺少標籤資料。');
      }
      if (!labels.contains(label)) labels.add(label);
    case BoardColumnKind.assignee:
      if (assigneeId != null && assigneeId != column.assigneeId) {
        return const BoardIssueQuery.unsupported(
          '看板與欄位指定了不同的指派對象，Issues API 無法正確套用兩者。',
        );
      }
      assigneeId = column.assigneeId;
    case BoardColumnKind.milestone:
      if (milestoneId != null && milestoneId != column.milestoneId) {
        return const BoardIssueQuery.unsupported(
          '看板與欄位指定了不同的里程碑，Issues API 無法正確套用兩者。',
        );
      }
      milestoneId = column.milestoneId;
      milestoneTitle = column.milestoneTitle;
    case BoardColumnKind.unsupported:
      break;
  }
  final query = <String, String>{
    'scope': 'all',
    'state': column.kind == BoardColumnKind.closed ? 'closed' : 'opened',
    'order_by': 'relative_position',
    'sort': 'asc',
    'with_labels_details': 'true',
    if (labels.isNotEmpty) 'labels': labels.join(','),
    if (assigneeId != null) 'assignee_id': '$assigneeId',
    'milestone': ?milestoneTitle,
    if (board.scope.weight != null) 'weight': '${board.scope.weight}',
    if (search.trim().isNotEmpty) 'search': search.trim(),
  };
  return BoardIssueQuery.supported(Map.unmodifiable(query));
}

bool boardOpenIssueMatches(BoardDefinition board, BoardJson issue) {
  for (final column in board.columns) {
    if (column.kind == BoardColumnKind.open ||
        column.kind == BoardColumnKind.closed ||
        column.kind == BoardColumnKind.unsupported) {
      continue;
    }
    if (boardIssueMatches(issue, boardIssueQuery(board, column))) return false;
  }
  return true;
}

bool boardColumnIssueMatches(
  BoardDefinition board,
  BoardColumn column,
  BoardIssueQuery query,
  BoardJson issue,
) =>
    boardIssueMatches(issue, query) &&
    (column.kind != BoardColumnKind.open ||
        boardOpenIssueMatches(board, issue));

bool boardIssueMatches(BoardJson issue, BoardIssueQuery query) {
  if (!query.supported) return false;
  final parameters = query.parameters;
  final state = parameters['state'];
  if (state != null && issue['state'] != state) return false;
  final labels = _issueLabels(issue);
  final expectedLabels = parameters['labels']
      ?.split(',')
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty);
  if (expectedLabels != null &&
      expectedLabels.any((label) => !labels.contains(label))) {
    return false;
  }
  final expectedAssignee = int.tryParse(parameters['assignee_id'] ?? '');
  if (expectedAssignee != null) {
    final assignees = issue['assignees'];
    if (assignees is! List ||
        !assignees.any(
          (value) => value is BoardJson && value['id'] == expectedAssignee,
        )) {
      return false;
    }
  }
  final expectedMilestone = parameters['milestone'];
  if (expectedMilestone != null) {
    final milestone = issue['milestone'];
    if (milestone is! BoardJson || milestone['title'] != expectedMilestone) {
      return false;
    }
  }
  final expectedWeight = int.tryParse(parameters['weight'] ?? '');
  if (expectedWeight != null && issue['weight'] != expectedWeight) return false;
  return true;
}

BoardColumn _columnFromList(BoardJson list) {
  final id = _positiveInt(list['id']);
  final key = id == null ? 'unknown-${list['position'] ?? 0}' : 'list-$id';
  final label = list['label'];
  if (label is BoardJson) {
    final name = optionalString(label, 'name')?.trim() ?? '';
    if (name.isNotEmpty) {
      return BoardColumn(
        key: key,
        title: name,
        kind: BoardColumnKind.label,
        label: name,
        labelColor: optionalString(label, 'color'),
      );
    }
  }
  final assignee = list['assignee'];
  if (assignee is BoardJson) {
    final assigneeId = _positiveInt(assignee['id']);
    if (assigneeId != null) {
      final name = optionalString(assignee, 'name')?.trim();
      final username = optionalString(assignee, 'username')?.trim();
      return BoardColumn(
        key: key,
        title: name?.isNotEmpty == true
            ? name!
            : '@${username?.isNotEmpty == true ? username : assigneeId}',
        kind: BoardColumnKind.assignee,
        assigneeId: assigneeId,
      );
    }
  }
  final milestone = list['milestone'];
  if (milestone is BoardJson) {
    final milestoneId = _positiveInt(milestone['id']);
    final milestoneTitle = optionalString(milestone, 'title')?.trim();
    if (milestoneId != null && milestoneTitle?.isNotEmpty == true) {
      return BoardColumn(
        key: key,
        title: milestoneTitle!,
        kind: BoardColumnKind.milestone,
        milestoneId: milestoneId,
        milestoneTitle: milestoneTitle,
      );
    }
    return BoardColumn(
      key: key,
      title: '不支援的里程碑欄位',
      kind: BoardColumnKind.unsupported,
      unsupportedReason: '這個里程碑欄位缺少 ID 或 title，未載入任何替代議題。',
    );
  }
  final type =
      optionalString(list, 'type') ??
      (list['iteration'] is BoardJson ? 'iteration' : 'unknown');
  return BoardColumn(
    key: key,
    title: type == 'iteration' ? 'Iteration' : '不支援的欄位',
    kind: BoardColumnKind.unsupported,
    unsupportedReason: type == 'iteration'
        ? '目前版本尚未支援 Iteration 看板欄位，未載入任何替代議題。'
        : 'GitLab 回傳了不支援的「$type」看板欄位，未載入任何替代議題。',
  );
}

Set<String> _issueLabels(BoardJson issue) {
  final result = <String>{};
  final raw = issue['labels'];
  if (raw is List) {
    for (final value in raw) {
      if (value is String) result.add(value);
      if (value is BoardJson && value['name'] is String) {
        result.add(value['name'] as String);
      }
    }
  }
  return result;
}

int? _positiveInt(Object? value) => value is int && value > 0 ? value : null;
int? _nonNegativeInt(Object? value) =>
    value is int && value >= 0 ? value : null;
