import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/shared/markdown_media_svg.dart';
// ignore: depend_on_referenced_packages
import 'package:vector_graphics_compiler/vector_graphics_compiler.dart';

void main() {
  Uint8List bytes(String value) => Uint8List.fromList(utf8.encode(value));

  String pngData(int width, int height) {
    final data = Uint8List(24)
      ..setAll(0, const [137, 80, 78, 71, 13, 10, 26, 10])
      ..setAll(12, const [73, 72, 68, 82]);
    final view = ByteData.sublistView(data);
    view.setUint32(16, width);
    view.setUint32(20, height);
    return base64Encode(data);
  }

  String jpegData(int width, int height) => base64Encode(
    Uint8List.fromList([
      0xff,
      0xd8,
      0xff,
      0xc0,
      0x00,
      0x0b,
      0x08,
      height >> 8,
      height & 0xff,
      width >> 8,
      width & 0xff,
      0x01,
      0x01,
      0x11,
      0x00,
      0xff,
      0xd9,
    ]),
  );

  test('sanitises common Inkscape and Illustrator SVG exports', () async {
    final fixtures = [
      '''<?xml version="1.0" encoding="UTF-8"?>
<!-- Created with Inkscape -->
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<svg xmlns="http://www.w3.org/2000/svg"><style>.a { fill: red; }</style><path class="a" d="M0 0h1v1z"/></svg>''',
      '''<?xml version="1.0" encoding="utf-8"?>
<!-- Generator: Adobe Illustrator -->
<svg xmlns="http://www.w3.org/2000/svg"><style type="text/css">.st0{fill:#fff;}</style><rect class="st0" width="1" height="1"/></svg>''',
    ];

    for (final fixture in fixtures) {
      final result = await sanitizeMarkdownSvg(bytes(fixture));
      expect(result, isNotNull);
      final text = utf8.decode(result!);
      expect(text, contains('<svg'));
      expect(text, isNot(contains('<!--')));
      expect(text.toLowerCase(), isNot(contains('<!doctype')));
      expect(text.toLowerCase(), isNot(contains('<style')));
    }
  });

  test(
    'detects SVG after declarations and trusts the SVG content type',
    () async {
      final prefixed = bytes(
        '<?xml version="1.0"?><!-- export --><!DOCTYPE svg><svg><rect/></svg>',
      );
      expect(await sanitizeMarkdownSvg(prefixed), isNotNull);
      expect(
        await sanitizeMarkdownSvg(
          bytes('\n<!-- export -->\n<svg><rect/></svg>'),
          contentType: 'image/svg+xml',
        ),
        isNotNull,
      );
      expect(await sanitizeMarkdownSvg(bytes('not an image')), isNull);
    },
  );

  test('rejects active content, external references, and entities', () async {
    for (final value in [
      '<svg><script>alert(1)</script></svg>',
      '<svg><image href="https://other.example/a.png"/></svg>',
      '<svg><image xlink:href="data:image/png;base64,AAAA"/></svg>',
      '<svg><path fill="url(https://other.example/a.svg)"/></svg>',
      '<!DOCTYPE svg [<!ENTITY xxe SYSTEM "file:///etc/passwd">]><svg>&xxe;</svg>',
      '<?xml-stylesheet href="https://other.example/a.css"?><svg/>',
    ]) {
      await expectLater(
        sanitizeMarkdownSvg(bytes(value), contentType: 'image/svg+xml'),
        throwsA(isA<ApiFailure>()),
        reason: value,
      );
    }
  });

  test('rejects Argon quote smuggling and decoded external values', () async {
    for (final value in [
      '''<svg xmlns="http://www.w3.org/2000/svg"><image id="href='#2" href="https://evil.example/leak.png" data-end="'"/></svg>''',
      '''<svg xmlns="http://www.w3.org/2000/svg"><rect id="url(#" fill="url(https://evil.example/a.svg)"/></svg>''',
      '''<svg xmlns="http://www.w3.org/2000/svg"><rect fill="&#x75;rl(https://evil.example/a.svg)"/></svg>''',
      '''<svg xmlns="http://www.w3.org/2000/svg"><image style="href: https://evil.example/a.png"/></svg>''',
      '''<svg xmlns="http://www.w3.org/2000/svg"><rect style="fill: &#x75;rl(https://evil.example/a.svg)"/></svg>''',
    ]) {
      await expectLater(
        sanitizeMarkdownSvg(bytes(value)),
        throwsA(isA<ApiFailure>()),
        reason: value,
      );
    }
  });

  test('rejects forbidden elements and event handler attributes', () async {
    for (final value in [
      '<svg xmlns="http://www.w3.org/2000/svg"><foreignObject><div>x</div></foreignObject></svg>',
      '<svg xmlns="http://www.w3.org/2000/svg"><rect onload="alert(1)"/></svg>',
      '<svg xmlns="http://www.w3.org/2000/svg"><rect ONCLICK="alert(1)"/></svg>',
    ]) {
      await expectLater(
        sanitizeMarkdownSvg(bytes(value)),
        throwsA(isA<ApiFailure>()),
        reason: value,
      );
    }
  });

  test(
    'allows bounded embedded raster images and enforces byte and pixel limits',
    () async {
      final safe = pngData(10, 10);
      final oversized = pngData(6000, 5000);
      final oversizedBytes = Uint8List(5 * 1024 * 1024 + 1)
        ..setAll(0, base64Decode(safe));
      expect(
        await sanitizeMarkdownSvg(
          bytes('<svg><image href="data:image/png;base64,$safe"/></svg>'),
        ),
        isNotNull,
      );
      await expectLater(
        sanitizeMarkdownSvg(
          bytes(
            '''<svg><image id="href='#2" xlink:href="data:image/png;base64,$oversized" data-end="'"/></svg>''',
          ),
        ),
        throwsA(
          isA<ApiFailure>().having(
            (failure) => failure.kind,
            'kind',
            FailureKind.tooLarge,
          ),
        ),
      );
      await expectLater(
        sanitizeMarkdownSvg(
          bytes(
            '<svg><image href="data:image/png;base64,${base64Encode(oversizedBytes)}"/></svg>',
          ),
        ),
        throwsA(
          isA<ApiFailure>().having(
            (failure) => failure.kind,
            'kind',
            FailureKind.tooLarge,
          ),
        ),
      );
    },
  );

  test('accepts renderer-compatible base64 whitespace and image/jpg', () async {
    final png = pngData(10, 10);
    final wrappedPng = '${png.substring(0, 8)}\n  ${png.substring(8)}';
    final jpg = jpegData(10, 10);

    expect(
      await sanitizeMarkdownSvg(
        bytes('<svg><image href="data:image/png;base64,$wrappedPng"/></svg>'),
      ),
      isNotNull,
    );
    expect(
      await sanitizeMarkdownSvg(
        bytes('<svg><image href="data:image/jpg;base64,$jpg"/></svg>'),
      ),
      isNotNull,
    );
  });

  test('strips inert external anchor links but keeps badge contents', () async {
    final result = await sanitizeMarkdownSvg(
      bytes(
        '<svg xmlns="http://www.w3.org/2000/svg"><a xlink:href="https://github.com/org/repo"><rect width="10" height="10" fill="red"/></a></svg>',
      ),
    );

    final text = utf8.decode(result!);
    expect(text, contains('<a'));
    expect(text, contains('<rect'));
    expect(text, isNot(contains('href=')));
    expect(text, isNot(contains('https://')));
  });

  test(
    'normalises quoted local paint references into compiled drawing commands',
    () async {
      final result = await sanitizeMarkdownSvg(
        bytes('''
<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10" viewBox="0 0 10 10">
  <defs>
    <linearGradient id="g"><stop stop-color="#ff0000"/><stop offset="1" stop-color="#0000ff"/></linearGradient>
  </defs>
  <rect width="10" height="10" fill="url(&quot;#g&quot;)"/>
</svg>
'''),
      );
      final sanitised = utf8.decode(result!);
      expect(sanitised, contains('fill="url(#g)"'));
      final instructions = parseWithoutOptimizers(sanitised);
      expect(instructions.commands, isNotEmpty);
    },
  );

  test('validates references in every attribute and inline style', () async {
    final result = await sanitizeMarkdownSvg(
      bytes(
        '<svg><defs><path id="local"/></defs><use href="#local" style="fill: url(#local)" data-paint="url(#local)"/></svg>',
      ),
    );
    expect(result, isNotNull);

    for (final value in [
      '<svg><use href="local"/></svg>',
      '<svg><use xlink:href="https://evil.example/a.svg"/></svg>',
      '<svg><path data-paint="url(data:image/png;base64,AAAA)"/></svg>',
      '<svg><path style="fill:url(https://evil.example/a.svg)"/></svg>',
    ]) {
      await expectLater(
        sanitizeMarkdownSvg(bytes(value)),
        throwsA(isA<ApiFailure>()),
        reason: value,
      );
    }
  });

  test('keeps local references and predefined XML entities', () async {
    final result = await sanitizeMarkdownSvg(
      bytes(
        '<svg><use href="#local"/><text>&amp;&lt;&gt;&quot;&apos;</text></svg>',
      ),
    );
    expect(result, isNotNull);
  });

  test('validates a 1 MiB text and attribute run in under 500 ms', () async {
    final run = 'a' * (1024 * 1024);
    final fixture = bytes(
      '<svg xmlns="http://www.w3.org/2000/svg"><desc data-run="$run">$run</desc></svg>',
    );
    final watch = Stopwatch()..start();
    final result = await sanitizeMarkdownSvg(fixture);
    watch.stop();

    expect(result, isNotNull);
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
  });

  test(
    'applies the markup cap before full MIME-sniffed XML validation',
    () async {
      final fixture = bytes('<svg>${'<g/>' * 100001}');

      await expectLater(
        sanitizeMarkdownSvg(fixture),
        throwsA(
          isA<ApiFailure>().having(
            (failure) => failure.kind,
            'kind',
            FailureKind.tooLarge,
          ),
        ),
      );
    },
  );

  test('removes a large flat comment list within the bounded budget', () async {
    final fixture = bytes('<svg>${'<!--x-->' * 99997}<rect/></svg>');
    final watch = Stopwatch()..start();
    final result = await sanitizeMarkdownSvg(fixture);
    watch.stop();

    expect(result, isNotNull);
    expect(utf8.decode(result!), isNot(contains('<!--')));
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  });
}
