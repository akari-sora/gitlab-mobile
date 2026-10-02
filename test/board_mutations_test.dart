import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/board_mutations.dart';
import 'package:gitlab_mobile/core/board_queries.dart';

void main() {
  final board = BoardDefinition.fromJson(
    {'id': 1, 'name': 'Board'},
    [
      {
        'id': 11,
        'position': 1,
        'label': {'id': 21, 'name': 'doing'},
      },
      {
        'id': 12,
        'position': 2,
        'label': {'id': 22, 'name': 'review'},
      },
    ],
  );

  test('label move removes only source and preserves other board labels', () {
    final plan = planBoardIssueMove(
      board: board,
      source: board.columns[1],
      target: board.columns[2],
      issue: {
        'state': 'opened',
        'labels': ['doing', 'review', 'customer'],
      },
    );

    expect(plan.payload, {'labels': 'review,customer'});
  });

  test('closed and open moves apply state event with a fresh label set', () {
    final close = planBoardIssueMove(
      board: board,
      source: board.columns[1],
      target: board.columns.last,
      issue: {
        'state': 'opened',
        'labels': ['doing', 'customer'],
      },
    );
    expect(close.payload, {'labels': 'customer', 'state_event': 'close'});

    final reopen = planBoardIssueMove(
      board: board,
      source: board.columns.last,
      target: board.columns.first,
      issue: {
        'state': 'closed',
        'labels': ['review', 'customer'],
      },
    );
    expect(reopen.payload, {
      'labels': 'review,customer',
      'state_event': 'reopen',
    });
    expect(
      boardMoveReadbackMatches(board, board.columns.last, board.columns.first, {
        'state': 'opened',
        'labels': ['review', 'customer'],
      }),
      isTrue,
    );
  });

  test('parsed server list identity is retained for management writes', () {
    final column = board.columns[1];
    expect(column.listId, 11);
    expect(column.labelId, 21);
    expect(column.position, 1);
  });

  test('Open move is blocked when a non-label column still matches', () {
    final mixed = BoardDefinition.fromJson(
      {'id': 2, 'name': 'Mixed'},
      [
        {
          'id': 31,
          'position': 1,
          'assignee': {'id': 7, 'name': 'Developer'},
        },
      ],
    );
    expect(
      () => planBoardIssueMove(
        board: mixed,
        source: mixed.columns[1],
        target: mixed.columns.first,
        issue: {
          'state': 'opened',
          'labels': <String>[],
          'assignees': [
            {'id': 7},
          ],
        },
      ),
      throwsA(isA<Exception>()),
    );
  });
}
