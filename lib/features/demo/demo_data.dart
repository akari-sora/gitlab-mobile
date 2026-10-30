import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/gitlab_api.dart' show Json;
import 'demo_scope.dart';

// The demo's sample data, in the shapes the GitLab REST API returns. It is
// English, like most repository content, and it is all fiction: no name,
// address or project here refers to anything real. Every URL is on the
// `.invalid` demo host, and no avatar or image points anywhere else.

const demoUserId = 4101;
const demoGroupId = 3001;
const demoPlannerId = 3101;
const demoNotesId = 3102;
const demoPipelineId = 3201;

/// The issue the AI comments on or closes when its page is not an issue.
const demoDefaultIssue = 1;

const _web = 'https://$demoHost';
const _group = 'mergeline-demo';

Json demoUser(int id) => switch (id) {
  4102 => _user(4102, 'sam.rivera', 'Sam Rivera'),
  4103 => _user(4103, 'priya.nair', 'Priya Nair'),
  _ => _user(demoUserId, 'alex.demo', 'Alex Morgan'),
};

Json _user(int id, String username, String name) => {
  'id': id,
  'username': username,
  'name': name,
  'state': 'active',
  'locked': false,
  'avatar_url': null,
  'web_url': '$_web/$username',
};

final Json demoGroup = {
  'id': demoGroupId,
  'name': 'Mergeline Demo',
  'path': _group,
  'full_name': 'Mergeline Demo',
  'full_path': _group,
  'description': 'Sample projects for trying Mergeline without an account.',
  'visibility': 'private',
  'kind': 'group',
  'parent_id': null,
  'avatar_url': null,
  'web_url': '$_web/groups/$_group',
  'created_at': '2026-09-01T09:00:00.000Z',
};

/// One commit of the sample history. [files] are full file contents after
/// the commit (null deletes a file); the diff is derived from them.
final class DemoCommit {
  const DemoCommit({
    required this.sha,
    required this.parent,
    required this.title,
    required this.author,
    required this.date,
    required this.files,
    this.message = '',
  });

  final String sha;
  final String? parent;
  final String title;
  final String message;
  final int author;
  final String date;
  final Map<String, String?> files;
}

/// A sample project: metadata, its commits by branch and its files.
final class DemoProject {
  DemoProject({
    required this.id,
    required this.name,
    required this.path,
    required this.description,
    required this.created,
    required this.commits,
    required this.branches,
    this.starCount = 0,
    this.topics = const [],
  });

  final int id;
  final String name;
  final String path;
  final String description;
  final String created;
  final List<DemoCommit> commits;

  /// Branch name to head commit SHA; the first is the default branch.
  final Map<String, String> branches;
  final int starCount;
  final List<String> topics;

  String get fullPath => '$_group/$path';
  String get web => '$_web/$fullPath';
  String get defaultBranch => branches.keys.first;

  DemoCommit? commit(String sha) =>
      commits.where((commit) => commit.sha == sha).firstOrNull;

  /// The commit a branch name, tag or SHA (or a prefix of one) names.
  DemoCommit? resolve(String? ref) {
    final name = ref == null || ref.isEmpty ? defaultBranch : ref;
    final head = branches[name];
    if (head != null) return commit(head);
    if (name.length < 7) return null;
    return commits.where((commit) => commit.sha.startsWith(name)).firstOrNull;
  }

  /// Oldest first, from the root to [head].
  List<DemoCommit> history(DemoCommit head) {
    final chain = <DemoCommit>[];
    DemoCommit? current = head;
    while (current != null) {
      chain.add(current);
      current = current.parent == null ? null : commit(current.parent!);
    }
    return chain.reversed.toList();
  }

  /// Every file as of [head].
  Map<String, String> tree(DemoCommit head) {
    final files = <String, String>{};
    for (final commit in history(head)) {
      commit.files.forEach((path, content) {
        if (content == null) {
          files.remove(path);
        } else {
          files[path] = content;
        }
      });
    }
    return files;
  }

