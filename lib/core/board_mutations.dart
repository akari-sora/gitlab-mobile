import 'board_queries.dart';
import 'failure.dart';

final class BoardMovePlan {
  const BoardMovePlan({required this.payload, required this.target});

  final Map<String, Object?> payload;
  final BoardColumn target;
}

bool boardColumnAcceptsDirectMove(BoardColumn column) =>
    column.kind == BoardColumnKind.open ||
    column.kind == BoardColumnKind.closed ||
    column.kind == BoardColumnKind.label;

BoardMovePlan planBoardIssueMove({
  required BoardDefinition board,
  required BoardColumn source,
  required BoardColumn target,
  required BoardJson issue,
}) {
  if (!boardColumnAcceptsDirectMove(source) ||
      !boardColumnAcceptsDirectMove(target) ||
      source.key == target.key) {
    throw const ApiFailure(
      FailureKind.unsupported,
      title: '無法直接移動到這個欄位',
      detail: '目前只支援 Open、Closed 與標籤欄位之間的直接移動。',
    );
  }
  final sourceQuery = boardIssueQuery(board, source);
  if (!sourceQuery.supported ||
      !boardColumnIssueMatches(board, source, sourceQuery, issue)) {
    throw const ApiFailure(
      FailureKind.conflict,
      title: '議題已不在原本欄位',
      detail: 'GitLab 上的議題已經變更。請重新整理看板後再移動。',
    );
  }
  final labels = issueLabelNames(issue).toList(growable: true);
  if (source.kind == BoardColumnKind.label) {
    labels.remove(source.label);
  }
  if (target.kind == BoardColumnKind.label) {
    final label = target.label;
    if (label == null || label.isEmpty) {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
    if (!labels.contains(label)) labels.add(label);
  }
  final state = issue['state'];
  if (state != 'opened' && state != 'closed') {
    throw const ApiFailure(FailureKind.invalidResponse);
  }
  if (target.kind == BoardColumnKind.open) {
    for (final column in board.columns) {
      if (column.kind == BoardColumnKind.assignee ||
          column.kind == BoardColumnKind.milestone ||
          column.kind == BoardColumnKind.unsupported) {
        final query = boardIssueQuery(board, column);
        if (!query.supported || boardIssueMatches(issue, query)) {
          throw const ApiFailure(
            FailureKind.unsupported,
            title: '無法直接移動到 Open',
            detail: '此議題仍符合無法由直接移動安全修改的看板欄位。請在議題頁調整指派或里程碑。',
          );
        }
      }
    }
  }
  return BoardMovePlan(
    target: target,
    payload: Map.unmodifiable({
      'labels': labels.join(','),
      if (target.kind == BoardColumnKind.closed && state != 'closed')
        'state_event': 'close',
      if (target.kind != BoardColumnKind.closed && state == 'closed')
        'state_event': 'reopen',
    }),
  );
}

Set<String> issueLabelNames(BoardJson issue) {
  final labels = <String>{};
  final raw = issue['labels'];
  if (raw is List) {
    for (final value in raw) {
      if (value is String && value.trim().isNotEmpty) labels.add(value.trim());
      if (value is BoardJson) {
        final name = value['name'];
        if (name is String && name.trim().isNotEmpty) labels.add(name.trim());
      }
    }
  }
  return labels;
}

bool boardMoveReadbackMatches(
  BoardDefinition board,
  BoardColumn source,
  BoardColumn target,
  BoardJson issue,
) {
  final targetMatches = target.kind == BoardColumnKind.open
      ? issue['state'] == 'opened'
      : boardColumnIssueMatches(
          board,
          target,
          boardIssueQuery(board, target),
          issue,
        );
  final sourceMatches = boardColumnIssueMatches(
    board,
    source,
    boardIssueQuery(board, source),
    issue,
  );
  return targetMatches && !sourceMatches;
}
