import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/project_locator.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'package:gitlab_mobile/features/shell/language.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';

import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_adapter.dart';
import 'support/fake_shortcuts.dart';
import 'support/memory_appearance_store.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';

final class _Store implements LanguageStore {
  _Store([this.value]);
  String? value;
  int writes = 0;
  bool failReads = false;
  bool failWrites = false;
  Completer<String?>? pendingRead;
  @override
  Future<String?> read() async {
    if (failReads) throw StateError('synthetic key-store failure');
    final pending = pendingRead;
    return pending != null ? pending.future : value;
  }

  @override
  Future<void> write(String? tag) async {
    if (failWrites) throw StateError('synthetic key-store failure');
    writes++;
    value = tag;
  }
}

String? _tag(String code, [String? script, String? country]) =>
    matchLanguage(code, scriptCode: script, countryCode: country)?.tag;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every language has a unique tag and a locale', () {
    expect(appLanguages.first, same(sourceLanguage));
    expect(sourceLanguage.tag, 'zh-TW');
    expect({for (final language in appLanguages) language.tag}.length, appLanguages.length);
    expect(appLocales, hasLength(appLanguages.length));
    expect(appLanguages.length, greaterThanOrEqualTo(20));
  });

  test('device locales map to the closest language', () {
    expect(_tag('zh', 'Hant'), 'zh-TW');
    expect(_tag('zh', null, 'TW'), 'zh-TW');
    expect(_tag('zh', null, 'HK'), 'zh-TW');
    expect(_tag('zh', null, 'MO'), 'zh-TW');
    expect(_tag('zh', 'Hans', 'TW'), 'zh-CN', reason: 'the script wins over the region');
    expect(_tag('zh', null, 'CN'), 'zh-CN');
    expect(_tag('zh', null, 'SG'), 'zh-CN');
    expect(_tag('zh'), 'zh-CN');
    expect(_tag('pt', null, 'PT'), 'pt-BR');
    expect(_tag('in'), 'id', reason: 'the obsolete code for Indonesian');
    expect(_tag('ja', null, 'JP'), 'ja');
    expect(_tag('xx'), isNull);
    final english = resolveLanguage([
      (languageCode: 'xx', scriptCode: null, countryCode: null),
      (languageCode: 'yy', scriptCode: null, countryCode: null),
    ]);
    expect(english.tag, 'en', reason: 'English when nothing matches');
    final second = resolveLanguage([
      (languageCode: 'xx', scriptCode: null, countryCode: null),
      (languageCode: 'de', scriptCode: null, countryCode: 'AT'),
    ]);
    expect(second.tag, 'de', reason: 'the first supported of the preferred languages');
  });

  test('input errors stay specific in every language', () async {
    for (final language in [languageForTag('en')!, languageForTag('ja')!, sourceLanguage]) {
      useLanguage(language);
      expect(() => GitLabInstance.parse('http://example.com'), throwsA(isA<InputFormatException>()));
      final controller = controllerFor(MemoryAccountStore(), FakeAdapter((_) => fail('no request expected')));
      await controller.initialize();
      await controller.connect('http://example.com', 'synthetic-test-token');
      expect(controller.message, l10n.enterHttpsGitlabUrl, reason: language.tag);
      await controller.connect('https://example.com/a/../b', 'synthetic-test-token');
      expect(controller.message, l10n.instancePathNoRelativeEncoded, reason: language.tag);
      controller.dispose();
      for (final link in ['https://gitlab.com/g/%FF/x', 'https://gitlab.com/g/p?x=%FF']) {
        expect(() => projectLocator(GitLabInstance.parse('https://gitlab.com'), link),
            throwsA(isA<InputFormatException>()), reason: 'an undecodable link is the user\'s input, not a server reply');
      }
    }
  });

  test('follows the device until a language is picked, then the latest change wins', () async {
    var device = [const Locale('ja', 'JP')];
    final store = _Store();
    final controller = LanguageController(store, deviceLocales: () => device);
    addTearDown(controller.dispose);
    var notified = 0;
    controller.addListener(() => notified++);

    await controller.load();
    expect(controller.choice, isNull);
    expect(controller.language.tag, 'ja');
    expect(l10n.language.tag, 'ja', reason: 'load applies the language to l10n');
    expect(controller.locale, const Locale('ja'));
    expect(notified, 1);

    device = [const Locale('fr', 'CA')];
    controller.didChangeLocales(device);
    expect(controller.language.tag, 'fr');

    await controller.select('ko');
    expect(controller.choice, 'ko');
    expect(store.value, 'ko|fr-CA', reason: 'the device language at the time is kept with the pick');
    expect(l10n.language.tag, 'ko');

    controller.didChangeLocales(device);
    expect(controller.choice, 'ko', reason: 'the same device language keeps the pick');

    device = [const Locale('de')];
    controller.didChangeLocales(device);
    await pumpEventQueue();
    expect(controller.choice, isNull, reason: 'a later device or per-app language change wins');
    expect(controller.language.tag, 'de');
    expect(store.value, isNull);

    await controller.select('xx');
    expect(controller.choice, isNull, reason: 'unknown tags are ignored');
  });

  test('picking the language already shown still notifies and is remembered', () async {
    final store = _Store();
    final controller = LanguageController(store, deviceLocales: () => [const Locale('en', 'US')]);
    addTearDown(controller.dispose);
    await controller.load();
    var notified = 0;
    controller.addListener(() => notified++);
    await controller.select('en');
    expect(controller.choice, 'en');
    expect(notified, 1, reason: 'the picker row changes from following the system to English');
    expect(store.value, 'en|en-US');
    await controller.select(null);
    expect(notified, 2);
    expect(store.value, isNull);
  });

  test('a stored language applies only while the device language is unchanged', () async {
    final kept = LanguageController(_Store('zh-CN|en-US'), deviceLocales: () => [const Locale('en', 'US')]);
    addTearDown(kept.dispose);
    await kept.load();
    expect(kept.choice, 'zh-CN');
    expect(kept.locale, const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans', countryCode: 'CN'));

    final moved = _Store('zh-CN|en-US');
    final changed = LanguageController(moved, deviceLocales: () => [const Locale('de', 'DE')]);
    addTearDown(changed.dispose);
    await changed.load();
    await pumpEventQueue();
    expect(changed.choice, isNull, reason: 'the device moved on since the pick');
    expect(changed.language.tag, 'de');
    expect(moved.value, isNull);

    final unknown = LanguageController(_Store('tlh'), deviceLocales: () => [const Locale('en', 'US')]);
    addTearDown(unknown.dispose);
    await unknown.load();
    expect(unknown.choice, isNull);
    expect(unknown.language.tag, 'en');
  });

  test('a pick made while the stored value is still loading wins', () async {
    final read = Completer<String?>();
    final store = _Store()..pendingRead = read;
    final controller = LanguageController(store, deviceLocales: () => [const Locale('en', 'US')]);
    addTearDown(controller.dispose);
    final loading = controller.load();
    expect(l10n.language.tag, 'en', reason: 'the device language applies before the read finishes');
    await controller.select('ko');
    read.complete('ja|en-US');
    await loading;
    expect(controller.choice, 'ko');
    expect(l10n.language.tag, 'ko');
  });

  test('a stored tag without device languages is kept and completed', () async {
    final store = _Store('ja');
    final controller = LanguageController(store, deviceLocales: () => [const Locale('en', 'US')]);
    addTearDown(controller.dispose);
    await controller.load();
    await pumpEventQueue();
    expect(controller.choice, 'ja');
    expect(store.value, 'ja|en-US');
    controller.didChangeLocales([const Locale('en', 'US')]);
    expect(controller.choice, 'ja', reason: 'a re-sent, unchanged locale list keeps the pick');
  });

  test('a change further down the device languages also ends a pick', () async {
    var device = [const Locale('fi', 'FI'), const Locale('en', 'US')];
    final store = _Store();
    final controller = LanguageController(store, deviceLocales: () => device);
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.language.tag, 'en', reason: 'Finnish is not translated');
    await controller.select('ja');
    expect(store.value, 'ja|fi-FI,en-US');
    device = [const Locale('fi', 'FI'), const Locale('de', 'DE')];
    controller.didChangeLocales(device);
    expect(controller.choice, isNull);
    expect(controller.language.tag, 'de');
  });

  test('clearing a pick notifies even when the language stays the same', () async {
    var device = [const Locale('en', 'US')];
    final controller = LanguageController(_Store(), deviceLocales: () => device);
    addTearDown(controller.dispose);
    await controller.load();
    await controller.select('ja');
    var notified = 0;
    controller.addListener(() => notified++);
    device = [const Locale('ja', 'JP')];
    controller.didChangeLocales(device);
    expect(controller.choice, isNull);
    expect(controller.language.tag, 'ja');
    expect(notified, 1, reason: 'the picker row changes to following the system');
  });

  test('a device language change during a slow read discards the stored pick', () async {
    var device = [const Locale('en', 'US')];
    final read = Completer<String?>();
    final store = _Store()..pendingRead = read;
    final controller = LanguageController(store, deviceLocales: () => device);
    addTearDown(controller.dispose);
    final loading = controller.load();
    device = [const Locale('de', 'DE')];
    controller.didChangeLocales(device);
    read.complete('ja');
    await loading;
    expect(controller.choice, isNull);
    expect(controller.language.tag, 'de');
  });

  test('storage failures fall back to the device and keep the pick for this run', () async {
    final store = _Store()..failReads = true..failWrites = true;
    final controller = LanguageController(store, deviceLocales: () => [const Locale('es', 'MX')]);
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.language.tag, 'es');
    await controller.select('it');
    expect(controller.choice, 'it');
    expect(l10n.language.tag, 'it');
  });

  testWidgets('我的 › 外觀 › 語言 switches the language and keeps the page', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = WorkspaceFixture();
    final session = controllerFor(MemoryAccountStore(), fixture.adapter);
    await tester.runAsync(() async {
      await session.initialize();
      await session.connect('https://example.com/gitlab', 'synthetic-test-token');
    });
    final store = _Store();
    final language = LanguageController(store, deviceLocales: () => [const Locale('zh', 'TW')]);
    final appearance = AppearanceController(MemoryAppearanceStore());
    final shortcuts = LauncherShortcuts(FakeAppShortcutHost(), MemoryRecentProjectStore());
    addTearDown(() {
      language.dispose();
      appearance.dispose();
      shortcuts.dispose();
      session.dispose();
      fixture.api.close();
    });
    await tester.runAsync(language.load);
    await tester.pumpWidget(AuthenticatedApp(
      session: session, appearance: appearance, shortcuts: shortcuts, language: language));
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('我的'));
    await settleNetworkWidgets(tester);
    final row = find.byKey(const ValueKey('language-row'));
    await tester.scrollUntilVisible(row, 200);
    expect(find.descendant(of: row, matching: find.text('跟隨系統 · 繁體中文')), findsOneWidget);

    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('language-en')));
    await tester.pumpAndSettle();
    expect(language.choice, 'en');
    expect(store.value, 'en|zh-TW');
    expect(l10n.language.tag, 'en');
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.locale, const Locale('en'));
    expect(find.descendant(of: row, matching: find.text('English')), findsOneWidget);
    // The app's language, not the project analytics' programming languages.
    expect(find.descendant(of: row, matching: find.text('Language')), findsOneWidget);
    expect(find.text('Me'), findsWidgets, reason: 'the navigation and the page title are rebuilt in English');
    expect(find.text('我的'), findsNothing);
  });
}