  Json record({int openIssues = 0}) => {
    'id': id,
    'description': description,
    'name': name,
    'name_with_namespace': 'Mergeline Demo / $name',
    'path': path,
    'path_with_namespace': fullPath,
    'created_at': created,
    'default_branch': defaultBranch,
    'tag_list': topics,
    'topics': topics,
    'ssh_url_to_repo': 'git@$demoHost:$fullPath.git',
    'http_url_to_repo': '$web.git',
    'web_url': web,
    'readme_url': '$web/-/blob/$defaultBranch/README.md',
    'forks_count': 0,
    'avatar_url': null,
    'star_count': starCount,
    'last_activity_at': '2026-10-28T16:20:00.000Z',
    'visibility': 'private',
    'archived': false,
    'empty_repo': false,
    'issues_enabled': true,
    'merge_requests_enabled': true,
    'jobs_enabled': true,
    'wiki_enabled': false,
    'snippets_enabled': false,
    'open_issues_count': openIssues,
    'namespace': {
      'id': demoGroupId,
      'name': 'Mergeline Demo',
      'path': _group,
      'kind': 'group',
      'full_path': _group,
      'parent_id': null,
      'avatar_url': null,
      'web_url': '$_web/groups/$_group',
    },
    'permissions': {
      'project_access': {'access_level': 40, 'notification_level': 3},
      'group_access': null,
    },
  };
}

/// Git's blob id, so tree entries and file headers agree like on GitLab.
String demoBlobId(String content) {
  final bytes = utf8.encode(content);
  return sha1.convert([
    ...utf8.encode('blob ${bytes.length}\u0000'),
    ...bytes,
  ]).toString();
}

const _readme = '''# Pocket Planner

A small Flutter to-do app. This repository is sample data for the Mergeline
demo; it is not a real project.

## Features

- Add, complete and delete tasks
- Keep tasks in named lists
- Works offline

## Development

```sh
flutter pub get
flutter test
```

The task model lives in `lib/task.dart`, and the list screen in
`lib/main.dart`.
''';

const _pubspec = '''name: pocket_planner
description: A small to-do app used as Mergeline sample data.
publish_to: none
version: 1.0.0+1

environment:
  sdk: ^3.5.0

dependencies:
  flutter:
    sdk: flutter

dev_dependencies:
  flutter_test:
    sdk: flutter
''';

const _taskV1 = '''/// One item on a to-do list.
class Task {
  const Task({required this.title, this.done = false});

  final String title;
  final bool done;

  Task complete() => Task(title: title, done: true);

  static Task create(String title) => Task(title: title.trim());
}
''';

const _taskV2 = '''/// One item on a to-do list.
class Task {
  const Task({required this.title, this.done = false, this.due});

  final String title;
  final bool done;
  final DateTime? due;

  Task complete() => Task(title: title, done: true, due: due);

  static Task create(String title) => Task(title: title.trim());
}
''';

const _taskListV1 = '''import 'task.dart';

/// A named list of tasks.
class TaskList {
  TaskList(this.name);

  final String name;
  final List<Task> tasks = [];

  void add(String title) => tasks.add(Task.create(title));

  List<Task> get open => tasks.where((task) => !task.done).toList();
}
''';

const _taskListV2 = '''import 'task.dart';

/// A named list of tasks.
class TaskList {
  TaskList(this.name);

  final String name;
  final List<Task> tasks = [];

  void add(String title) => tasks.add(Task.create(title));

  List<Task> get open => tasks.where((task) => !task.done).toList();

  /// Open tasks, the ones due soonest first; tasks without a date last.
  List<Task> get byDueDate => open
    ..sort((a, b) => (a.due ?? DateTime(9999)).compareTo(b.due ?? DateTime(9999)));
}
''';

const _mainV1 = '''import 'package:flutter/material.dart';

import 'task_list.dart';

void main() => runApp(const PocketPlanner());

class PocketPlanner extends StatelessWidget {
  const PocketPlanner({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Pocket Planner',
    home: ListScreen(list: TaskList('Today')),
  );
}

class ListScreen extends StatelessWidget {
  const ListScreen({super.key, required this.list});

  final TaskList list;

  @override
  Widget build(BuildContext context) {
    final open = list.open;
    return ListView(
      children: [for (final task in open) ListTile(title: Text(task.title))],
    );
  }
}
''';

