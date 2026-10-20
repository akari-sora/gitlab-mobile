import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/shared/markdown_media_html.dart';

void main() {
  group('HTML images', () {
    test('converts image attributes and carries dimensions internally', () {
      expect(
        preprocessMarkdownMedia(
          '<img alt="A &amp; B" src="docs/a b.png" width="320" height="180">',
        ),
        '![A & B](<docs/a b.png> "mergeline-size:320:180")',
      );
      expect(
        preprocessMarkdownMedia('<IMG SRC=a.png HEIGHT=40 />'),
        '![](<a.png> "mergeline-size::40")',
      );
    });

    test('removes layout wrappers and keeps a linked image clickable', () {
      expect(
        preprocessMarkdownMedia(
          '<div><center><a href="guide.html"><picture>'
          '<source srcset="large.webp"><img src="small.png" alt="Small">'
          '</picture></a></center></div>',
        ),
        '[![Small](<small.png>)](<guide.html>)\n\n',
      );
    });

    test('leaves unrelated HTML and ordinary HTML links intact', () {
      const source = '<span>text</span> <a href="page.html">page</a>';
      expect(preprocessMarkdownMedia(source), source);
      expect(
        preprocessMarkdownMedia('<img src="a.png" alt="&#999999999999;">'),
        '![&#999999999999;](<a.png>)',
      );
    });
  });

  group('media', () {
    test('converts video and audio sources to internal media tokens', () {
      expect(
        preprocessMarkdownMedia(
          '<video title="Demo" src="demo.mp4"></video>\n'
          '<audio><source src="sound.ogg" type="audio/ogg"></audio>',
        ),
        '![Demo](<demo.mp4> "mergeline-media:video")\n'
        '![](<sound.ogg> "mergeline-media:audio")',
      );
    });

    test('marks extensionless HTML audio for audio controls', () {
      expect(
        preprocessMarkdownMedia('<audio src="api/tracks/7"></audio>'),
        '![](<api/tracks/7> "mergeline-media:audio")',
      );
    });

    test('converts known Markdown media links and preserves destinations', () {
      expect(
        preprocessMarkdownMedia(
          '[Movie](clip.MP4?download=1#preview) [song](<audio file.m4a> "old") '
          '[page](page.html) ![poster](poster.png)',
        ),
        '![Movie](clip.MP4?download=1#preview "mergeline-media") '
        '![song](<audio file.m4a> "mergeline-media") '
        '[page](page.html) ![poster](poster.png)',
      );
    });

    test('does not rewrite the outer link of a linked image', () {
      const source = '[![poster](poster.png)](movie.mp4)';
      expect(preprocessMarkdownMedia(source), source);
    });

    test('converts reference links and media autolinks', () {
      const source =
          '[Clip][demo]\n\n'
          '`[not media](inside.mp4)`\n\n'
          '[demo]: https://cdn.example/demo.webm "Demo"\n\n'
          '<https://cdn.example/audio.m4a?raw=1>';
      expect(
        preprocessMarkdownMedia(source),
        '![Clip](https://cdn.example/demo.webm "mergeline-media")\n\n'
        '`[not media](inside.mp4)`\n\n'
        '[demo]: https://cdn.example/demo.webm "Demo"\n\n'
        '![](<https://cdn.example/audio.m4a?raw=1> "mergeline-media")',
      );
    });
  });

  test('does not touch fenced code or matching code spans', () {
    const source = '''
Before <img src="before.png">

```html
<img src="fenced.png">
[movie](fenced.mp4)
```

`<img src="inline.png">` and ``[audio](inline.mp3)``

After <audio src="after.wav"></audio>
''';
    expect(preprocessMarkdownMedia(source), '''
Before ![](<before.png>)

```html
<img src="fenced.png">
[movie](fenced.mp4)
```

`<img src="inline.png">` and ``[audio](inline.mp3)``

After ![](<after.wav> "mergeline-media:audio")
''');
  });

  test('hostile one MiB input completes within 500 ms', () {
    const mebibyte = 1024 * 1024;
    final source =
        '${List.filled(mebibyte ~/ 10, '<img ').join()}'
        '${List.filled(mebibyte ~/ 2, '[').join()}';
    preprocessMarkdownMedia('<img src="warmup.png">');
    final stopwatch = Stopwatch()..start();
    final result = preprocessMarkdownMedia(source);
    stopwatch.stop();

    expect(result, source);
    expect(stopwatch.elapsedMilliseconds, lessThan(500));
  });

  test('one MiB of unterminated reference lines stays linear', () {
    const mebibyte = 1024 * 1024;
    final source = List.filled(mebibyte ~/ 2, '[\n').join();
    preprocessMarkdownMedia('[warmup][media]\n[media]: clip.mp4');
    final stopwatch = Stopwatch()..start();
    final result = preprocessMarkdownMedia(source);
    stopwatch.stop();

    expect(result, source);
    expect(stopwatch.elapsedMilliseconds, lessThan(500));
  });

  test('nested anchors and malformed quoted tags stay linear', () {
    final nested =
        '${List.filled(20000, '<a href="x">').join()}'
        '<img src="image.png">'
        '${List.filled(20000, '</a>').join()}';
    final malformed = List.filled(50000, '<img alt="unterminated>').join();
    final stopwatch = Stopwatch()..start();
    final nestedResult = preprocessMarkdownMedia(nested);
    final malformedResult = preprocessMarkdownMedia(malformed);
    stopwatch.stop();

    expect(nestedResult, contains('![](<image.png>)'));
    expect(malformedResult, isNotEmpty);
    expect(stopwatch.elapsedMilliseconds, lessThan(500));
  });
}
