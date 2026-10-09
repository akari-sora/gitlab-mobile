import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/shared/resource_share.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
// The production dependency re-exports its value types, while this test needs
// the platform seam itself to prove that no browser or file share is used.
// ignore: depend_on_referenced_packages
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/link.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

final class _FakeSharePlatform extends SharePlatform
    with MockPlatformInterfaceMixin {
  ShareParams? params;
  int calls = 0;
  Object? error;
  Completer<ShareResult>? pending;

  void reset() {
    params = null;
    calls = 0;
    error = null;
    pending = null;
  }

  @override
  Future<ShareResult> share(ShareParams params) {
    calls++;
    this.params = params;
    final wait = pending;
    if (wait != null) return wait.future;
    final failure = error;
    if (failure != null) return Future<ShareResult>.error(failure);
    return Future<ShareResult>.value(ShareResult.unavailable);
  }
}

final class _FakeUrlLauncher extends UrlLauncherPlatform
    with MockPlatformInterfaceMixin {
  String? launchedUrl;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launchedUrl = url;
    return true;
  }
}

Widget _host(Uri uri, {Object? ownerKey, bool Function()? isCurrent}) =>
    MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Resource'),
          actions: [
            ResourceShareButton(
              uri: uri,
              ownerKey: ownerKey,
              isCurrent: isCurrent,
            ),
          ],
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final fake = _FakeSharePlatform();
  final fakeLauncher = _FakeUrlLauncher();
  late SharePlatform originalShare;
  late UrlLauncherPlatform originalLauncher;

  setUpAll(() {
    originalShare = SharePlatform.instance;
    originalLauncher = UrlLauncherPlatform.instance;
    SharePlatform.instance = fake;
    UrlLauncherPlatform.instance = fakeLauncher;
  });

  tearDownAll(() {
    SharePlatform.instance = originalShare;
    UrlLauncherPlatform.instance = originalLauncher;
  });

  setUp(() {
    fake.reset();
    fakeLauncher.launchedUrl = null;
  });

  testWidgets('shares only canonical URL text with a popover origin at 320px', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final uri = Uri.parse('https://example.com/gitlab/team/app/-/commit/abc');
    await tester.pumpWidget(_host(uri));

    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('分享連結'));
    await tester.pump();

    expect(fake.calls, 1);
    expect(fake.params?.text, uri.toString());
    expect(fake.params?.uri, isNull);
    expect(fake.params?.files, isNull);
    expect(fake.params?.subject, isNull);
    expect(fake.params?.title, isNull);
    expect(fake.params?.sharePositionOrigin, isNotNull);
    expect(fake.params!.sharePositionOrigin!.width, greaterThan(0));
    expect(fake.params!.sharePositionOrigin!.height, greaterThan(0));
    expect(fakeLauncher.launchedUrl, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'disables URLs that could disclose credentials or are not HTTPS',
    (tester) async {
      final unsafe = [
        Uri.parse('http://example.com/team/app'),
        Uri.parse('https://user:secret@example.com/team/app'),
        Uri.parse('https://example.com/team/app?private_token=secret'),
        Uri(scheme: 'https', path: '/team/app'),
      ];

      for (final uri in unsafe) {
        await tester.pumpWidget(_host(uri));
        final button = tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.share_outlined),
        );
        expect(button.onPressed, isNull, reason: '$uri must not be shared');
      }
      expect(fake.calls, 0);
    },
  );

  testWidgets('prevents a second share while the native sheet is pending', (
    tester,
  ) async {
    final pending = Completer<ShareResult>();
    fake.pending = pending;
    await tester.pumpWidget(_host(Uri.parse('https://example.com/team/app')));

    await tester.tap(find.byTooltip('分享連結'));
    await tester.pump();
    expect(fake.calls, 1);
    final button = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.share_outlined),
    );
    expect(button.onPressed, isNull);

    pending.complete(ShareResult.unavailable);
    await tester.pump();
    expect(fake.calls, 1);
  });

  testWidgets('shows a useful error for the current owner', (tester) async {
    fake.error = StateError('share failed');
    await tester.pumpWidget(_host(Uri.parse('https://example.com/team/app')));
    await tester.tap(find.byTooltip('分享連結'));
    await tester.pump();
    expect(find.text('無法分享連結。'), findsOneWidget);
  });

  testWidgets('does not show a late error after its owner becomes stale', (
    tester,
  ) async {
    final pending = Completer<ShareResult>();
    fake.pending = pending;
    var current = true;
    await tester.pumpWidget(
      _host(
        Uri.parse('https://example.com/team/other'),
        isCurrent: () => current,
      ),
    );
    await tester.tap(find.byTooltip('分享連結'));
    await tester.pump();
    current = false;
    pending.completeError(StateError('late failure'));
    await tester.pump();

    expect(find.text('無法分享連結。'), findsNothing);
  });

  testWidgets('ignores a late failure after the shared resource changes', (
    tester,
  ) async {
    final pending = Completer<ShareResult>();
    fake.pending = pending;
    await tester.pumpWidget(_host(Uri.parse('https://example.com/team/one')));
    await tester.tap(find.byTooltip('分享連結'));
    await tester.pump();

    await tester.pumpWidget(_host(Uri.parse('https://example.com/team/two')));
    pending.completeError(StateError('late failure'));
    await tester.pump();

    expect(find.text('無法分享連結。'), findsNothing);
    final button = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.share_outlined),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('resets for a new owner of the same URL and ignores old errors', (
    tester,
  ) async {
    final pending = Completer<ShareResult>();
    fake.pending = pending;
    final uri = Uri.parse('https://example.com/team/shared');
    await tester.pumpWidget(_host(uri, ownerKey: 'account-1'));
    await tester.tap(find.byTooltip('分享連結'));
    await tester.pump();

    await tester.pumpWidget(_host(uri, ownerKey: 'account-2'));
    final replacement = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.share_outlined),
    );
    expect(replacement.onPressed, isNotNull);

    pending.completeError(StateError('old owner failure'));
    await tester.pump();
    expect(find.text('無法分享連結。'), findsNothing);
    expect(fake.calls, 1);
  });
}
