import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/repository_graph.dart';

const m = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const a = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const b = 'cccccccccccccccccccccccccccccccccccccccc';
const c = 'dddddddddddddddddddddddddddddddddddddddd';

Map<String, dynamic> commit(String id, List<String> parents) => {
  'id': id,
  'short_id': id.substring(0, 8),
  'title': 'Commit ${id.substring(0, 1)}',
  'author_name': 'Developer',
  'committed_date': '2026-10-02T08:00:00Z',
  'parent_ids': parents,
};

void main() {
  test('lays out a merge and convergence using only declared parent edges', () {
    final graph = RepositoryGraphLayout.fromJson([
      commit(m, [a, b]),
      commit(a, [c]),
      commit(b, [c]),
      commit(c, const []),
    ]);

    expect(graph.rows.map((row) => row.lane), [0, 0, 1, 0]);
    expect(graph.rows[0].parents.map((edge) => (edge.sha, edge.lane)), [
      (a, 0),
      (b, 1),
    ]);
    expect(graph.rows[1].parents.map((edge) => (edge.sha, edge.lane)), [
      (c, 0),
    ]);
    expect(graph.rows[2].parents.map((edge) => (edge.sha, edge.lane)), [
      (c, 0),
    ]);
    expect(graph.rows[3].parents, isEmpty);
    expect(graph.boundaryParents, isEmpty);
    expect(graph.laneCount, 2);
  });

  test('reports parent lanes outside the loaded commit range', () {
    final graph = RepositoryGraphLayout.fromJson([
      commit(m, [a, b]),
    ]);

    expect(graph.boundaryParents.map((parent) => (parent.sha, parent.lane)), [
      (a, 0),
      (b, 1),
    ]);
  });

  test('rejects malformed commit identities and parent arrays', () {
    expect(
      () => RepositoryGraphLayout.fromJson([
        {
          ...commit(m, [a]),
          'id': 'not-a-sha',
        },
      ]),
      throwsFormatException,
    );
    expect(
      () => RepositoryGraphLayout.fromJson([
        {
          ...commit(m, [a]),
          'parent_ids': 'not-an-array',
        },
      ]),
      throwsFormatException,
    );
  });
}
