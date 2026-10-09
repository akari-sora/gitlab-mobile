// Public read-only integration checks. No PAT, CI_JOB_TOKEN or private data.
// Uses production parsing/pagination/HTTP streaming with only authentication
// removed for GitLab endpoints that explicitly permit anonymous public reads.
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:gitlab_mobile/core/analytics_models.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/pipeline_graph.dart';
import 'package:gitlab_mobile/core/registry_models.dart';
import 'package:gitlab_mobile/core/repository_graph.dart';
import 'package:gitlab_mobile/core/snippet_models.dart';
import 'package:gitlab_mobile/core/unified_diff.dart';
import 'package:gitlab_mobile/core/work_item_activity_models.dart';
import 'package:gitlab_mobile/core/work_item_attribute_models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';

const _publicProjectId = 86648389;
const _publicProjectPath = 'aa22396584/gitlab-mobile';
const _publicPipelineId = 2906089178;
const _publicSnippetProjectId = 278964;
const _publicSnippetProjectPath = 'gitlab-org/gitlab';
const _publicSnippetId = 6030720;
const _publicSnippetPaths = ['README.md', 'verify-mattermost-docker.sh'];
const _projectSnippetsQuery = r'''
query MobileProjectSnippets($projectId: ProjectID!, $first: Int!, $after: String) {
  snippets(projectId: $projectId, first: $first, after: $after) {
    nodes { id project { id fullPath } updatedAt }
    pageInfo { hasNextPage endCursor }
  }
}
''';
const _snippetBlobQuery = r'''
query MobileSnippetBlob($ids: [SnippetID!], $paths: [String!]) {
  snippets(ids: $ids) {
    nodes {
      id
      project { id fullPath }
      updatedAt
      blobs(paths: $paths) {
        hasUnretrievableBlobs
        nodes {
          binary
          name
          path
          rawPath
          size
          rawPlainData
          renderedAsText
          simpleViewer { tooLarge renderError }
        }
      }
    }
  }
}
''';
const _publicWorkItemIid = 631894;
const _publicGroupWorkItemIid = 23883;
const _publicGroupParentWorkItemIid = 18225;
const _publicGroupWorkItemPath = 'gitlab-org';
const _publicWorkItemStateQuery = r'''
query MobileWorkItemState($id: WorkItemID!) {
  workItem(id: $id) {
    id
    iid
    state
    updatedAt
    project { id fullPath }
    namespace { id fullPath }
    workItemType { id }
    userPermissions { updateWorkItem }
  }
}
''';
const _publicWorkItemSummaryFields = r'''
id
iid
title
state
createdAt
updatedAt
project { id fullPath }
namespace { id fullPath }
workItemType { id name }
''';

final _publicProjectWorkItemsQuery =
    '''
query MobileProjectWorkItems(\$path: ID!, \$first: Int!, \$after: String) {
  project(fullPath: \$path) {
    id
    fullPath
    workItems(first: \$first, after: \$after) {
      nodes { $_publicWorkItemSummaryFields }
      pageInfo { hasNextPage endCursor }
    }
  }
}
''';

final _publicGroupWorkItemsQuery =
    '''
query MobileGroupWorkItems(
  \$path: ID!
  \$first: Int!
  \$after: String
  \$includeDescendants: Boolean!
  \$state: IssuableState!
  \$search: String
  \$sort: WorkItemSort!

) {
  group(fullPath: \$path) {
    id
    fullPath
    workItems(
      first: \$first
      after: \$after
      includeDescendants: \$includeDescendants
      state: \$state
      search: \$search
      sort: \$sort

    ) {
      nodes { $_publicWorkItemSummaryFields }
      pageInfo { hasNextPage endCursor }
    }
  }
}
''';

final _publicProjectWorkItemQuery =
    '''
query MobileProjectWorkItem(\$path: ID!, \$iid: String!) {
  project(fullPath: \$path) {
    id
    fullPath
    workItems(first: 2, iid: \$iid) {
      nodes { ${_publicWorkItemDetailFields()} }
      pageInfo { hasNextPage endCursor }
    }
  }
}
''';

final _publicNamespaceWorkItemQuery =
    '''
query MobileNamespaceWorkItem(\$path: ID!, \$iid: String!) {
  namespace(fullPath: \$path) {
    id
    fullPath
    workItem(iid: \$iid) { ${_publicWorkItemDetailFields()} }
  }
}
''';

const _publicNamespaceWorkItemTypesQuery = r'''
query MobileNamespaceWorkItemTypes($path: ID!, $first: Int!, $after: String) {
  namespace(fullPath: $path) {
    id
    fullPath
    workItemTypes(first: $first, after: $after) {
      nodes {
        id
        name
        enabled
        isGroupWorkItemType
        widgetDefinitions { type }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
}
''';

String _publicWorkItemDetailFields() =>
    '''
$_publicWorkItemSummaryFields
description
widgets {
  type
  ... on WorkItemWidgetDescription {
    description
    edited
    lastEditedAt
  }
  ... on WorkItemWidgetAssignees {
    assignees(first: 20) {
      nodes { id name username }
      pageInfo { hasNextPage endCursor }
    }
  }
  ... on WorkItemWidgetLabels {
    labels(first: 50) {
      nodes { id title color description textColor }
      pageInfo { hasNextPage endCursor }
    }
  }
  ... on WorkItemWidgetHierarchy {
    hasParent
    hasChildren
    parent { $_publicWorkItemSummaryFields }
    children(first: 20) {
      nodes { $_publicWorkItemSummaryFields }
      pageInfo { hasNextPage endCursor }
    }
  }
  ... on WorkItemWidgetStartAndDueDate {
    startDate
    dueDate
    rollUp
  }
}
''';

const _analyticsFrom = '2026-09-01T00:00:00.000Z';
const _analyticsTo = '2026-10-03T00:00:00.000Z';
const _pipelineAnalyticsQuery = r'''
query MobilePipelineAnalytics($path: ID!, $ref: String!, $fromTime: Time!, $toTime: Time!, $period: AnalyticsAggregationPeriod!, $source: CiPipelineSources) {
  project(fullPath: $path) {
    id
    pipelineAnalytics(ref: $ref, fromTime: $fromTime, toTime: $toTime, source: $source) {
      aggregate {
        label
        all: count
        success: count(status: SUCCESS)
        failed: count(status: FAILED)
        other: count(status: OTHER)
        durationStatistics { p50 p95 }
      }
      timeSeries(period: $period) {
        label
        all: count
        success: count(status: SUCCESS)
        failed: count(status: FAILED)
        other: count(status: OTHER)
        durationStatistics { p50 p95 }
      }
    }
  }
}
''';
const _codeCoverageSummaryQuery = r'''
query MobileCodeCoverageSummary($path: ID!) {
  project(fullPath: $path) {
    id
    codeCoverageSummary { averageCoverage coverageCount lastUpdatedOn }
  }
}
''';
const _incidentStatusQuery = r'''
query MobileIncidentStatus($path: ID!, $iid: String!) {
  project(fullPath: $path) {
    id
    issues(iids: [$iid], types: [INCIDENT], first: 2) {
      nodes { id iid projectId state severity escalationStatus updatedAt }
      pageInfo { hasNextPage }
    }
  }
}
''';
const _pipelineGraphQuery = r'''
query MobilePipelineGraph($path: ID!, $pipeline: CiPipelineID!, $after: String) {
  project(fullPath: $path) {
    id
    pipeline(id: $pipeline) {
      id iid
      stages(first: 100) { nodes { name } pageInfo { hasNextPage } }
      jobs(first: 20, after: $after) {
        nodes {
          id name status kind retried schedulingType stage { name }
          needs(first: 100) {
            nodes { name }
            pageInfo { hasNextPage endCursor }
          }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}
''';

