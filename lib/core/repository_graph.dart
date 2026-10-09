typedef GraphJson = Map<String, dynamic>;

final class RepositoryGraphCommit {
  const RepositoryGraphCommit({
    required this.id,
    required this.shortId,
    required this.title,
    required this.authorName,
    required this.committedDate,
    required this.parentIds,
    required this.raw,
  });

  factory RepositoryGraphCommit.fromJson(GraphJson value) {
    final id = value['id'];
    final parents = value['parent_ids'];
    if (id is! String || !_sha.hasMatch(id) || parents is! List<dynamic>) {
      throw const FormatException('Invalid commit graph record');
    }
    final parentIds = <String>[];
    for (final parent in parents) {
      if (parent is! String || !_sha.hasMatch(parent)) {
        throw const FormatException('Invalid commit parent');
      }
      parentIds.add(parent);
    }
    final short = value['short_id'];
    final title = value['title'];
    final message = value['message'];
    return RepositoryGraphCommit(
      id: id,
      shortId: short is String && short.isNotEmpty ? short : id.substring(0, 8),
      title: title is String && title.isNotEmpty
          ? title
          : message is String && message.isNotEmpty
          ? message.split('\n').first
          : id.substring(0, 8),
      authorName: value['author_name'] is String
          ? value['author_name'] as String
          : '',
      committedDate: value['committed_date'] is String
          ? value['committed_date'] as String
          : '',
      parentIds: List.unmodifiable(parentIds),
      raw: Map.unmodifiable(value),
    );
  }

  static final RegExp _sha = RegExp(r'^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$');

  final String id;
  final String shortId;
  final String title;
  final String authorName;
  final String committedDate;
  final List<String> parentIds;
  final GraphJson raw;
}

final class RepositoryGraphParent {
  const RepositoryGraphParent({required this.sha, required this.lane});
  final String sha;
  final int lane;
}

final class RepositoryGraphRow {
  const RepositoryGraphRow({
    required this.commit,
    required this.lane,
    required this.lanesBefore,
    required this.lanesAfter,
    required this.parents,
  });
  final RepositoryGraphCommit commit;
  final int lane;
  final List<String?> lanesBefore;
  final List<String?> lanesAfter;
  final List<RepositoryGraphParent> parents;
}

final class RepositoryGraphLayout {
  const RepositoryGraphLayout({
    required this.rows,
    required this.boundaryParents,
    required this.laneCount,
  });

  factory RepositoryGraphLayout.fromJson(List<GraphJson> values) {
    final commits = values
        .map(RepositoryGraphCommit.fromJson)
        .toList(growable: false);
    final rows = <RepositoryGraphRow>[];
    final active = <String?>[];
    final processed = <String>{};
    var laneCount = 0;

    int freeLane({int? preferred}) {
      if (preferred != null &&
          preferred < active.length &&
          active[preferred] == null) {
        return preferred;
      }
      final free = active.indexOf(null);
      if (free >= 0) return free;
      active.add(null);
      return active.length - 1;
    }

    for (final commit in commits) {
      if (!processed.add(commit.id)) continue;
      var lane = active.indexOf(commit.id);
      if (lane < 0) {
        lane = freeLane();
        active[lane] = commit.id;
      }
      final before = List<String?>.unmodifiable(active);
      active[lane] = null;
      final parents = <RepositoryGraphParent>[];
      for (var index = 0; index < commit.parentIds.length; index++) {
        final parent = commit.parentIds[index];
        if (processed.contains(parent)) {
          throw const FormatException('Commit order is not topological');
        }
        var parentLane = active.indexOf(parent);
        if (parentLane < 0) {
          parentLane = freeLane(preferred: index == 0 ? lane : null);
          active[parentLane] = parent;
        }
        parents.add(RepositoryGraphParent(sha: parent, lane: parentLane));
      }
      while (active.isNotEmpty && active.last == null) {
        active.removeLast();
      }
      laneCount = laneCount < before.length ? before.length : laneCount;
      if (laneCount < active.length) laneCount = active.length;
      rows.add(
        RepositoryGraphRow(
          commit: commit,
          lane: lane,
          lanesBefore: before,
          lanesAfter: List<String?>.unmodifiable(active),
          parents: List.unmodifiable(parents),
        ),
      );
    }

    final boundary = <RepositoryGraphParent>[
      for (var lane = 0; lane < active.length; lane++)
        if (active[lane] case final sha?)
          RepositoryGraphParent(sha: sha, lane: lane),
    ];
    return RepositoryGraphLayout(
      rows: List.unmodifiable(rows),
      boundaryParents: List.unmodifiable(boundary),
      laneCount: laneCount,
    );
  }

  final List<RepositoryGraphRow> rows;
  final List<RepositoryGraphParent> boundaryParents;
  final int laneCount;
}
