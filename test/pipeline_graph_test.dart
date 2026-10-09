import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/pipeline_graph.dart';

Map<String, dynamic> job({
  required int id,
  required String name,
  List<String> needs = const [],
  bool retried = false,
  String schedulingType = 'DAG',
  bool needsTruncated = false,
  String kind = 'BUILD',
}) => {
  'id': 'gid://gitlab/Ci::Build/$id',
  'name': name,
  'status': 'SUCCESS',
  'kind': kind,
  'retried': retried,
  'schedulingType': schedulingType,
  'stage': {'name': 'test'},
  'needs': {
    'nodes': [
      for (final name in needs) {'name': name},
    ],
    'pageInfo': {'hasNextPage': needsTruncated, 'endCursor': null},
  },
};

Map<String, dynamic> page(
  List<Map<String, dynamic>> jobs, {
  bool hasNextPage = false,
  String? endCursor,
  bool stagesTruncated = false,
}) => {
  'id': 'gid://gitlab/Ci::Pipeline/77',
  'iid': '12',
  'stages': {
    'nodes': [
      {'name': 'build'},
      {'name': 'test'},
    ],
    'pageInfo': {'hasNextPage': stagesTruncated},
  },
  'jobs': {
    'nodes': jobs,
    'pageInfo': {'hasNextPage': hasNextPage, 'endCursor': endCursor},
  },
};

void main() {
  test('bridge nodes retain real identity without opening a build log', () {
    final bridge = {
      ...job(id: 7, name: 'downstream', kind: 'BRIDGE'),
      'id': 'gid://gitlab/Ci::Bridge/7',
    };
    final parsed = PipelineGraphPageData.fromJson(
      page([
        job(id: 1, name: 'compile'),
        bridge,
        job(id: 2, name: 'test', needs: ['downstream']),
      ]),
    );
    final node = parsed.jobs[1];
    expect(node.id, 'gid://gitlab/Ci::Bridge/7');
    expect(node.numericId, isNull);
    expect(node.canOpen, isFalse);
    expect(
      resolvePipelineGraphNeeds(parsed.jobs)[parsed.jobs[2].id]!.single.target,
      same(node),
    );
    expect(
      () => PipelineGraphJob.fromJson({
        ...bridge,
        'id': 'gid://gitlab/Ci::Build/7',
      }),
      throwsFormatException,
    );
    expect(
      () => PipelineGraphJob.fromJson({
        ...job(id: 7, name: 'build'),
        'id': 'gid://gitlab/Ci::Bridge/7',
      }),
      throwsFormatException,
    );
  });

  test('parses stage order, exact needs, cursor and build job identity', () {
    final parsed = PipelineGraphPageData.fromJson(
      page(
        [
          job(id: 1, name: 'compile'),
          job(id: 2, name: 'unit', needs: ['compile']),
        ],
        hasNextPage: true,
        endCursor: 'cursor-2',
      ),
    );

    expect(parsed.pipelineId, 77);
    expect(parsed.iid, 12);
    expect(parsed.stageNames, ['build', 'test']);
    expect(parsed.jobs.singleWhere((value) => value.name == 'unit').needs, [
      'compile',
    ]);
    expect(parsed.jobs.first.numericId, 1);
    expect(parsed.hasNextPage, isTrue);
    expect(parsed.endCursor, 'cursor-2');
  });

  test(
    'resolves only a unique normal job and marks missing or duplicate names',
    () {
      final parsed = PipelineGraphPageData.fromJson(
        page([
          job(id: 1, name: 'compile', retried: true),
          job(id: 2, name: 'compile'),
          job(id: 3, name: 'lint'),
          job(id: 4, name: 'test', needs: ['compile', 'lint', 'not-loaded']),
          job(id: 5, name: 'duplicate'),
          job(id: 6, name: 'duplicate'),
          job(id: 7, name: 'ambiguous', needs: ['duplicate']),
        ]),
      );

      final resolved = resolvePipelineGraphNeeds(parsed.jobs);
      final testNeeds = resolved['gid://gitlab/Ci::Build/4']!;
      expect(testNeeds[0].state, PipelineGraphNeedState.resolved);
      expect(testNeeds[0].target?.numericId, 2);
      expect(testNeeds[1].state, PipelineGraphNeedState.resolved);
      expect(testNeeds[2].state, PipelineGraphNeedState.unloaded);
      expect(
        resolved['gid://gitlab/Ci::Build/7']!.single.state,
        PipelineGraphNeedState.ambiguous,
      );
    },
  );

  test(
    'preserves stage scheduling and truncated needs without invented edges',
    () {
      final parsed = PipelineGraphPageData.fromJson(
        page([
          job(id: 1, name: 'stage-job', schedulingType: 'STAGE'),
          job(id: 2, name: 'free-job'),
          job(
            id: 3,
            name: 'partial',
            needs: ['free-job'],
            needsTruncated: true,
          ),
        ], stagesTruncated: true),
      );

      expect(parsed.stagesTruncated, isTrue);
      expect(parsed.jobs[0].waitsForStage, isTrue);
      expect(parsed.jobs[1].canRunImmediately, isTrue);
      expect(parsed.jobs[2].needsTruncated, isTrue);
      expect(
        resolvePipelineGraphNeeds(parsed.jobs)['gid://gitlab/Ci::Build/1'],
        isEmpty,
      );
    },
  );

  test('rejects malformed pagination, enum and GitLab global IDs', () {
    expect(
      () => PipelineGraphPageData.fromJson(
        page([
          {...job(id: 1, name: 'compile'), 'status': 'success'},
        ]),
      ),
      throwsFormatException,
    );
    expect(
      () => PipelineGraphPageData.fromJson(
        page([
          {...job(id: 1, name: 'compile'), 'id': '1'},
        ]),
      ),
      throwsFormatException,
    );
    expect(
      () => PipelineGraphPageData.fromJson(
        page([job(id: 1, name: 'compile')], hasNextPage: true),
      ),
      throwsFormatException,
    );
  });
}