const _publicWorkItemAttributeIdentityFields = r'''
id
iid
project { id fullPath }
namespace { id fullPath }
''';

final _publicWorkItemStatusAttributeQuery =
    '''
query MobileWorkItemStatusAttribute(\$id: WorkItemID!) {
  workItem(id: \$id) {
    $_publicWorkItemAttributeIdentityFields
    widgets {
      type
      ... on WorkItemWidgetStatus {
        status { id name iconName color category }
      }
    }
  }
}
''';

final _publicWorkItemMilestoneAttributeQuery =
    '''
query MobileWorkItemMilestoneAttribute(\$id: WorkItemID!) {
  workItem(id: \$id) {
    $_publicWorkItemAttributeIdentityFields
    widgets {
      type
      ... on WorkItemWidgetMilestone {
        milestone {
          id iid title state webPath dueDate startDate
          project { id fullPath }
          group { id fullPath }
        }
      }
    }
  }
}
''';

final _publicWorkItemWeightAttributeQuery =
    '''
query MobileWorkItemWeightAttribute(\$id: WorkItemID!) {
  workItem(id: \$id) {
    $_publicWorkItemAttributeIdentityFields
    widgets {
      type
      ... on WorkItemWidgetWeight {
        weight
        rolledUpWeight
        rolledUpCompletedWeight
      }
    }
  }
}
''';

final _publicWorkItemIterationAttributeQuery =
    '''
query MobileWorkItemIterationAttribute(\$id: WorkItemID!) {
  workItem(id: \$id) {
    $_publicWorkItemAttributeIdentityFields
    widgets {
      type
      ... on WorkItemWidgetIteration {
        iteration {
          id iid title state webUrl startDate dueDate
          group { id fullPath }
          iterationCadence { id title }
        }
      }
    }
  }
}
''';

final _publicWorkItemHealthAttributeQuery =
    '''
query MobileWorkItemHealthAttribute(\$id: WorkItemID!) {
  workItem(id: \$id) {
    $_publicWorkItemAttributeIdentityFields
    widgets {
      type
      ... on WorkItemWidgetHealthStatus {
        healthStatus
        rolledUpHealthStatus { healthStatus count }
      }
    }
  }
}
''';

final _publicWorkItemTimeTrackingAttributeQuery =
    '''
query MobileWorkItemTimeTrackingAttribute(\$id: WorkItemID!) {
  workItem(id: \$id) {
    $_publicWorkItemAttributeIdentityFields
    widgets {
      type
      ... on WorkItemWidgetTimeTracking {
        timeEstimate
        totalTimeSpent
        humanReadableAttributes { timeEstimate totalTimeSpent }
      }
    }
  }
}
''';

final _publicWorkItemDevelopmentAttributeQuery =
    '''
query MobileWorkItemDevelopmentAttribute(\$id: WorkItemID!) {
  workItem(id: \$id) {
    $_publicWorkItemAttributeIdentityFields
    widgets {
      type
      ... on WorkItemWidgetDevelopment {
        closingMergeRequestsCount
        willAutoCloseByMergeRequest
      }
    }
  }
}
''';

const _publicWorkItemActivityIdentityFields = r'''
id
iid
project { id fullPath }
namespace { id fullPath }
''';

const _publicWorkItemActivityNoteFields = r'''
id
system
systemNoteIconName
body
createdAt
updatedAt
author { id name username }
''';

final _publicWorkItemActivityWriteAccessQuery =
    '''
query MobileWorkItemActivityWriteAccess(\$id: WorkItemID!) {
  currentUser { id }
  workItem(id: \$id) {
    $_publicWorkItemActivityIdentityFields
    userPermissions { createNote }
    widgets {
      type
      ... on WorkItemWidgetNotes { discussionLocked }
    }
  }
}
''';

final _publicWorkItemActivityQuery =
    '''
query MobileWorkItemActivity(
  \$id: WorkItemID!
  \$after: String
  \$filter: NotesFilterType!
  \$sort: WorkItemDiscussionsSort!
) {
  workItem(id: \$id) {
    $_publicWorkItemActivityIdentityFields
    widgets {
      type
      ... on WorkItemWidgetNotes {
        discussions(
          first: 20
          after: \$after
          filter: \$filter
          sort: \$sort
        ) {
          nodes {
            id
            replyId
            createdAt
            notes(first: 20) {
              nodes { $_publicWorkItemActivityNoteFields }
              pageInfo { hasNextPage endCursor }
            }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
}
''';

final _publicWorkItemActivityLegacyQuery =
    '''
query MobileWorkItemActivity(\$id: WorkItemID!, \$after: String) {
  workItem(id: \$id) {
    $_publicWorkItemActivityIdentityFields
    widgets {
      type
      ... on WorkItemWidgetNotes {
        discussions(first: 20, after: \$after) {
          nodes {
            id
            replyId
            createdAt
            notes(first: 20) {
              nodes { $_publicWorkItemActivityNoteFields }
              pageInfo { hasNextPage endCursor }
            }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
}
''';

final _publicWorkItemDiscussionNotesQuery =
    '''
query MobileWorkItemDiscussionNotes(
  \$workItemId: WorkItemID!
  \$anchorNoteId: NoteID!
  \$after: String
) {
  workItem(id: \$workItemId) {
    $_publicWorkItemActivityIdentityFields
  }
  anchor: note(id: \$anchorNoteId) {
    id
    project { id fullPath }
    discussion {
      id
      replyId
      createdAt
      notes(first: 20, after: \$after) {
        nodes { $_publicWorkItemActivityNoteFields }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}
''';

