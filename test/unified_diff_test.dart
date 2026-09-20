import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/unified_diff.dart';

void main() {
  test('anchors additions deletions and context independently of visual row', () {
    final lines = parseUnifiedDiff('@@ -8,3 +8,3 @@\n before\n-old\n+new\n after\n');
    expect(lines[1].oldLine, 8); expect(lines[1].newLine, 8);
    expect(lines[2].oldLine, 9); expect(lines[2].newLine, isNull);
    expect(lines[3].oldLine, isNull); expect(lines[3].newLine, 9);
    expect(lines[4].oldLine, 10); expect(lines[4].newLine, 10);
  });
  test('new file and no-newline metadata have no fabricated old line', () {
    final lines = parseUnifiedDiff('@@ -0,0 +1 @@\n+hello\n\\ No newline at end of file\n');
    expect(lines[1].oldLine, isNull); expect(lines[1].newLine, 1);
    expect(lines.last.commentable, isFalse);
  });
  test('multiple hunks reset both line counters', () {
    final lines = parseUnifiedDiff('@@ -1 +1 @@\n-a\n+b\n@@ -9 +10 @@\n context\n');
    expect(lines.last.oldLine, 9); expect(lines.last.newLine, 10);
  });
  test('truncated malformed and overfilled hunks fail closed', () {
    for (final source in ['@@ -1,2 +1,2 @@\n a\n', '@@ -1 +1 @@\n a\n b\n', 'not a diff']) {
      expect(() => parseUnifiedDiff(source), throwsFormatException);
    }
  });
}
