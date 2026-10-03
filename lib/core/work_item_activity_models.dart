import 'work_item_graph_models.dart';

enum WorkItemActivityAvailability { present, absent, widgetsUnavailable }

enum WorkItemActivityConnectionAvailability { present, unavailable }

enum WorkItemActivityFilter {
  all('ALL_NOTES'),
  comments('ONLY_COMMENTS'),
  history('ONLY_ACTIVITY');

  const WorkItemActivityFilter(this.graphValue);

  final String graphValue;
}

enum WorkItemActivityOrder {
  oldestFirst('CREATED_ASC'),
  newestFirst('CREATED_DESC');

  const WorkItemActivityOrder(this.graphValue);

  final String graphValue;
}

final class WorkItemActivityConnection<T> {
  WorkItemActivityConnection({
    required this.availability,
    required List<T> items,
  }) : items = List.unmodifiable(items);

  final WorkItemActivityConnectionAvailability availability;
  final List<T> items;
}

final class WorkItemActivityAuthor {
  const WorkItemActivityAuthor({
    required this.id,
    required this.name,
    required this.username,
  });

  final String id;
  final String name;
  final String username;
}

final class WorkItemActivityNote {
  const WorkItemActivityNote({
    required this.id,
    required this.system,
    required this.systemNoteIconName,
    required this.body,
    required this.createdAt,
    required this.updatedAt,
    required this.author,
  });

  final String id;
  final bool system;
  final String? systemNoteIconName;
  final String body;
  final DateTime createdAt;
  final DateTime updatedAt;
  final WorkItemActivityAuthor? author;
}

final class WorkItemActivityDiscussion {
  const WorkItemActivityDiscussion({
    required this.id,
    required this.replyId,
    required this.createdAt,
    required this.notes,
  });

  final String id;
  final String replyId;
  final DateTime createdAt;
  final WorkItemActivityConnection<WorkItemActivityNote> notes;
}

final class WorkItemActivitySnapshot {
  const WorkItemActivitySnapshot({
    required this.workItemId,
    required this.iid,
    required this.project,
    required this.namespace,
    required this.availability,
    required this.discussions,
  });

  final String workItemId;
  final int iid;
  final GraphResourceRef? project;
  final GraphResourceRef? namespace;
  final WorkItemActivityAvailability availability;
  final WorkItemActivityConnection<WorkItemActivityDiscussion> discussions;
}