Future<void> main() async {
  final checks = <Map<String, Object?>>[];
  var failed = false, sawProjectsLink = false;
  String? discoveredSnippetGraphId;
  SnippetGraphSnapshot? snippetSnapshot;
  WorkItemGraphSummary? discoveredPublicWorkItem;
  String? discoveredPublicGroupNamespaceId;
  String? discoveredPublicGroupItemsCursor;
  WorkItemGraphSummary? discoveredPublicGroupWorkItem;
  var groupItemsFirstCount = 0;
  var groupItemsNextCount = 0;
  final publicGroupItemIids = <int>[];
  var projectActivityFirstDiscussions = 0;
  var groupActivityFirstDiscussions = 0;
  var groupActivityNextDiscussions = 0;
  var groupActivitySystemNotes = 0;
  var nestedActivityNotes = 0;
  var nestedActivityContinuationExercised = false;
  var activityConfigurationCount = 0;
  var activityContinuationCount = 0;
  var groupNewestContinuationExercised = false;
  RegistryPackage? publicRegistryPackage;
  RegistryPackageFile? publicRegistryFile;
  var packageDownloadedBytes = 0;
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        final restRead =
            const ['GET', 'HEAD'].contains(request.method) &&
            request.uri.scheme == 'https' &&
            request.uri.host == 'gitlab.com' &&
            request.uri.path.startsWith('/api/v4/');
        final graphRead =
            _isExactPublicPipelineGraph(request) ||
            _isExactPublicIncidentGraph(request) ||
            _isExactPublicAnalyticsGraph(request) ||
            _isExactPublicSnippetGraph(request, discoveredSnippetGraphId) ||
            _isExactPublicWorkItemGraph(
              request,
              issuedGroupCursor: discoveredPublicGroupItemsCursor,
            ) ||
            _isExactPublicWorkItemAttributeGraph(
              request,
              discoveredPublicWorkItem?.id,
            ) ||
            _isExactPublicWorkItemStateGraph(request, {
              if (discoveredPublicWorkItem != null)
                discoveredPublicWorkItem!.id,
              if (discoveredPublicGroupWorkItem != null)
                discoveredPublicGroupWorkItem!.id,
            }) ||
            _isExactPublicWorkItemActivityGraph(
              request,
              discoveredPublicWorkItem?.id,
              discoveredPublicGroupWorkItem?.id,
            );
        if (!restRead && !graphRead) {
          handler.reject(
            DioException(
              requestOptions: request,
              error: 'Public smoke permits only GitLab public reads',
            ),
          );
          return;
        }
        request.headers.removeWhere((key, _) {
          final lower = key.toLowerCase();
          return lower == 'cookie' ||
              lower == 'cookie2' ||
              lower == 'private-token' ||
              lower == 'job-token' ||
              lower == 'x-gitlab-token' ||
              lower.endsWith('authorization');
        });
        handler.next(request);
      },
      onResponse: (response, handler) {
        if (response.requestOptions.uri.path == '/api/v4/projects' &&
            response.headers.map.containsKey('link')) {
          sawProjectsLink = true;
        }
        handler.next(response);
      },
    ),
  );
  final api = GitLabApi(
    instance: GitLabInstance.parse('https://gitlab.com'),
    token: 'unused-public-probe-placeholder',
    dio: dio,
  );
  void require(bool value) {
    if (!value) {
      throw const FormatException('Public contract assertion');
    }
  }

  void requireActivityPage(
    WorkItemActivityPage page,
    WorkItemGraphSummary expected,
    WorkItemActivityFilter filter,
    WorkItemActivityOrder order,
  ) {
    require(
      page.controlsSupported &&
          page.filter == filter &&
          page.order == order &&
          page.snapshot.workItemId == expected.id &&
          page.snapshot.iid == expected.iid &&
          page.snapshot.project?.id == expected.project?.id &&
          page.snapshot.project?.fullPath == expected.project?.fullPath &&
          page.snapshot.namespace?.id == expected.namespace?.id &&
          page.snapshot.namespace?.fullPath == expected.namespace?.fullPath &&
          page.snapshot.availability == WorkItemActivityAvailability.present &&
          page.snapshot.discussions.availability ==
              WorkItemActivityConnectionAvailability.present,
    );
    final discussions = page.snapshot.discussions.items;
    require(discussions.length <= 20);
    for (var index = 1; index < discussions.length; index++) {
      final previous = discussions[index - 1].createdAt;
      final current = discussions[index].createdAt;
      require(
        order == WorkItemActivityOrder.oldestFirst
            ? !previous.isAfter(current)
            : !previous.isBefore(current),
      );
    }
    final notes = discussions.expand((discussion) => discussion.notes.items);
    if (filter == WorkItemActivityFilter.comments) {
      require(notes.every((note) => !note.system));
    } else if (filter == WorkItemActivityFilter.history) {
      require(notes.every((note) => note.system));
    }
  }

  Future<void> check(String name, Future<void> Function() run) async {
    final clock = Stopwatch()..start();
    try {
      await run();
      checks.add({
        'name': name,
        'status': 'PASS',
        'milliseconds': clock.elapsedMilliseconds,
      });
      stdout.writeln('PASS $name');
    } catch (error) {
      failed = true;
      final kind = error is ApiFailure
          ? '${error.kind.name}:${error.status}'
          : error.runtimeType.toString();
      checks.add({'name': name, 'status': 'FAIL', 'error_type': kind});
      stdout.writeln('FAIL $name ($kind)');
    }
  }

  Future<void> expectedGap(
    String name,
    Future<void> Function() run, {
    required int status,
  }) async {
    final clock = Stopwatch()..start();
    try {
      await run();
      failed = true;
      checks.add({
        'name': name,
        'status': 'FAIL',
        'error_type': 'unexpectedly_available_anonymously',
      });
      stdout.writeln('FAIL $name (unexpectedly available anonymously)');
    } on ApiFailure catch (error) {
      if (error.status != status) {
        failed = true;
        checks.add({
          'name': name,
          'status': 'FAIL',
          'error_type': '${error.kind.name}:${error.status}',
        });
        stdout.writeln('FAIL $name (${error.kind.name}:${error.status})');
        return;
      }
      checks.add({
        'name': name,
        'status': 'GAP',
        'expected_status': status,
        'milliseconds': clock.elapsedMilliseconds,
      });
      stdout.writeln('GAP $name (expected HTTP $status)');
    }
  }

  try {
    await check('public.project.numeric_id', () async {
      final project = await api.project('$_publicProjectId');
      require(
        project.path == _publicProjectPath && project.visibility == 'public',
      );
    });
    await check('public.project.encoded_namespace', () async {
      require((await api.project(_publicProjectPath)).id == _publicProjectId);
    });
    await check('public.repository.paged_topological_graph', () async {
      const query = {
        'ref_name': '0e1298e339bb5d23bdf80c31eef5d830d8716fe2',
        'order': 'topo',
        'per_page': '5',
      };
      final first = await api.records([
        'projects',
        '$_publicProjectId',
        'repository',
        'commits',
      ], query: query);
      require(first.items.length == 5 && first.next != null);
      final second = await api.records(
        ['projects', '$_publicProjectId', 'repository', 'commits'],
        query: query,
        next: first.next,
      );
      require(second.items.length == 5);
      final graph = RepositoryGraphLayout.fromJson([
        ...first.items,
        ...second.items,
      ]);
      require(graph.rows.length == 10 && graph.laneCount >= 1);
      require(graph.rows.any((row) => row.commit.parentIds.length > 1));
    });
    await check('public.pipeline.actual_dependency_graph', () async {
      final project = await api.project('$_publicProjectId');
      final graph = PipelineGraphPageData.fromJson(
        await api.pipelineGraphPage(project, _publicPipelineId),
      );
      final android = graph.jobs.singleWhere(
        (job) => job.name == 'android_debug',
      );
      require(graph.pipelineId == _publicPipelineId);
      require(android.kind == 'BUILD' && android.needs.length == 4);
      require(
        android.needs.toSet().containsAll(const {
          'public_api_smoke',
          'native_templates',
          'flutter_checks',
          'python_checks',
        }),
      );
      final resolved = resolvePipelineGraphNeeds(graph.jobs)[android.id]!;
      require(
        resolved.length == 4 &&
            resolved.every(
              (need) => need.state == PipelineGraphNeedState.resolved,
            ),
      );
    });
    await check('public.typed_task_incident_lists', () async {
      for (final type in ['task', 'incident']) {
        final page = await api.records(
          ['projects', '$_publicProjectId', 'issues'],
          query: {'scope': 'all', 'state': 'all', 'issue_type': type},
        );
        require(
          page.items.every(
            (issue) =>
                issue['issue_type'] == type &&
                issue['project_id'] == _publicProjectId,
          ),
        );
      }
    });
    await check('public.incident.lifecycle_query_schema_only', () async {
      // Public issue #1 is an ordinary issue, so the INCIDENT-only connection
      // is empty. This proves the fixed operation parses, not a live mutation.
      final project = await api.project('$_publicProjectId');
      try {
        await api.incidentStatus(project, 1);
      } on ApiFailure catch (failure) {
        require(
          failure.kind == FailureKind.invisible && failure.status == null,
        );
        return;
      }
      throw const FormatException('Ordinary issue returned as Incident');
    });
    await check('public.analytics.sanitized_repository_models', () async {
      final project = await api.project('$_publicProjectId');
      final contributors = await api.repositoryContributors(
        project,
        ref: 'main',
      );
      require(contributors.items.isNotEmpty);
      require(
        contributors.items.every(
          (row) => row.commits >= 0 && row.displayName.isNotEmpty,
        ),
      );
      final activity = await api.repositoryActivity(
        project,
        ref: 'main',
        from: DateTime.parse(_analyticsFrom),
        to: DateTime.parse(_analyticsTo),
      );
      require(activity.items.isNotEmpty);
      require(
        activity.items.every(
          (row) =>
              row.parentCount >= 0 &&
              !row.committedAt.isBefore(DateTime.parse(_analyticsFrom)) &&
              row.committedAt.isBefore(DateTime.parse(_analyticsTo)),
        ),
      );
    });
    await check('public.analytics.actual_pipeline_series', () async {
      final project = await api.project('$_publicProjectId');
      final analytics = await api.pipelineAnalytics(
        project,
        ref: 'main',
        from: DateTime.parse(_analyticsFrom),
        to: DateTime.parse(_analyticsTo),
      );
      require(analytics.buckets.isNotEmpty);
      require(
        analytics.buckets.any(
          (bucket) => bucket.total != null && bucket.total! > BigInt.zero,
        ),
      );
      require(
        analytics.aggregate?.total != null &&
            analytics.aggregate!.total! > BigInt.zero,
      );
    });
    await check(
      'public.analytics.actual_source_filter_and_aggregate',
      () async {
        final project = await api.project('$_publicProjectId');
        final analytics = await api.pipelineAnalytics(
          project,
          ref: 'main',
          from: DateTime.parse(_analyticsFrom),
          to: DateTime.parse(_analyticsTo),
          source: AnalyticsPipelineSource.push,
        );
        require(
          analytics.aggregate?.total != null &&
              analytics.aggregate!.total! > BigInt.zero,
        );
        require(analytics.aggregate?.p50Seconds != null);
      },
    );
    await check('public.analytics.coverage_query_nullable_contract', () async {
      final project = await api.project('$_publicProjectId');
      final summary = await api.codeCoverageSummary(project);
      // A public project may not expose coverage; null is never treated as 0%.
      require(
        summary?.averageCoverage == null ||
            (summary!.averageCoverage! >= 0 && summary.averageCoverage! <= 100),
      );
    });
    await check('public.registry.list_detail_files', () async {
      final page = await api.records(
        ['projects', '$_publicProjectId', 'packages'],
        query: const {
          'package_name': 'gitlab-mobile-preview',
          'include_versionless': 'true',
          'order_by': 'created_at',
          'sort': 'desc',
          'per_page': '5',
        },
      );
      require(page.items.isNotEmpty);
      final listed = RegistryPackage.fromJson(page.items.first);
      final detail = RegistryPackage.fromJson(
        await api.record([
          'projects',
          '$_publicProjectId',
          'packages',
          '${listed.id}',
        ]),
      );
      final filesPage = await api.records(
        [
          'projects',
          '$_publicProjectId',
          'packages',
          '${listed.id}',
          'package_files',
        ],
        query: const {
          'order_by': 'created_at',
          'sort': 'desc',
          'per_page': '20',
        },
      );
      final files = filesPage.items
          .map(RegistryPackageFile.fromJson)
          .toList(growable: false);
      require(detail.id == listed.id && detail.name == 'gitlab-mobile-preview');
      require(files.any((file) => file.name == 'SHA256SUMS'));
      require(files.any((file) => file.name.endsWith('-debug.apk')));
    });
    await check('public.registry.numeric_file_download_integrity', () async {
      const packageId = 71215360;
      const fileId = 361672601;
      const checksum =
          'e72c27dcd464ea3bda6b0b3dda910ac3a4ee551f91387c17f1c2abe9dcf1ca88';
      final verifiedPackage = RegistryPackage.fromJson(
        await api.record([
          'projects',
          '$_publicProjectId',
          'packages',
          '$packageId',
        ]),
      );
      require(verifiedPackage.id == packageId);
      final files = await api.records(
        [
          'projects',
          '$_publicProjectId',
          'packages',
          '$packageId',
          'package_files',
        ],
        query: const {'per_page': '100'},
      );
      final selected = files.items
          .map(RegistryPackageFile.fromJson)
          .singleWhere((file) => file.id == fileId);
      final file = await api.packageFileForDownload(
        _publicProjectId,
        verifiedPackage,
        selected,
        isCurrent: () => true,
      );
      // Only the small public checksum manifest is fetched, never the APK.
      require(
        file.id == fileId &&
            file.name == 'SHA256SUMS' &&
            file.size == 185 &&
            file.sha256 == checksum,
      );
      publicRegistryPackage = verifiedPackage;
      publicRegistryFile = file;
      final directory = await Directory.systemTemp.createTemp(
        'public-package-',
      );
      final target = File('${directory.path}/checksum-manifest');
      IOSink? sink;
      var sinkClosed = false;
      try {
        sink = target.openWrite();
        final downloaded = await api.downloadPackageFile(
          _publicProjectId,
          verifiedPackage.id,
          file.id,
          sink: sink,
          fileName: file.name,
          maxBytes: 4096,
        );
        await sink.close();
        sinkClosed = true;
        final bytes = await target.readAsBytes();
        require(downloaded.fileName == file.name);
        require(
          downloaded.bytesWritten == file.size && bytes.length == file.size,
        );
        require(sha256.convert(bytes).toString() == file.sha256);
        packageDownloadedBytes = bytes.length;
      } finally {
        try {
          if (!sinkClosed) await sink?.close();
        } finally {
          await directory.delete(recursive: true);
        }
      }
    });
    await check('public.snippet.actual_multifile_metadata_not_crud', () async {
      final response = await api.record([
        'projects',
        '278964',
        'snippets',
        '6030720',
      ]);
      require(response['files'] is List<dynamic>);
      final snippets = <ProjectSnippet>[ProjectSnippet.fromJson(response)];
      final snippet = snippets.single..requireProject(278964);
      require(snippet.visibility == 'public' && snippet.hasExplicitFiles);
      require(snippet.filePaths.length > 1 && !snippet.canUseLegacyRaw);
      require(snippet.filePaths.every((path) => path.trim().isNotEmpty));
    });
    await check('public.snippet.server_identity_and_lazy_markdown', () async {
      final project = await api.project('$_publicSnippetProjectId');
      require(
        project.path == _publicSnippetProjectPath &&
            project.visibility == 'public',
      );
      final snippet = ProjectSnippet.fromJson(
        await api.record([
          'projects',
          '$_publicSnippetProjectId',
          'snippets',
          '$_publicSnippetId',
        ]),
      );
      final snapshot = await api.projectSnippetSnapshot(project, snippet);
      require(
        snapshot.projectId == _publicSnippetProjectId &&
            snapshot.snippetId == _publicSnippetId &&
            snapshot.filePaths.length == 3,
      );
      // This value comes from the production client's validated server lookup.
      // The read allowlist never constructs a Snippet Global ID.
      discoveredSnippetGraphId = snapshot.graphId;
      snippetSnapshot = snapshot;
      final blob = await api.snippetBlob(
        project,
        snapshot,
        path: _publicSnippetPaths.first,
      );
      require(
        blob.path == _publicSnippetPaths.first &&
            blob.availability == SnippetBlobAvailability.text &&
            blob.content != null &&
            utf8.encode(blob.content!).length == blob.size,
      );
    });
    await check('public.snippet.lazy_nondefault_file', () async {
      final snapshot = snippetSnapshot;
      require(snapshot != null);
      final project = await api.project('$_publicSnippetProjectId');
      final blob = await api.snippetBlob(
        project,
        snapshot!,
        path: _publicSnippetPaths.last,
      );
      require(
        blob.path == _publicSnippetPaths.last &&
            blob.availability == SnippetBlobAvailability.text &&
            blob.content != null &&
            utf8.encode(blob.content!).length == blob.size,
      );
    });
    await check('public.work_items.project_page_identity', () async {
      final project = await api.project('$_publicSnippetProjectId');
      final page = await api.projectWorkItems(project);
      require(page.items.isNotEmpty && page.items.length <= 20);
      require(page.nextCursor != null);
      require(
        page.items.every(
          (item) => item.project?.fullPath == project.path && item.iid > 0,
        ),
      );
    });
    await check('public.work_items.actual_dynamic_widgets', () async {
      final project = await api.project('$_publicSnippetProjectId');
      final detail = await api.projectWorkItem(project, _publicWorkItemIid);
      require(detail.summary.iid == _publicWorkItemIid);
      require(detail.summary.project?.fullPath == project.path);
      require(detail.widgetsAvailable && detail.widgetTypes.isNotEmpty);
      require(
        detail.summary.type.id.isNotEmpty &&
            detail.summary.type.name.isNotEmpty,
      );
      require(detail.description != null && detail.labels?.labels != null);
      // Bind attribute reads to the production-validated public response.
      discoveredPublicWorkItem = detail.summary;
    });
    await check(
      'public.work_items.project_read_only_state_permission',
      () async {
        final expected = discoveredPublicWorkItem;
        require(expected != null);
        final state = await api.workItemState(expected!);
        require(state.id == expected.id && state.iid == expected.iid);
        require(state.state.name.toUpperCase() == expected.state);
        require(!state.canUpdate);
      },
    );
    await check(
      'public.work_items.project_read_only_note_permission',
      () async {
        final expected = discoveredPublicWorkItem;
        require(expected != null);
        final access = await api.workItemActivityWriteAccess(expected!);
        require(!access.canCreateNote && access.commentTarget == null);
      },
    );
    for (final kind in WorkItemAttributeKind.values) {
      await check('public.work_items.attribute_${kind.name}', () async {
        final expected = discoveredPublicWorkItem;
        require(expected != null);
        final attribute = await api.workItemAttribute(expected!, kind);
        require(
          attribute.workItemId == expected.id &&
              attribute.iid == expected.iid &&
              attribute.kind == kind &&
              attribute.project?.id == expected.project?.id &&
              attribute.project?.fullPath == expected.project?.fullPath &&
              attribute.namespace?.id == expected.namespace?.id &&
              attribute.namespace?.fullPath == expected.namespace?.fullPath,
        );
        require(
          attribute.availability == WorkItemAttributeAvailability.present &&
              attribute.value != null,
        );
      });
    }
    await check('public.work_items.project_activity_controls', () async {
      final expected = discoveredPublicWorkItem;
      require(expected != null);
      for (final filter in WorkItemActivityFilter.values) {
        for (final order in WorkItemActivityOrder.values) {
          final page = await api.workItemActivity(
            expected!,
            filter: filter,
            order: order,
          );
          requireActivityPage(page, expected, filter, order);
          require(
            page.nextNotesByDiscussion.keys.every(
              page.snapshot.discussions.items
                  .map((item) => item.id)
                  .toSet()
                  .contains,
            ),
          );
          if (filter == WorkItemActivityFilter.all &&
              order == WorkItemActivityOrder.oldestFirst) {
            projectActivityFirstDiscussions =
                page.snapshot.discussions.items.length;
          }
          activityConfigurationCount++;
        }
      }
    });
    await check('public.work_items.server_type_capabilities', () async {
      final page = await api.namespaceWorkItemTypes(_publicSnippetProjectPath);
      require(page.namespace.fullPath == _publicSnippetProjectPath);
      require(page.items.isNotEmpty && page.items.length <= 20);
      require(page.items.any((type) => type.enabled));
      require(
        page.items.map((type) => type.type.id).toSet().length ==
            page.items.length,
      );
    });
    await check('public.work_items.group_owned_detail', () async {
      final detail = await api.namespaceWorkItem(
        _publicGroupWorkItemPath,
        _publicGroupWorkItemIid,
      );
      require(detail.summary.iid == _publicGroupWorkItemIid);
      require(detail.summary.project == null);
      require(detail.summary.namespace?.fullPath == _publicGroupWorkItemPath);
      require(detail.widgetsAvailable);
      discoveredPublicGroupNamespaceId = detail.summary.namespace?.id;
      discoveredPublicGroupWorkItem = detail.summary;
    });
    await check('public.work_items.group_read_only_state_permission', () async {
      final expected = discoveredPublicGroupWorkItem;
      require(expected != null);
      final state = await api.workItemState(expected!);
      require(state.id == expected.id && state.iid == expected.iid);
      require(state.state.name.toUpperCase() == expected.state);
      require(!state.canUpdate);
    });
    await check('public.work_items.group_read_only_note_permission', () async {
      final expected = discoveredPublicGroupWorkItem;
      require(expected != null);
      final access = await api.workItemActivityWriteAccess(expected!);
      require(!access.canCreateNote && access.commentTarget == null);
    });
    await check('public.work_items.group_owned_pages', () async {
      final first = await api.groupWorkItems(_publicGroupWorkItemPath);
      require(first.group.fullPath == _publicGroupWorkItemPath);
      require(first.group.id == discoveredPublicGroupNamespaceId);
      require(first.items.length == 20 && first.nextCursor != null);
      require(
        first.items.every(
          (item) =>
              item.project == null &&
              item.namespace?.id == first.group.id &&
              item.namespace?.fullPath == first.group.fullPath,
        ),
      );
      groupItemsFirstCount = first.items.length;
      publicGroupItemIids.addAll(first.items.map((item) => item.iid));
      discoveredPublicGroupItemsCursor = first.nextCursor;
      final next = await api.groupWorkItems(
        _publicGroupWorkItemPath,
        expectedGroupId: first.group.id,
        after: discoveredPublicGroupItemsCursor,
        filter: first.filter,
        previousFilter: first.filter,
      );
      require(next.group.id == first.group.id);
      require(next.items.length == 20);
      require(next.nextCursor != discoveredPublicGroupItemsCursor);
      final ids = first.items.map((item) => item.id).toSet();
      final iids = first.items.map((item) => item.iid).toSet();
      require(
        next.items.every(
          (item) =>
              item.project == null &&
              item.namespace?.id == first.group.id &&
              item.namespace?.fullPath == first.group.fullPath &&
              ids.add(item.id) &&
              iids.add(item.iid),
        ),
      );
      groupItemsNextCount = next.items.length;
      publicGroupItemIids.addAll(next.items.map((item) => item.iid));
      discoveredPublicGroupItemsCursor = null;
    });
    await check('public.groups.exact_path_resolution', () async {
      final group = await api.groupByPath(_publicGroupWorkItemPath);
      require(group['id'] is int && (group['id'] as int) > 0);
      require(group['full_path'] == _publicGroupWorkItemPath);
      require(group['visibility'] == 'public');
    });
    await check('public.work_items.group_type_capabilities', () async {
      final owner = discoveredPublicGroupNamespaceId;
      require(owner != null);
      final page = await api.namespaceWorkItemTypes(
        _publicGroupWorkItemPath,
        expectedNamespaceId: owner,
      );
      require(page.namespace.id == owner);
      require(page.namespace.fullPath == _publicGroupWorkItemPath);
      require(page.items.isNotEmpty && page.items.length <= 20);
      require(
        page.items.any((type) => type.enabled && type.isGroupWorkItemType),
      );
    });
    await check('public.work_items.group_activity_controls', () async {
      final expected = discoveredPublicGroupWorkItem;
      require(expected != null);
      final groupExpected = expected!;
      WorkItemActivityPage? newestFirst;
      for (final filter in WorkItemActivityFilter.values) {
        for (final order in WorkItemActivityOrder.values) {
          final page = await api.workItemActivity(
            groupExpected,
            filter: filter,
            order: order,
          );
          requireActivityPage(page, groupExpected, filter, order);
          if (filter == WorkItemActivityFilter.history) {
            groupActivitySystemNotes += page.snapshot.discussions.items
                .expand((discussion) => discussion.notes.items)
                .length;
          }
          if (filter == WorkItemActivityFilter.all &&
              order == WorkItemActivityOrder.oldestFirst) {
            groupActivityFirstDiscussions =
                page.snapshot.discussions.items.length;
          }
          if (filter == WorkItemActivityFilter.all &&
              order == WorkItemActivityOrder.newestFirst) {
            newestFirst = page;
          }
          activityConfigurationCount++;
        }
      }
      require(newestFirst != null);
      final first = newestFirst!;
      final firstDiscussions = first.snapshot.discussions.items;
      final firstIds = firstDiscussions.map((item) => item.id).toSet();
      require(firstIds.length == firstDiscussions.length);
      WorkItemActivityPage? next;
      if (first.nextDiscussions != null) {
        next = await api.workItemActivityNext(first.nextDiscussions!);
        requireActivityPage(
          next,
          groupExpected,
          WorkItemActivityFilter.all,
          WorkItemActivityOrder.newestFirst,
        );
        activityContinuationCount++;
        groupNewestContinuationExercised = true;
        final nextDiscussions = next.snapshot.discussions.items;
        groupActivityNextDiscussions = nextDiscussions.length;
        require(nextDiscussions.every((item) => !firstIds.contains(item.id)));
        if (firstDiscussions.isNotEmpty && nextDiscussions.isNotEmpty) {
          require(
            !firstDiscussions.last.createdAt.isBefore(
              nextDiscussions.first.createdAt,
            ),
          );
        }
      }

      final nested = <String, WorkItemDiscussionNotesContinuation>{
        ...first.nextNotesByDiscussion,
        if (next != null) ...next.nextNotesByDiscussion,
      };
      if (nested.isNotEmpty) {
        final entry = nested.entries.first;
        final notes = await api.workItemDiscussionNotesNext(entry.value);
        require(
          notes.workItemId == groupExpected.id &&
              notes.discussionId == entry.key &&
              notes.notes.availability ==
                  WorkItemActivityConnectionAvailability.present &&
              notes.notes.items.isNotEmpty,
        );
        nestedActivityContinuationExercised = true;
        nestedActivityNotes = notes.notes.items.length;
        activityContinuationCount++;
      }
    });
    await check('public.work_items.group_parent_optional_metadata', () async {
      final namespaceId = discoveredPublicGroupNamespaceId;
      require(namespaceId != null);
      final detail = await api.namespaceWorkItem(
        _publicGroupWorkItemPath,
        _publicGroupParentWorkItemIid,
        expectedNamespaceId: namespaceId,
      );
      require(detail.summary.iid == _publicGroupParentWorkItemIid);
      require(detail.summary.project == null);
      require(detail.summary.namespace?.id == namespaceId);
      require(detail.summary.namespace?.fullPath == _publicGroupWorkItemPath);
      require(detail.widgetsAvailable && detail.assignees?.assignees != null);
    });
    await expectedGap('public.boards.authentication_required', () async {
      await api.records(
        ['projects', '$_publicProjectId', 'boards'],
        query: const {'per_page': '1'},
      );
    }, status: 401);
    await check('public.projects.real_link_header_and_second_page', () async {
      const query = {
        'per_page': '1',
        'search': 'gitlab',
        'order_by': 'id',
        'sort': 'asc',
      };
      final first = await api.records(['projects'], query: query);
      require(first.items.length == 1 && first.next != null && sawProjectsLink);
      require(first.next!.queryParameters['search'] == 'gitlab');
      final next = await api.records(
        ['projects'],
        query: query,
        next: first.next,
      );
      require(
        next.items.length == 1 &&
            next.items.first['id'] != first.items.first['id'],
      );
    });
    await check('public.repository.fixed_sha_tree_readme', () async {
      final project = await api.project('86648389');
      final sha = await api.defaultBranchSha(project);
      final tree = await api.tree(project.id, sha);
      require(tree.items.any((row) => row.name == 'README.md'));
      require(
        (await api.textFile(
          project.id,
          sha,
          'README.md',
        )).contains('GitLab Mobile'),
      );
    });
    await check('public.metadata.branches_tags_releases', () async {
      require(
        (await api.records([
          'projects',
          '86648389',
          'repository',
          'branches',
        ])).items.isNotEmpty,
      );
      await api.records(['projects', '86648389', 'repository', 'tags']);
      await api.records(['projects', '86648389', 'releases']);
    });
    await check('public.compare.fixed_revisions', () async {
      final result = await api.record(
        ['projects', '86648389', 'repository', 'compare'],
        query: {
          'from': '911a953ee92b2e3ddd3e526c3691e6495c311ad3',
          'to': '0e1298e339bb5d23bdf80c31eef5d830d8716fe2',
          'straight': 'true',
          'unidiff': 'true',
        },
      );
      require(
        result['commits'] is List &&
            result['diffs'] is List &&
            result['compare_same_ref'] == false,
      );
      final files = result['diffs'] as List<dynamic>;
      final file = files.cast<Map<String, dynamic>>().firstWhere(
        (row) => row['new_path'] == 'lib/core/workspace_api.dart',
      );
      require(file['collapsed'] != true && file['too_large'] != true);
      final lines = parseUnifiedDiff(file['diff'] as String);
      require(lines.any((line) => line.commentable));
    });
    await check('public.missing_file_is_404_not_auth_failure', () async {
      try {
        await api.fileMetadata(
          _publicProjectId,
          '__nonexistent_public_smoke_fixture_86648389__.txt',
          'main',
        );
      } on ApiFailure catch (error) {
        require(error.status == 404);
        return;
      }
      throw const FormatException('Missing file unexpectedly readable');
    });
  } finally {
    api.close();
    final report = {
      'suite': 'production-Dart-public-read-integration',
      'source_sha': Platform.environment['CI_COMMIT_SHA'],
      'pipeline_id': Platform.environment['CI_PIPELINE_ID'],
      'authentication': 'anonymous; no credential read or sent',
      'writes': 0,
      'status': failed ? 'FAIL' : 'PASS',
      'checks': checks,
      'metrics': {
        'public_package_id': publicRegistryPackage?.id,
        'public_package_file_id': publicRegistryFile?.id,
        'public_package_downloaded_bytes': packageDownloadedBytes,
        'work_item_group_first_rows': groupItemsFirstCount,
        'work_item_group_next_rows': groupItemsNextCount,
        'public_group_owned_item_iids': publicGroupItemIids,
        'work_item_project_activity_first_discussions':
            projectActivityFirstDiscussions,
        'work_item_group_activity_first_discussions':
            groupActivityFirstDiscussions,
        'work_item_group_activity_next_discussions':
            groupActivityNextDiscussions,
        'work_item_group_activity_system_notes': groupActivitySystemNotes,
        'work_item_nested_activity_continuation_exercised':
            nestedActivityContinuationExercised,
        'work_item_nested_activity_notes': nestedActivityNotes,
        'work_item_activity_configuration_count': activityConfigurationCount,
        'work_item_activity_continuation_count': activityContinuationCount,
        'work_item_group_newest_continuation_exercised':
            groupNewestContinuationExercised,
      },
      'gaps': [
        'Issue boards return HTTP 401 to anonymous public reads',
        if (!nestedActivityContinuationExercised)
          'Public Work Item fixtures did not issue a nested note continuation',
        if (!groupNewestContinuationExercised)
          'Public group Work Item newest-first page did not issue an outer continuation',
      ],
      'not_run': [
        'PAT authentication',
        'authenticated issue boards',
        'private project access',
        'snippet CRUD',
        'Task/Incident fixture CRUD and escalation lifecycle mutation',
        'Work Item writes/CRUD and edition-specific widget coverage',
        'live writes/CRUD',
        'Android/iOS device UI',
      ],
    };
    Directory('public-smoke-output').createSync(recursive: true);
    File(
      'public-smoke-output/report.json',
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    stdout.writeln('BEGIN_PUBLIC_SMOKE_REPORT');
    stdout.writeln(jsonEncode(report));
    stdout.writeln('END_PUBLIC_SMOKE_REPORT');
    if (failed) {
      exitCode = 1;
    }
  }
}

