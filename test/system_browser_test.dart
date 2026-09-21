import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/features/auth/system_browser.dart';

class FakeAppLinks implements AppLinks {
  FakeAppLinks({this.initialLink, StreamController<Uri>? controller})
    : _controller = controller ?? StreamController<Uri>.broadcast();

  final Uri? initialLink;
  final StreamController<Uri> _controller;

  @override
  Future<Uri?> getInitialLink() async => initialLink;

  @override
  Stream<Uri> get uriLinkStream => _controller.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final authUrl = Uri.parse(
    'https://example.com/oauth/authorize?client_id=123',
  );
  final callbackUrl = Uri.parse('io.gitlabmobile.app://oauth/callback');

  test('authenticate resolves immediately when initial link matches', () async {
    final matchingInitial = Uri.parse(
      'io.gitlabmobile.app://oauth/callback?code=abc&state=s1',
    );
    var launched = false;
    final browser = SystemAuthorizationBrowser(
      links: FakeAppLinks(initialLink: matchingInitial),
      launch: (uri) async {
        launched = true;
        return true;
      },
    );

    final result = await browser.authenticate(
      authorizationUrl: authUrl,
      callbackUrl: callbackUrl,
    );

    expect(result, matchingInitial);
    expect(launched, isFalse);
  });

  test('authenticate throws network failure when launch fails', () async {
    final browser = SystemAuthorizationBrowser(
      links: FakeAppLinks(),
      launch: (uri) async => false,
    );

    expect(
      () => browser.authenticate(
        authorizationUrl: authUrl,
        callbackUrl: callbackUrl,
      ),
      throwsA(
        isA<ApiFailure>().having((e) => e.kind, 'kind', FailureKind.network),
      ),
    );
  });

  test(
    'authenticate opens browser and waits for matching callback on stream',
    () async {
      final controller = StreamController<Uri>.broadcast();
      Uri? openedUri;
      final browser = SystemAuthorizationBrowser(
        links: FakeAppLinks(controller: controller),
        launch: (uri) async {
          openedUri = uri;
          return true;
        },
      );

      final authFuture = browser.authenticate(
        authorizationUrl: authUrl,
        callbackUrl: callbackUrl,
      );

      await Future<void>.delayed(Duration.zero);
      expect(openedUri, authUrl);

      // Send a non-matching URI first
      controller.add(Uri.parse('https://other.com/callback'));
      await Future<void>.delayed(Duration.zero);

      // Send the matching URI
      final callbackWithCode = Uri.parse(
        'io.gitlabmobile.app://oauth/callback?code=auth123&state=s1',
      );
      controller.add(callbackWithCode);

      final result = await authFuture;
      expect(result, callbackWithCode);

      await controller.close();
    },
  );
}
