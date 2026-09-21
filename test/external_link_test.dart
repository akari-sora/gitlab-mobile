import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/shared/external_link.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class FakeUrlLauncher extends UrlLauncherPlatform
    with MockPlatformInterfaceMixin {
  String? launchedUrl;
  LaunchOptions? options;
  bool shouldSucceed = true;
  bool shouldThrow = false;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launchedUrl = url;
    this.options = options;
    if (shouldThrow) throw Exception('failed');
    return shouldSucceed;
  }
}

void main() {
  late FakeUrlLauncher fakeLauncher;
  late UrlLauncherPlatform originalPlatform;

  setUp(() {
    fakeLauncher = FakeUrlLauncher();
    originalPlatform = UrlLauncherPlatform.instance;
    UrlLauncherPlatform.instance = fakeLauncher;
  });

  tearDown(() {
    UrlLauncherPlatform.instance = originalPlatform;
  });

  testWidgets('openExternal ignores non-https schemes', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () =>
                  openExternal(context, Uri.parse('http://gitlab.com')),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    expect(fakeLauncher.launchedUrl, isNull);
    expect(find.text('無法啟動系統瀏覽器。'), findsNothing);
  });

  testWidgets('openExternal ignores URLs with userInfo', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => openExternal(
                context,
                Uri.parse('https://user:token@gitlab.com'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    expect(fakeLauncher.launchedUrl, isNull);
    expect(find.text('無法啟動系統瀏覽器。'), findsNothing);
  });

  testWidgets('openExternal launches valid https URL in external application', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () =>
                  openExternal(context, Uri.parse('https://gitlab.com/repo')),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    expect(fakeLauncher.launchedUrl, 'https://gitlab.com/repo');
    expect(fakeLauncher.options?.mode, PreferredLaunchMode.externalApplication);
    expect(find.text('無法啟動系統瀏覽器。'), findsNothing);
  });

  testWidgets('openExternal shows snackbar when launch returns false', (
    tester,
  ) async {
    fakeLauncher.shouldSucceed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () =>
                  openExternal(context, Uri.parse('https://gitlab.com/repo')),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    expect(find.text('無法啟動系統瀏覽器。'), findsOneWidget);
  });

  testWidgets('openExternal shows snackbar when launch throws', (tester) async {
    fakeLauncher.shouldThrow = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () =>
                  openExternal(context, Uri.parse('https://gitlab.com/repo')),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    expect(find.text('無法啟動系統瀏覽器。'), findsOneWidget);
  });
}