bool _isExactPublicPipelineGraph(RequestOptions request) {
  if (request.method != 'POST' ||
      request.uri != Uri.parse('https://gitlab.com/api/graphql')) {
    return false;
  }
  final body = request.data;
  if (body is! Map ||
      body.length != 2 ||
      !body.containsKey('query') ||
      !body.containsKey('variables') ||
      body['query'] != _pipelineGraphQuery) {
    return false;
  }
  final variables = body['variables'];
  return variables is Map &&
      variables.length == 3 &&
      variables['path'] == _publicProjectPath &&
      variables['pipeline'] == 'gid://gitlab/Ci::Pipeline/$_publicPipelineId' &&
      variables.containsKey('after') &&
      variables['after'] == null;
}

bool _isExactPublicIncidentGraph(RequestOptions request) {
  if (request.method != 'POST' ||
      request.uri != Uri.parse('https://gitlab.com/api/graphql')) {
    return false;
  }
  final body = request.data;
  if (body is! Map ||
      body.length != 2 ||
      body['query'] != _incidentStatusQuery) {
    return false;
  }
  final variables = body['variables'];
  return variables is Map &&
      variables.length == 2 &&
      variables['path'] == _publicProjectPath &&
      variables['iid'] == '1';
}

bool _isExactPublicAnalyticsGraph(RequestOptions request) {
  if (request.method != 'POST' ||
      request.uri != Uri.parse('https://gitlab.com/api/graphql')) {
    return false;
  }
  final body = request.data;
  if (body is! Map ||
      body.length != 2 ||
      !body.containsKey('query') ||
      !body.containsKey('variables')) {
    return false;
  }
  final variables = body['variables'];
  if (variables is! Map || variables['path'] != _publicProjectPath) {
    return false;
  }
  if (body['query'] == _codeCoverageSummaryQuery) return variables.length == 1;
  final sourceAllowed =
      variables.length == 5 && !variables.containsKey('source') ||
      variables.length == 6 && variables['source'] == 'PUSH';
  return body['query'] == _pipelineAnalyticsQuery &&
      sourceAllowed &&
      variables['ref'] == 'main' &&
      variables['fromTime'] == _analyticsFrom &&
      variables['toTime'] == _analyticsTo &&
      variables['period'] == 'DAY';
}

