import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/project_locator.dart';

void main() {
  final instance = GitLabInstance.parse('https://example.com/gitlab');
  const root = 'https://example.com/gitlab';
  const sha = '0123456789abcdef0123456789abcdef01234567';

  GitLabLink? inApp(String url) => GitLabLink.inApp(Uri.parse(url), instance);

  test('concrete same-instance resources open in the app', () {
    final cases = <String, (LinkTarget, String)>{
      '$root/team/core/-/issues/7': (LinkTarget.issue, 'team/core'),
      '$root/team/core/-/issues/7#note_12': (LinkTarget.issue, 'team/core'),
      '$root/team/core/-/merge_requests/5': (
        LinkTarget.mergeRequest,
        'team/core',
      ),
      '$root/team/core/-/merge_requests/5/diffs': (
        LinkTarget.mergeRequest,
        'team/core',
      ),
      '$root/team/core/-/work_items/9': (LinkTarget.workItem, 'team/core'),
      '$root/groups/team/sub/-/work_items/8': (LinkTarget.workItem, 'team/sub'),
      '$root/team/core/-/pipelines/99': (LinkTarget.pipeline, 'team/core'),
      '$root/team/core/-/jobs/501': (LinkTarget.job, 'team/core'),
      '$root/team/core/-/commit/$sha': (LinkTarget.commit, 'team/core'),
      '$root/team/core/-/blob/$sha/lib/main.dart#L4': (
        LinkTarget.file,
        'team/core',
      ),
    };
    for (final MapEntry(key: url, value: (target, project)) in cases.entries) {
      final link = inApp(url);
      expect(link, isNotNull, reason: url);
      expect((link!.target, link.project), (target, project), reason: url);
    }
    expect(inApp('$root/team/core/-/blob/$sha/lib/main.dart#L4')!.line, 4);
    expect(
      inApp('$root/groups/team/sub/-/work_items/8')!.workItemScope,
      WorkItemLinkScope.group,
    );
  });

  test('pages that are not one concrete resource stay in the browser', () {
    for (final url in [
      // A branch ref may contain slashes, so the file cannot be pinned.
      '$root/team/core/-/blob/main/README.md',
      '$root/team/core',
      '$root/team/core/-/tree/main',
      '$root/users/someone/activity',
      '$root/groups/team',
      '$root/groups/team/-/work_items',
      '$root/groups/team/-/epics/3',
      '$root/team/core/-/milestones/1',
      '$root/team/core/-/wikis/home',
      // Sub-pages the parent resource's screen would not show.
      '$root/team/core/-/jobs/501/artifacts/download',
      '$root/team/core/-/jobs/501/raw',
      '$root/team/core/-/issues/7/designs/mockup.png',
      '$root/team/core/-/pipelines/99/test_report',
      '$root/team/core/-/merge_requests/5/unknown',
      '$root/',
    ]) {
      expect(inApp(url), isNull, reason: url);
    }
  });

  test('other origins, cleartext and credentials stay in the browser', () {
    for (final url in [
      'https://other.example/gitlab/team/core/-/issues/7',
      'https://example.com:8443/gitlab/team/core/-/issues/7',
      'http://example.com/gitlab/team/core/-/issues/7',
      'https://example.com/other/team/core/-/issues/7',
      'https://user:secret@example.com/gitlab/team/core/-/issues/7',
      '$root/team/core/-/issues/7?private_token=secret',
    ]) {
      expect(inApp(url), isNull, reason: url);
    }
  });
}
