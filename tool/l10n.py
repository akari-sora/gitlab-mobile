#!/usr/bin/env python3
"""Generate the app's string tables from the ARB catalogs in lib/l10n/arb.

The template is app_zh_TW.arb, the language the app is written in. Every other
catalog must carry every message with the same {placeholders}. The generated
Dart is plain Dart, with no Flutter import, so lib/core can use it too:
lib/l10n/strings.g.dart holds the accessors and one part file per language
holds its messages.

    python3 tool/l10n.py           # regenerate
    python3 tool/l10n.py --check   # fail on incomplete catalogs or stale files
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
ARB_DIR = ROOT / 'lib/l10n/arb'
OUT_DIR = ROOT / 'lib/l10n'
TEMPLATE = 'zh_TW'

# (tag, ARB suffix, own name, language, script, country), in picker order.
LANGUAGES = [
    ('zh-TW', 'zh_TW', '繁體中文', 'zh', 'Hant', 'TW'),
    ('zh-CN', 'zh_CN', '简体中文', 'zh', 'Hans', 'CN'),
    ('en', 'en', 'English', 'en', None, None),
    ('ja', 'ja', '日本語', 'ja', None, None),
    ('ko', 'ko', '한국어', 'ko', None, None),
    ('es', 'es', 'Español', 'es', None, None),
    ('pt-BR', 'pt_BR', 'Português (Brasil)', 'pt', None, 'BR'),
    ('fr', 'fr', 'Français', 'fr', None, None),
    ('de', 'de', 'Deutsch', 'de', None, None),
    ('it', 'it', 'Italiano', 'it', None, None),
    ('ru', 'ru', 'Русский', 'ru', None, None),
    ('uk', 'uk', 'Українська', 'uk', None, None),
    ('pl', 'pl', 'Polski', 'pl', None, None),
    ('nl', 'nl', 'Nederlands', 'nl', None, None),
    ('sv', 'sv', 'Svenska', 'sv', None, None),
    ('cs', 'cs', 'Čeština', 'cs', None, None),
    ('ro', 'ro', 'Română', 'ro', None, None),
    ('tr', 'tr', 'Türkçe', 'tr', None, None),
    ('ar', 'ar', 'العربية', 'ar', None, None),
    ('hi', 'hi', 'हिन्दी', 'hi', None, None),
    ('th', 'th', 'ไทย', 'th', None, None),
    ('vi', 'vi', 'Tiếng Việt', 'vi', None, None),
    ('id', 'id', 'Bahasa Indonesia', 'id', None, None),
    ('ms', 'ms', 'Bahasa Melayu', 'ms', None, None),
]

PLACEHOLDER = re.compile(r'\{([A-Za-z][A-Za-z0-9]*)\}')
KEY = re.compile(r'^[a-z][A-Za-z0-9]*$')
DART_RESERVED = {
    'abstract', 'as', 'assert', 'async', 'await', 'base', 'break', 'case', 'catch', 'class', 'const',
    'continue', 'covariant', 'default', 'deferred', 'do', 'dynamic', 'else', 'enum', 'export', 'extends',
    'extension', 'external', 'factory', 'false', 'final', 'finally', 'for', 'function', 'get', 'hide',
    'if', 'implements', 'import', 'in', 'interface', 'is', 'late', 'library', 'mixin', 'new', 'null',
    'of', 'on', 'operator', 'part', 'required', 'rethrow', 'return', 'sealed', 'set', 'show', 'static',
    'super', 'switch', 'sync', 'this', 'throw', 'true', 'try', 'type', 'typedef', 'var', 'void', 'when',
    'while', 'with', 'yield', 'language', 'hashCode', 'runtimeType', 'toString', 'noSuchMethod',
}


# Words that can never name a parameter, plus `language`, which would shadow
# the field the generated accessors read.
PARAMETER_RESERVED = {
    'assert', 'break', 'case', 'catch', 'class', 'const', 'continue', 'default', 'do', 'else', 'enum',
    'extends', 'false', 'final', 'finally', 'for', 'if', 'in', 'is', 'new', 'null', 'rethrow', 'return',
    'super', 'switch', 'this', 'throw', 'true', 'try', 'var', 'void', 'while', 'with', 'language',
}


class CatalogError(Exception):
    pass


def placeholders(text: str) -> list[str]:
    return PLACEHOLDER.findall(text)


def _read_arb(path: Path) -> dict:
    """Parses one catalog, rejecting a key that appears twice."""
    def unique(pairs: list[tuple[str, object]]) -> dict:
        seen: dict[str, object] = {}
        for key, value in pairs:
            if key in seen:
                raise CatalogError(f'{path.name}: duplicate key {key}')
            seen[key] = value
        return seen
    return json.loads(path.read_text(encoding='utf-8'), object_pairs_hook=unique)


def load(arb_dir: Path = ARB_DIR) -> tuple[list[str], dict[str, dict[str, str]]]:
    """The message keys in template order and every language's messages."""
    template = _read_arb(arb_dir / f'app_{TEMPLATE}.arb')
    keys = [key for key in template if not key.startswith('@')]
    errors = []
    for key in keys:
        if not KEY.match(key) or key in DART_RESERVED:
            errors.append(f'{key}: not a usable Dart identifier')
        stray = PLACEHOLDER.sub('', template[key])
        if '{' in stray or '}' in stray:
            errors.append(f'{key}: a brace that is not a {{placeholder}}')
        for name in set(placeholders(template[key])):
            if name in PARAMETER_RESERVED:
                errors.append(f'{key}: placeholder {{{name}}} is not a usable Dart parameter name')
        declared = set((template.get(f'@{key}') or {}).get('placeholders', {}))
        if declared != set(placeholders(template[key])):
            errors.append(f'{key}: placeholders in @{key} do not match the message')
    catalogs: dict[str, dict[str, str]] = {}
    for tag, suffix, *_ in LANGUAGES:
        path = arb_dir / f'app_{suffix}.arb'
        if not path.is_file():
            errors.append(f'{path.name}: missing')
            continue
        data = _read_arb(path)
        if data.get('@@locale') != suffix:
            errors.append(f'{path.name}: @@locale is not {suffix}')
        messages = {key: value for key, value in data.items() if not key.startswith('@')}
        extra = set(messages) - set(keys)
        if extra:
            errors.append(f'{path.name}: unknown keys {sorted(extra)[:5]}')
        for key in keys:
            value = messages.get(key)
            if not isinstance(value, str) or not value.strip():
                errors.append(f'{path.name}: {key} is missing or empty')
                continue
            if sorted(placeholders(value)) != sorted(placeholders(template[key])):
                errors.append(f'{path.name}: {key} has placeholders {placeholders(value)}, '
                              f'expected {placeholders(template[key])}')
            stray = PLACEHOLDER.sub('', value)
            if '{' in stray or '}' in stray:
                errors.append(f'{path.name}: {key} has a brace that is not a {{placeholder}}')
        catalogs[tag] = messages
    if errors:
        raise CatalogError('\n'.join(errors[:50]) + (f'\n… {len(errors) - 50} more' if len(errors) > 50 else ''))
    return keys, catalogs