bool _isExactPublicSnippetGraph(
  RequestOptions request,
  String? discoveredGraphId,
) {
  if (request.method != 'POST' ||
      request.uri != Uri.parse('https://gitlab.com/api/graphql')) {
    return false;
  }
  final body = request.data;
  if (body is! Map ||
      body.length != 2 ||
      !body.containsKey('query') ||
      !body.containsKey('variables')) {
    return false;
  }
  final variables = body['variables'];
  if (variables is! Map) return false;
  if (body['query'] == _projectSnippetsQuery) {
    return variables.length == 3 &&
        variables['projectId'] ==
            'gid://gitlab/Project/$_publicSnippetProjectId' &&
        variables['first'] == 100 &&
        variables.containsKey('after') &&
        variables['after'] == null;
  }
  final ids = variables['ids'];
  final paths = variables['paths'];
  return discoveredGraphId != null &&
      body['query'] == _snippetBlobQuery &&
      variables.length == 2 &&
      ids is List &&
      ids.length == 1 &&
      ids.single == discoveredGraphId &&
      paths is List &&
      paths.length == 1 &&
      _publicSnippetPaths.contains(paths.single);
}

bool _isExactPublicWorkItemGraph(
  RequestOptions request, {
  String? issuedGroupCursor,
}) {
  if (request.method != 'POST' ||
      request.uri != Uri.parse('https://gitlab.com/api/graphql')) {
    return false;
  }
  final body = request.data;
  if (body is! Map ||
      body.length != 2 ||
      !body.containsKey('query') ||
      !body.containsKey('variables')) {
    return false;
  }
  final variables = body['variables'];
  if (variables is! Map) return false;
  if (body['query'] is String &&
      (body['query'] as String).replaceAll(RegExp(r'\s+'), ' ').trim() ==
          _publicGroupWorkItemsQuery.replaceAll(RegExp(r'\s+'), ' ').trim()) {
    return variables.length == 7 &&
        variables['path'] == _publicGroupWorkItemPath &&
        variables['first'] == 20 &&
        variables['includeDescendants'] == false &&
        variables['state'] == 'all' &&
        variables['search'] == '' &&
        variables['sort'] == 'CREATED_DESC' &&
        variables.containsKey('after') &&
        (variables['after'] == null ||
            (issuedGroupCursor != null &&
                variables['after'] == issuedGroupCursor));
  }
  if (body['query'] == _publicNamespaceWorkItemTypesQuery &&
      variables['path'] == _publicGroupWorkItemPath) {
    return variables.length == 3 &&
        variables['first'] == 20 &&
        variables.containsKey('after') &&
        variables['after'] == null;
  }
  if (body['query'] == _publicProjectWorkItemsQuery ||
      body['query'] == _publicNamespaceWorkItemTypesQuery) {
    return variables.length == 3 &&
        variables['path'] == _publicSnippetProjectPath &&
        variables['first'] == 20 &&
        variables.containsKey('after') &&
        variables['after'] == null;
  }
  if (body['query'] == _publicProjectWorkItemQuery) {
    return variables.length == 2 &&
        variables['path'] == _publicSnippetProjectPath &&
        variables['iid'] == '$_publicWorkItemIid';
  }
  return body['query'] == _publicNamespaceWorkItemQuery &&
      variables.length == 2 &&
      variables['path'] == _publicGroupWorkItemPath &&
      const [
        '$_publicGroupWorkItemIid',
        '$_publicGroupParentWorkItemIid',
      ].contains(variables['iid']);
}