const _mainV2 = '''import 'package:flutter/material.dart';

import 'task_list.dart';

void main() => runApp(const PocketPlanner());

class PocketPlanner extends StatelessWidget {
  const PocketPlanner({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Pocket Planner',
    home: ListScreen(list: TaskList('Today')),
  );
}

class ListScreen extends StatelessWidget {
  const ListScreen({super.key, required this.list});

  final TaskList list;

  @override
  Widget build(BuildContext context) {
    final open = list.open;
    if (open.isEmpty) return const Center(child: Text('Nothing to do'));
    return ListView(
      children: [for (final task in open) ListTile(title: Text(task.title))],
    );
  }
}
''';

const _test = '''import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_planner/task.dart';

void main() {
  test('Task.create trims the title', () {
    expect(Task.create('  Buy milk ').title, 'Buy milk');
  });

  test('Task.complete marks the task done', () {
    expect(const Task(title: 'Call Sam').complete().done, isTrue);
  });
}
''';

const _ci = '''stages: [lint, test, build]

default:
  image: ghcr.io/cirruslabs/flutter:stable

analyze:
  stage: lint
  script:
    - flutter pub get
    - flutter analyze

test:
  stage: test
  script:
    - flutter test

build:
  stage: build
  script:
    - flutter build apk --debug
''';

const plannerShas = (
  initial: '4f6c2a91b8e3d07a5c19e2b4f8a63d1e0b7c9a52',
  model: '9b2e7d4c1a8f3e6b0d5c2a9f7e4b1c8d3a6f0e25',
  list: 'e3a91f0c6d2b8e5a7c4f1d9b3e6a0c8f2d5b7e14',
  ci: '7d0b5e2a9c4f1e8b6a3d0c7f5e2b9a4d1c8f6e33',
  emptyList: 'b5d2a8e1f4c7b0a3e6d9c2f5a8b1e4d7c0a3f612',
  dueDates: '2c8e5b1f7a4d0e9c6b3a8f5d2e1c7b4a9f6d3e08',
);

DemoProject demoPlanner() => DemoProject(
  id: demoPlannerId,
  name: 'Pocket Planner',
  path: 'pocket-planner',
  description: 'A small Flutter to-do app. Sample data for the Mergeline demo.',
  created: '2026-09-02T08:00:00.000Z',
  starCount: 12,
  topics: const ['flutter', 'sample'],
  branches: {
    'main': plannerShas.emptyList,
    'feature/due-dates': plannerShas.dueDates,
    'fix/empty-list': plannerShas.emptyList,
  },
  commits: [
    DemoCommit(
      sha: plannerShas.initial,
      parent: null,
      title: 'Initial commit',
      author: demoUserId,
      date: '2026-09-02T08:00:00.000Z',
      files: const {'README.md': _readme, 'pubspec.yaml': _pubspec},
    ),
    DemoCommit(
      sha: plannerShas.model,
      parent: plannerShas.initial,
      title: 'Add the task model',
      author: demoUserId,
      date: '2026-09-04T10:12:00.000Z',
      files: const {'lib/task.dart': _taskV1},
    ),
    DemoCommit(
      sha: plannerShas.list,
      parent: plannerShas.model,
      title: 'Add the list screen',
      author: 4103,
      date: '2026-09-10T14:40:00.000Z',
      files: const {
        'lib/task_list.dart': _taskListV1,
        'lib/main.dart': _mainV1,
        'test/task_test.dart': _test,
      },
    ),
    DemoCommit(
      sha: plannerShas.ci,
      parent: plannerShas.list,
      title: 'Run analysis and tests in CI',
      author: 4102,
      date: '2026-09-18T09:05:00.000Z',
      files: const {'.gitlab-ci.yml': _ci},
    ),
    DemoCommit(
      sha: plannerShas.emptyList,
      parent: plannerShas.ci,
      title: 'Show a message when the list is empty',
      message: 'Opening a list with no tasks crashed.\n\nCloses #3',
      author: demoUserId,
      date: '2026-10-22T11:30:00.000Z',
      files: const {'lib/main.dart': _mainV2},
    ),
    DemoCommit(
      sha: plannerShas.dueDates,
      parent: plannerShas.emptyList,
      title: 'Add due dates to tasks',
      author: 4103,
      date: '2026-10-27T15:45:00.000Z',
      files: const {
        'lib/task.dart': _taskV2,
        'lib/task_list.dart': _taskListV2,
      },
    ),
  ],
);

