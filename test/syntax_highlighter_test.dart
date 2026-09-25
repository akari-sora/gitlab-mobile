import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/syntax_highlighter.dart';
import 'package:gitlab_mobile/features/workspace/repository_page.dart';
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('SyntaxHighlighter language detection', () {
    test('detects standard languages by file extension', () {
      expect(SyntaxHighlighter.detectLanguage('lib/main.dart'), 'dart');
      expect(SyntaxHighlighter.detectLanguage('.gitlab-ci.yml'), 'yaml');
      expect(SyntaxHighlighter.detectLanguage('config.yaml'), 'yaml');
      expect(SyntaxHighlighter.detectLanguage('package.json'), 'json');
      expect(SyntaxHighlighter.detectLanguage('script.py'), 'python');
      expect(SyntaxHighlighter.detectLanguage('deploy.sh'), 'shell');
      expect(SyntaxHighlighter.detectLanguage('README.md'), 'markdown');
      expect(SyntaxHighlighter.detectLanguage('app.js'), 'javascript');
      expect(SyntaxHighlighter.detectLanguage('component.tsx'), 'javascript');
      expect(SyntaxHighlighter.detectLanguage('LICENSE'), '');
      expect(SyntaxHighlighter.detectLanguage('unknown.xyz'), 'xyz');
    });
  });

  group('SyntaxHighlighter tokenization', () {
    test('highlights Dart keywords, strings, comments and numbers', () {
      const line = 'final count = 42; // total items';
      final span = SyntaxHighlighter.highlightLine(
        line,
        extension: 'main.dart',
        isDark: true,
      );

      final children = span.children!;
      expect(children, isNotEmpty);

      // 檢查關鍵字 final
      final finalSpan = children.firstWhere((s) => (s as TextSpan).text == 'final') as TextSpan;
      expect(finalSpan.style?.color, const Color(0xFFFF7B72));
      expect(finalSpan.style?.fontWeight, FontWeight.w600);

      // 檢查數字 42
      final numSpan = children.firstWhere((s) => (s as TextSpan).text == '42') as TextSpan;
      expect(numSpan.style?.color, const Color(0xFF79C0FF));

      // 檢查註釋 // total items
      final commentSpan = children.firstWhere((s) => (s as TextSpan).text?.startsWith('//') == true) as TextSpan;
      expect(commentSpan.style?.color, const Color(0xFF8B949E));
      expect(commentSpan.style?.fontStyle, FontStyle.italic);
    });

    test('highlights Python syntax correctly', () {
      const line = 'def calculate(value="test"): # compute';
      final span = SyntaxHighlighter.highlightLine(
        line,
        extension: 'calc.py',
        isDark: false,
      );

      final children = span.children!;
      expect(children, isNotEmpty);

      // 檢查關鍵字 def
      final defSpan = children.firstWhere((s) => (s as TextSpan).text == 'def') as TextSpan;
      expect(defSpan.style?.color, const Color(0xFFD73A49));

      // 檢查字串 "test"
      final strSpan = children.firstWhere((s) => (s as TextSpan).text == '"test"') as TextSpan;
      expect(strSpan.style?.color, const Color(0xFF032F62));

      // 檢查註釋 # compute
      final commentSpan = children.firstWhere((s) => (s as TextSpan).text == '# compute') as TextSpan;
      expect(commentSpan.style?.color, const Color(0xFF6A737D));
    });

    test('highlights YAML keys and comments', () {
      const line = 'version: 1.0.0 # release';
      final span = SyntaxHighlighter.highlightLine(
        line,
        extension: 'pubspec.yaml',
        isDark: true,
      );

      final children = span.children!;
      // key 應為 keyColor
      final keySpan = children.firstWhere((s) => (s as TextSpan).text == 'version') as TextSpan;
      expect(keySpan.style?.color, const Color(0xFF7EE787));
    });

    test('highlights JSON key-value pairs', () {
      const line = '  "status": "active",';
      final span = SyntaxHighlighter.highlightLine(
        line,
        extension: 'data.json',
        isDark: false,
      );

      final children = span.children!;
      final keySpan = children.firstWhere((s) => (s as TextSpan).text == '"status"') as TextSpan;
      expect(keySpan.style?.color, const Color(0xFF22863A));

      final valSpan = children.firstWhere((s) => (s as TextSpan).text == '"active"') as TextSpan;
      expect(valSpan.style?.color, const Color(0xFF032F62));
    });

    test('handles empty lines without crashing', () {
      final span = SyntaxHighlighter.highlightLine('', extension: 'foo.dart', isDark: false);
      expect(span.text, '');
      expect(span.children, isNull);
    });

    test('protects against ultra-long lines (> 2000 chars) by failing-soft to plain text', () {
      final longLine = 'a' * 2500;
      final span = SyntaxHighlighter.highlightLine(longLine, extension: 'foo.dart', isDark: false);
      expect(span.text, longLine);
      expect(span.children, isNull);
    });

    test('adapts to light vs dark theme palettes correctly', () {
      const line = 'class User {}';
      final lightSpan = SyntaxHighlighter.highlightLine(line, extension: 'model.dart', isDark: false);
      final darkSpan = SyntaxHighlighter.highlightLine(line, extension: 'model.dart', isDark: true);

      final lightClass = lightSpan.children!.firstWhere((s) => (s as TextSpan).text == 'class') as TextSpan;
      final darkClass = darkSpan.children!.firstWhere((s) => (s as TextSpan).text == 'class') as TextSpan;

      expect(lightClass.style?.color, const Color(0xFFD73A49));
      expect(darkClass.style?.color, const Color(0xFFFF7B72));
    });
  });

  group('RepositoryFilePage syntax highlight integration', () {
    final instance = GitLabInstance.parse('https://example.com/gitlab');
    final account = Account(
      instance: instance,
      user: const GitLabUser(id: 7, username: 'coder', name: 'Coder'),
      token: 'synthetic-token',
    );
    final project = Project.fromJson({
      'id': 42,
      'name': 'Project',
      'path': 'project',
      'path_with_namespace': 'group/project',
      'description': '',
      'visibility': 'private',
      'default_branch': 'main',
      'archived': false,
      'last_activity_at': '2026-09-20T10:00:00Z',
    });

    const sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

    testWidgets('renders highlighted TextSpans in code file viewer', (tester) async {
      const dartCode = 'class App {\n  final name = "GitLab";\n}\n';

      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/repository/files/lib%2Fapp.dart') && request.method == 'HEAD') {
          return ResponseBody.fromString('', 200, headers: {
            'x-gitlab-size': ['100'],
            'x-gitlab-last-commit-id': [sha],
          });
        }
        if (path.endsWith('/repository/files/lib%2Fapp.dart/raw')) {
          return ResponseBody.fromString(dartCode, 200);
        }
        return jsonResponse([]);
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          home: RepositoryFilePage(
            account: account,
            api: api,
            project: project,
            branch: 'main',
            sha: sha,
            filePath: 'lib/app.dart',
          ),
        ),
      );
      await settleNetworkWidgets(tester);

      expect(find.text('app.dart'), findsOneWidget);
      // 驗證 RichText 中包含語法高亮的 class 關鍵字
      bool containsSpanText(InlineSpan span, String target) {
        if (span is TextSpan) {
          if (span.text == target) return true;
          if (span.children != null) {
            return span.children!.any((c) => containsSpanText(c, target));
          }
        }
        return false;
      }

      final richTexts = tester.widgetList<RichText>(find.byType(RichText));
      final hasClassKeyword = richTexts.any((r) => containsSpanText(r.text, 'class'));
      expect(hasClassKeyword, isTrue);
    });
  });
}