bool _isExactPublicWorkItemStateGraph(
  RequestOptions request,
  Set<String> discoveredIds,
) {
  if (request.method != 'POST' ||
      request.uri != Uri.parse('https://gitlab.com/api/graphql')) {
    return false;
  }
  final body = request.data;
  if (body is! Map ||
      body.length != 2 ||
      body['query'] != _publicWorkItemStateQuery) {
    return false;
  }
  final variables = body['variables'];
  return variables is Map &&
      variables.length == 1 &&
      discoveredIds.contains(variables['id']);
}

bool _isExactPublicWorkItemAttributeGraph(
  RequestOptions request,
  String? discoveredWorkItemId,
) {
  if (discoveredWorkItemId == null ||
      request.method != 'POST' ||
      request.uri != Uri.parse('https://gitlab.com/api/graphql')) {
    return false;
  }
  final body = request.data;
  if (body is! Map ||
      body.length != 2 ||
      !body.containsKey('query') ||
      !body.containsKey('variables')) {
    return false;
  }
  final variables = body['variables'];
  return variables is Map &&
      variables.length == 1 &&
      variables['id'] == discoveredWorkItemId &&
      [
        _publicWorkItemStatusAttributeQuery,
        _publicWorkItemMilestoneAttributeQuery,
        _publicWorkItemWeightAttributeQuery,
        _publicWorkItemIterationAttributeQuery,
        _publicWorkItemHealthAttributeQuery,
        _publicWorkItemTimeTrackingAttributeQuery,
        _publicWorkItemDevelopmentAttributeQuery,
      ].contains(body['query']);
}