const _notesReadme = '''# Design Notes

Short design notes for Pocket Planner. Sample data for the Mergeline demo.

- [Onboarding](docs/onboarding.md)
''';

const _onboarding = '''# Onboarding

1. Open the app and create a list.
2. Add a task with an optional due date.
3. Swipe a task to complete it.
''';

DemoProject demoNotes() => DemoProject(
  id: demoNotesId,
  name: 'Design Notes',
  path: 'design-notes',
  description: 'Design notes for Pocket Planner. Sample data.',
  created: '2026-09-05T08:00:00.000Z',
  branches: {'main': '6a3f0c9e2b5d8a1f4e7c0b3d6a9f2e5c8b1d4a70'},
  commits: const [
    DemoCommit(
      sha: '6a3f0c9e2b5d8a1f4e7c0b3d6a9f2e5c8b1d4a70',
      parent: null,
      title: 'Add onboarding notes',
      author: 4103,
      date: '2026-09-05T08:00:00.000Z',
      files: {'README.md': _notesReadme, 'docs/onboarding.md': _onboarding},
    ),
  ],
);

Json demoLabel(int id, String name, String color, String description) => {
  'id': id,
  'name': name,
  'color': color,
  'text_color': '#FFFFFF',
  'description': description,
  'description_html': description,
  'open_issues_count': 0,
  'closed_issues_count': 0,
  'open_merge_requests_count': 0,
  'subscribed': false,
  'priority': null,
  'is_project_label': true,
};

final List<Json> demoLabels = [
  demoLabel(3601, 'bug', '#d9534f', 'Something does not work'),
  demoLabel(3602, 'feature', '#428bca', 'New behaviour'),
  demoLabel(3603, 'docs', '#5cb85c', 'Documentation'),
];

final Json demoMilestone = {
  'id': 3501,
  'iid': 1,
  'project_id': demoPlannerId,
  'title': 'v1.1',
  'description': 'Due dates and polish.',
  'state': 'active',
  'created_at': '2026-10-01T09:00:00.000Z',
  'updated_at': '2026-10-01T09:00:00.000Z',
  'due_date': '2026-11-30',
  'start_date': '2026-10-15',
  'expired': false,
  'web_url': '$_web/$_group/pocket-planner/-/milestones/1',
};

/// The ANSI-coloured logs of the sample pipeline's jobs.
const demoJobLogs = {
  3301:
      '\u001b[0KRunning with gitlab-runner 17.5.0 (sample)\u001b[0;m\n'
      '\u001b[0K\u001b[36;1mPreparing the job\u001b[0;m\n'
      '\$ flutter pub get\n'
      'Resolving dependencies...\n'
      'Got dependencies!\n'
      '\$ flutter analyze\n'
      'Analyzing pocket-planner...\n'
      '\u001b[32;1mNo issues found!\u001b[0;m (ran in 4.2s)\n'
      '\u001b[32;1mJob succeeded\u001b[0;m\n',
  3302:
      '\u001b[0KRunning with gitlab-runner 17.5.0 (sample)\u001b[0;m\n'
      '\$ flutter test\n'
      '00:02 +1: Task.create trims the title\n'
      '00:02 +2: Task.complete marks the task done\n'
      '\u001b[33mWARNING\u001b[0m 1 test has no assertion on due dates yet\n'
      '\u001b[32m00:03 +2: All tests passed!\u001b[0m\n'
      '\u001b[32;1mJob succeeded\u001b[0;m\n',
  3303:
      '\u001b[0KRunning with gitlab-runner 17.5.0 (sample)\u001b[0;m\n'
      '\$ flutter build apk --debug\n'
      "Running Gradle task 'assembleDebug'...\n"
      'Built build/app/outputs/flutter-apk/app-debug.apk\n'
      '\u001b[32;1mJob succeeded\u001b[0;m\n',
};