def _dart_string(value: str) -> str:
    escaped = (value.replace('\\', '\\\\').replace("'", "\\'").replace('$', '\\$')
               .replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t'))
    return f"'{escaped}'"


def _doc(text: str) -> str:
    return text.replace('\r', ' ').replace('\n', ' ').replace('*/', '* /')


def _dart_suffix(suffix: str) -> str:
    return ''.join(part.capitalize() for part in suffix.split('_'))


def render(keys: list[str], catalogs: dict[str, dict[str, str]]) -> dict[str, str]:
    """The generated files, by name relative to lib/l10n."""
    template = catalogs[LANGUAGES[0][0]]
    header = '// GENERATED by tool/l10n.py from lib/l10n/arb. Do not edit.\n'
    files: dict[str, str] = {}
    lines = [header, '// ignore_for_file: lines_longer_than_80_chars\n', '\n']
    for _, suffix, *_ in LANGUAGES:
        lines.append(f"part 'strings_{suffix}.g.dart';\n")
    lines += [
        '\n',
        '/// One language the app is translated into.\n',
        'final class AppLanguage {\n',
        '  const AppLanguage._(this.tag, this.name, this.languageCode, this.scriptCode, this.countryCode, this._messages);\n',
        '\n',
        '  /// BCP 47 tag, as stored for the language picker.\n',
        '  final String tag;\n',
        '\n',
        '  /// The language\'s own name, for the picker.\n',
        '  final String name;\n',
        '  final String languageCode;\n',
        '  final String? scriptCode;\n',
        '  final String? countryCode;\n',
        '  final List<String> _messages;\n',
        '}\n',
        '\n',
        '/// Every language, the one the app is written in first.\n',
        'const appLanguages = <AppLanguage>[\n',
    ]
    for tag, suffix, name, language, script, country in LANGUAGES:
        script_text = f"'{script}'" if script else 'null'
        country_text = f"'{country}'" if country else 'null'
        lines.append(f"  AppLanguage._('{tag}', {_dart_string(name)}, '{language}', {script_text}, "
                     f"{country_text}, _messages{_dart_suffix(suffix)}),\n")
    lines += [
        '];\n',
        '\n',
        "final _placeholder = RegExp(r'\\{([A-Za-z][A-Za-z0-9]*)\\}');\n",
        '\n',
        'String _format(String message, Map<String, Object?> values) => message.replaceAllMapped(\n',
        '    _placeholder, (match) => values.containsKey(match[1]) ? \'${values[match[1]]}\' : match[0]!);\n',
        '\n',
        '/// The app\'s messages in one language. Each accessor\'s doc shows the\n',
        '/// Traditional Chinese source text.\n',
        'final class AppStrings {\n',
        '  const AppStrings(this.language);\n',
        '  final AppLanguage language;\n',
    ]
    for index, key in enumerate(keys):
        source = template[key]
        names = list(dict.fromkeys(placeholders(source)))
        lines.append('\n')
        lines.append(f'  /// {_doc(source)}\n')
        if names:
            params = ', '.join(f'Object? {name}' for name in names)
            values = ', '.join(f"'{name}': {name}" for name in names)
            lines.append(f'  String {key}({params}) => _format(language._messages[{index}], {{{values}}});\n')
        else:
            lines.append(f'  String get {key} => language._messages[{index}];\n')
    lines.append('}\n')
    files['strings.g.dart'] = ''.join(lines)
    for tag, suffix, *_ in LANGUAGES:
        messages = catalogs[tag]
        body = [header, "part of 'strings.g.dart';\n", '\n',
                f'const _messages{_dart_suffix(suffix)} = <String>[\n']
        for key in keys:
            body.append(f'  {_dart_string(messages[key])},\n')
        body.append('];\n')
        files[f'strings_{suffix}.g.dart'] = ''.join(body)
    return files


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--check', action='store_true', help='fail instead of writing when anything is stale')
    args = parser.parse_args(argv)
    try:
        keys, catalogs = load()
    except CatalogError as error:
        print(error, file=sys.stderr)
        return 1
    files = render(keys, catalogs)
    stale = [name for name, text in files.items()
             if not (OUT_DIR / name).is_file() or (OUT_DIR / name).read_text(encoding='utf-8') != text]
    known = {path.name for path in OUT_DIR.glob('strings*.g.dart')}
    orphans = sorted(known - set(files))
    if args.check:
        if stale or orphans:
            print(f'Generated l10n files are stale: {stale + orphans}. Run python3 tool/l10n.py.', file=sys.stderr)
            return 1
        print(f'{len(keys)} messages in {len(LANGUAGES)} languages; generated files current.')
        return 0
    for name in stale:
        (OUT_DIR / name).write_text(files[name], encoding='utf-8')
    for name in orphans:
        (OUT_DIR / name).unlink()
    print(f'{len(keys)} messages in {len(LANGUAGES)} languages; wrote {len(stale)} files.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
