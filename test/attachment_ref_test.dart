import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/shared/attachment_ref.dart';

void main() {
  const secret = '0123456789abcdef0123456789abcdef';
  const ref = ProjectUploadRef(secret: secret, filename: 'shot.png');
  final projectWeb = Uri.parse('https://example.com/gitlab/studio/mobile-workspace');

  test('relative /uploads path uses the page project and nothing else', () {
    expect(parseProjectUpload(Uri.parse('/uploads/$secret/shot.png'), projectId: 42), ref);
    expect(parseProjectUpload(Uri.parse('/uploads/$secret/shot.png')), isNull);
    expect(parseProjectUpload(Uri.parse('uploads/$secret/shot.png'), projectId: 42), isNull);
  });

  test('absolute project web path matches only that project', () {
    expect(parseProjectUpload(
      Uri.parse('https://example.com/gitlab/studio/mobile-workspace/uploads/$secret/shot.png'),
      projectId: 42, projectWeb: projectWeb,
    ), ref);
    expect(parseProjectUpload(
      Uri.parse('https://example.com/uploads/$secret/shot.png'),
      projectId: 42, projectWeb: projectWeb,
    ), ref);
    expect(parseProjectUpload(
      Uri.parse('https://example.com/gitlab/other/repo/uploads/$secret/shot.png'),
      projectId: 42, projectWeb: projectWeb,
    ), isNull);
  });

  test('base resolves a directory-relative upload onto the project web path', () {
    final base = Uri.parse('https://example.com/gitlab/studio/mobile-workspace/');
    expect(parseProjectUpload(
      Uri.parse('uploads/$secret/shot.png'),
      base: base, projectId: 42, projectWeb: projectWeb,
    ), ref);
  });

  test('/-/project id must equal the page project', () {
    expect(parseProjectUpload(Uri.parse('/-/project/42/uploads/$secret/shot.png'), projectId: 42), ref);
    expect(parseProjectUpload(
      Uri.parse('https://example.com/gitlab/-/project/42/uploads/$secret/shot.png'),
      projectId: 42, projectWeb: projectWeb,
    ), ref);
    expect(parseProjectUpload(
      Uri.parse('/-/project/7/uploads/$secret/shot.png'),
      projectId: 42, projectWeb: projectWeb,
    ), isNull);
    expect(parseProjectUpload(
      Uri.parse('https://example.com/gitlab/-/project/7/uploads/$secret/shot.png'),
      projectId: 42, projectWeb: projectWeb,
    ), isNull);
  });

  test('different origin is not a project upload', () {
    expect(parseProjectUpload(
      Uri.parse('https://example.org/uploads/$secret/shot.png'),
      projectId: 42, projectWeb: projectWeb,
    ), isNull);
    expect(parseProjectUpload(
      Uri.parse('https://example.org/x.png'),
      projectId: 42, projectWeb: projectWeb,
    ), isNull);
    expect(parseProjectUpload(Uri.parse('http://example.com/uploads/$secret/shot.png'), projectId: 42, projectWeb: projectWeb), isNull);
  });

  test('bad secret and an exact .. segment are ignored', () {
    expect(parseProjectUpload(Uri.parse('/uploads/abc/shot.png'), projectId: 42), isNull);
    expect(parseProjectUpload(Uri.parse('/uploads/${secret.toUpperCase()}/shot.png'), projectId: 42), isNull);
    expect(parseProjectUpload(Uri.parse('/uploads/$secret/notes..png'), projectId: 42),
      const ProjectUploadRef(secret: secret, filename: 'notes..png'));
    expect(parseProjectUpload(Uri.parse('/uploads/$secret/..'), projectId: 42), isNull);
    expect(parseProjectUpload(Uri(pathSegments: ['uploads', secret, r'a\b.png']), projectId: 42), isNull);
  });

  test('malformed escapes and an over-long path are null and do not throw', () {
    expect(parseProjectUpload(Uri.parse('/uploads/$secret/%FF.png'), projectId: 42), isNull);
    expect(parseProjectUpload(Uri.parse('/uploads/$secret/%'), projectId: 42), isNull);
    expect(parseProjectUpload(Uri.parse('/uploads/$secret/${'a' * 5000}.png'), projectId: 42), isNull);
    expect(parseProjectUpload(Uri.parse('/uploads/$secret/%C0%AFshot.png'), projectId: 42), isNull);
    expect(projectUploadWeb(Uri.parse('https://example.com/%FF/group'), ref), isNull);
    expect(projectUploadWeb(Uri.parse('https://example.com/${'g' * 5000}'), ref), isNull);
    expect(
      projectUploadWeb(projectWeb, ref),
      Uri.parse('https://example.com/gitlab/studio/mobile-workspace/uploads/$secret/shot.png'),
    );
  });
}
