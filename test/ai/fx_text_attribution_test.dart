import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';

// Plan v6 §5 item 7: with attribution on, AI-written class (A) comments and
// descriptions end with a localized line, counted in the payload before the
// checks. Widget and unit tests run in zh-TW.

void main() {
  tearDown(() => useLanguage(sourceLanguage));

  test('the line is in the zh-TW test language', () {
    final prepared = _prepare('Status update');
    expect(prepared.policyBlocked, isFalse);
    expect(prepared.finalText, 'Status update\n由 AI 助理撰寫');
  });

  test('the line follows the interface language when text is prepared', () {
    useLanguage(languageForTag('en')!);
    expect(
      _prepare('Status update').finalText,
      'Status update\nWritten by the AI assistant',
    );
    useLanguage(languageForTag('ja')!);
    expect(
      _prepare('Status update\n').finalText,
      'Status update\nAI アシスタントが作成',
    );
    useLanguage(languageForTag('ar')!);
    expect(_prepare('').finalText, 'كتبه مساعد AI');
  });

  test('no English attribution sentence is left in lib/', () {
    final hits = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.startsWith('lib/l10n/')) continue;
      if (entity.readAsStringSync().contains('Written by the AI assistant')) {
        hits.add(entity.path);
      }
    }
    expect(hits, isEmpty);
  });
}

AiTextOutcome _prepare(String text) => prepareWriteText(
  textClass: AiTextClass.quickActionMarkdown,
  modelText: text,
  field: null,
  placeholders: UploadPlaceholderTable(
    instance: GitLabInstance.parse('https://gitlab.example.com'),
  ),
  knownSecrets: const <String>{},
  aiAttribution: true,
  visibility: const AiVisibilityContext(targetProjectPath: 'group/proj'),
);