bool _isExactPublicWorkItemActivityGraph(
  RequestOptions request,
  String? discoveredProjectWorkItemId,
  String? discoveredGroupWorkItemId,
) {
  if (request.method != 'POST' ||
      request.uri != Uri.parse('https://gitlab.com/api/graphql')) {
    return false;
  }
  final body = request.data;
  if (body is! Map ||
      body.length != 2 ||
      !body.containsKey('query') ||
      !body.containsKey('variables')) {
    return false;
  }
  final variables = body['variables'];
  if (variables is! Map) return false;
  final allowedWorkItemIds = {
    ?discoveredProjectWorkItemId,
    ?discoveredGroupWorkItemId,
  };
  if (body['query'] == _publicWorkItemActivityWriteAccessQuery) {
    return variables.length == 1 &&
        allowedWorkItemIds.contains(variables['id']);
  }
  if (body['query'] == _publicWorkItemActivityQuery) {
    final after = variables['after'];
    return variables.length == 4 &&
        allowedWorkItemIds.contains(variables['id']) &&
        variables.containsKey('after') &&
        _isSafePublicActivityCursor(after, nullable: true) &&
        const {
          'ALL_NOTES',
          'ONLY_COMMENTS',
          'ONLY_ACTIVITY',
        }.contains(variables['filter']) &&
        const {'CREATED_ASC', 'CREATED_DESC'}.contains(variables['sort']);
  }
  if (body['query'] == _publicWorkItemActivityLegacyQuery) {
    return variables.length == 2 &&
        allowedWorkItemIds.contains(variables['id']) &&
        variables.containsKey('after') &&
        _isSafePublicActivityCursor(variables['after'], nullable: true);
  }
  if (body['query'] != _publicWorkItemDiscussionNotesQuery) return false;
  final anchor = variables['anchorNoteId'];
  final after = variables['after'];
  // The tool cannot construct this request: production GitLabApi accepts only
  // a private, owner-bound continuation minted from a validated activity page.
  return variables.length == 3 &&
      allowedWorkItemIds.contains(variables['workItemId']) &&
      anchor is String &&
      anchor.isNotEmpty &&
      anchor.length <= 512 &&
      _isSafePublicActivityCursor(after, nullable: false);
}

bool _isSafePublicActivityCursor(Object? value, {required bool nullable}) =>
    value == null
    ? nullable
    : value is String && value.isNotEmpty && value.length <= 4096;
