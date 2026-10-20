import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';

import 'support/fake_adapter.dart';

void main() {
  final shapes = <String, String>{
    'paragraph unknown tags': 'a\n${'<x>\n' * 16384}',
    'paragraph anchors': 'a\n${'<a href="x">\n' * 5462}',
    'inline unclosed video': 'v ${'<video>' * 9363}',
    'block unclosed video': '<div>\n${'<video>' * 9363}',
    'block unclosed audio': '<div>\n${'<audio>' * 9363}',
    'unclosed audio': '<audio>' * 9363,
  };
  for (final shape in shapes.entries) {
    testWidgets('FIX4 cap growth: ${shape.key}', (tester) async {
      final client = Dio()
        ..httpClientAdapter = FakeAdapter(
          (_) => ResponseBody.fromString('', 200),
        );
      addTearDown(client.close);

      Future<int> render(int length) async {
        // Tear down outside the timer so samples measure only this render.
        await tester.pumpWidget(const SizedBox.shrink());
        final source = shape.value.substring(0, length);
        final watch = Stopwatch()..start();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: MarkdownView(source, externalMediaClient: client),
              ),
            ),
          ),
        );
        await tester.pump();
        watch.stop();
        expect(tester.takeException(), isNull);
        return watch.elapsedMicroseconds;
      }

      await render(1024);
      // Use the best of three to reduce JIT/GC/scheduling noise without an
      // additive allowance that could conceal quadratic growth.
      var quarter = 1 << 62;
      var cap = 1 << 62;
      for (var sample = 0; sample < 3; sample++) {
        final measuredQuarter = await render(16384);
        final measuredCap = await render(65536);
        if (measuredQuarter < quarter) quarter = measuredQuarter;
        if (measuredCap < cap) cap = measuredCap;
      }
      debugPrint('FIX4 ${shape.key}: N=${quarter}us 4N=${cap}us');
      // Linear scans grow 4x from N to 4N and quadratic ones 16x. Laying out
      // one long unbroken line is already slightly superlinear (about 7x
      // here, as on main), so the ratio allows 12x; the original scans took
      // 2.8 to 66 s at the cap, far above the independent ceiling.
      expect(cap, lessThan(2000000), reason: '${shape.key}: cap < 2 s');
      expect(cap, lessThan(quarter * 12), reason: '${shape.key}: 4N growth');
    });
  }
}
