"""Keep AI libraries from depending on offline repository storage."""
from pathlib import Path
import re
import tempfile
import unittest
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[2] / 'lib'
TOKEN = re.compile(r'''(?s)//[^\n]*|/\*.*?\*/|(?:r)?(?:""".*?"""|\'\'\'.*?\'\'\'|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|[A-Za-z_]\w*|[^\s]''')
STRING = re.compile(r'''^(?:r)?(["'])(.*?)\1$''', re.S)


def directives(source):
    """Extract all URI choices from import/export/part directives."""
    tokens = [m.group() for m in TOKEN.finditer(source)
              if not m.group().startswith(('//', '/*'))]
    index = 0
    while index < len(tokens):
        kind = tokens[index]
        if kind not in ('import', 'export', 'part'):
            index += 1
            continue
        index += 1
        if index >= len(tokens) or not STRING.match(tokens[index]):
            continue
        uris = []
        while index < len(tokens) and tokens[index] != ';':
            match = STRING.match(tokens[index])
            if match:
                uris.append(match.group(2))
            index += 1
        if not uris or index == len(tokens):
            raise ValueError(f'malformed {kind} directive')
        yield kind, uris
        index += 1


def resolve_uri(lib, source, uri):
    parsed = urlsplit(uri)
    if parsed.scheme == 'package':
        if not parsed.path.startswith('gitlab_mobile/'):
            return None
        path = lib / unquote(parsed.path.removeprefix('gitlab_mobile/'))
    elif parsed.scheme:
        return None
    else:
        path = source.parent / unquote(parsed.path)
    if parsed.query or parsed.fragment:
        raise ValueError(f'invalid local URI: {uri}')
    return path.resolve()


def violations(lib):
    lib = lib.resolve()
    offline = lib / 'core/offline'
    roots = [lib / 'core/ai', lib / 'features/ai']
    queue = [(path, True) for root in roots for path in root.rglob('*.dart')]
    seen = set()
    found = []
    while queue:
        source, follow_imports = queue.pop()
        state = (source, follow_imports)
        if state in seen:
            continue
        seen.add(state)
        for kind, uris in directives(source.read_text(encoding='utf-8')):
            if kind == 'import' and not follow_imports:
                continue
            for uri in uris:
                target = resolve_uri(lib, source, uri)
                if target is None:
                    continue
                if target == offline or offline in target.parents:
                    found.append((source, uri))
                elif target.is_file():
                    # Imported libraries expose their exports and parts, but not
                    # their own private imports to the importing AI library.
                    queue.append((target, kind == 'part' and follow_imports))
    return found


class OfflineBoundariesTest(unittest.TestCase):
    def test_ai_does_not_import_offline_storage(self):
        self.assertEqual(violations(ROOT), [])

    def test_direct_conditional_export_and_part_are_checked(self):
        with tempfile.TemporaryDirectory() as directory:
            lib = Path(directory)
            ai = lib / 'core/ai'
            ai.mkdir(parents=True)
            offline = lib / 'core/offline'
            offline.mkdir(parents=True)
            (offline / 'secret.dart').write_text('class Secret {}')
            main = ai / 'main.dart'
            main.write_text("// import '../offline/secret.dart';\n"
                            "const x = \"import '../offline/secret.dart';\";\n")
            self.assertEqual(violations(lib), [])
            main.write_text("import 'safe.dart' if (dart.library.io) '../offline/secret.dart';")
            self.assertTrue(violations(lib))
            main.write_text("import 'barrel.dart';")
            (ai / 'barrel.dart').write_text("export 'part.dart';")
            (ai / 'part.dart').write_text("export '../offline/secret.dart';")
            self.assertTrue(violations(lib))
            main.write_text("part 'part.dart';")
            self.assertTrue(violations(lib))


if __name__ == '__main__':
    unittest.main()
