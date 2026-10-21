import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/shared/markdown_media_source.dart';

import 'support/fake_adapter.dart';

void main() {
  test('repository coordinates decode percent encoding exactly once', () async {
    final instance = GitLabInstance.parse('https://example.com/gitlab');
    final source = resolveMarkdownMedia(
      Uri.parse('100%25.png'),
      base: Uri.parse(
        'https://example.com/gitlab/team/project/-/blob/'
        'feature%25done/docs/readme.md',
      ),
      instance: instance,
      projectId: 42,
      projectWeb: Uri.parse('https://example.com/gitlab/team/project'),
    );

    expect(source.kind, MarkdownMediaSourceKind.repository);
    expect(source.path, 'docs/100%.png');
    expect(source.ref, 'feature%done');

    final adapter = FakeAdapter((_) => ResponseBody.fromBytes(<int>[1], 200));
    final api = testApi(adapter);
    addTearDown(api.close);

    expect(
      await api.rawFileBytes(source.project!, source.ref!, source.path!),
      Uint8List.fromList(<int>[1]),
    );
    final request = adapter.requests.single.uri;
    expect(request.path, contains('/files/docs%2F100%25.png/raw'));
    expect(request.queryParameters['ref'], 'feature%done');
  });

  test('local-use NAT64 embeds the same private IPv4 policy', () {
    expect(
      resolveMarkdownMedia(
        Uri.parse('https://[64:ff9b:1::a00:1]/asset.png'),
      ).kind,
      MarkdownMediaSourceKind.blocked,
    );
    expect(
      resolveMarkdownMedia(
        Uri.parse('https://[64:ff9b:1:808:8:800::]/asset.png'),
      ).kind,
      MarkdownMediaSourceKind.external,
    );
  });
}
