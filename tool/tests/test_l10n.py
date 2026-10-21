"""Checks for the string catalogs and their generated Dart (tool/l10n.py)."""
from __future__ import annotations

import json
from pathlib import Path
import re
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import l10n  # noqa: E402

LIB = l10n.ROOT / 'lib'
HAN = re.compile(r'[\u3400-\u9fff\uf900-\ufaff\uff00-\uffef\u3000-\u303f\U00020000-\U0003134f]')


def string_literals(source: str):
    """Yields (line, text) for every string literal in Dart source, skipping
    comments, including literals nested inside `${...}` interpolations. The
    text of an interpolated literal leaves out its nested expressions."""
    found: list[tuple[int, str]] = []
    n = len(source)

    def line_at(index: int) -> int:
        return source.count('\n', 0, index) + 1

    def code(i: int, stop_at_brace: bool) -> int:
        depth = 0
        while i < n:
            ch = source[i]
            if source.startswith('//', i):
                end = source.find('\n', i)
                i = n if end < 0 else end
            elif source.startswith('/*', i):
                level, i = 1, i + 2
                while i < n and level:
                    if source.startswith('/*', i):
                        level, i = level + 1, i + 2
                    elif source.startswith('*/', i):
                        level, i = level - 1, i + 2
                    else:
                        i += 1
            elif ch in '\'"':
                raw = i > 0 and source[i - 1] in 'rR' and (i < 2 or not (source[i - 2].isalnum() or source[i - 2] == '_'))
                i = string(i, raw)
            elif ch == '{':
                depth += 1
                i += 1
            elif ch == '}':
                if depth == 0 and stop_at_brace:
                    return i + 1
                depth -= 1
                i += 1
            else:
                i += 1
        return i

    def string(i: int, raw: bool) -> int:
        quote = source[i:i + 3] if source[i:i + 3] in ("'''", '"""') else source[i]
        start, i = i, i + len(quote)
        text: list[str] = []
        while i < n and not source.startswith(quote, i):
            ch = source[i]
            if ch == '\\' and not raw:
                text.append(source[i:i + 2])
                i += 2
            elif ch == '$' and not raw and source.startswith('${', i):
                i = code(i + 2, True)
            else:
                text.append(ch)
                i += 1
        found.append((line_at(start), ''.join(text)))
        return i + len(quote)

    code(0, False)
    return found


class StringLiteralScannerTest(unittest.TestCase):
    def test_skips_comments_and_finds_every_quote_style(self):
        source = (
            "// 註解 'x'\n"
            "/* 區塊 /* 巢狀 */ 'y' */\n"
            "final a = '中文';\n"
            'final b = "雙引號 \\" 跳脫";\n'
            "final c = '''三引號\n跨行''';\n"
            "final d = r'raw \\';\n"
            "final e = 'English';\n"
            "final f = '${x ? '巢狀' : ''} // 不是註解';\n"
            "final g = 'https://example.com'; // 註解 '假'\n"
            "final h = r'C:\\'; final i = '最後';\n"
        )
        texts = [(line, text) for line, text in string_literals(source) if HAN.search(text)]
        self.assertEqual([line for line, _ in texts], [3, 4, 5, 9, 9, 11])


class CatalogTest(unittest.TestCase):
    def test_generated_files_are_current(self):
        self.assertEqual(l10n.main(['--check']), 0, 'run python3 tool/l10n.py and commit the result')

    def test_every_language_has_its_own_catalog(self):
        tags = [tag for tag, *_ in l10n.LANGUAGES]
        self.assertEqual(tags[0], 'zh-TW', 'the template comes first')
        self.assertEqual(len(tags), len(set(tags)))
        for _, suffix, *_ in l10n.LANGUAGES:
            self.assertTrue((l10n.ARB_DIR / f'app_{suffix}.arb').is_file(), suffix)

    def test_translations_are_not_the_chinese_source(self):
        keys, catalogs = l10n.load()
        for tag, catalog in catalogs.items():
            if tag in ('zh-TW', 'zh-CN', 'ja'):
                continue
            with self.subTest(tag):
                leftover = [key for key in keys if HAN.search(catalog[key])]
                self.assertEqual(leftover[:10], [], f'{tag} still has Chinese text')

    def test_screen_names_are_translated(self):
        # The tabs and the Me page's rows name places other messages point
        # to, so they must be translated, not left in English.
        screens = ['homeTab', 'inboxTab', 'exploreTab', 'meTab', 'appearanceLabel', 'securityLabel',
                   'appLockLabel', 'appUpdatesLabel', 'linksLabel', 'myWorkLabel', 'myProjects']
        # The same word as in English is the right one here.
        same_word = {('de', 'linksLabel'), ('pt-BR', 'linksLabel'), ('it', 'homeTab'), ('nl', 'inboxTab')}
        _, catalogs = l10n.load()
        english = catalogs['en']
        for tag, catalog in catalogs.items():
            if tag == 'en':
                continue
            with self.subTest(tag):
                untranslated = [key for key in screens
                                if catalog[key] == english[key] and (tag, key) not in same_word]
                self.assertEqual(untranslated, [], f'{tag} shows these screens in English')
                if tag in ('ar', 'hi', 'th', 'ru', 'uk', 'ko', 'ja', 'zh-CN', 'zh-TW'):
                    latin = [key for key in screens if re.search(r'[A-Za-z]', catalog[key].replace('App', ''))]
                    self.assertEqual(latin, [], f'{tag} mixes Latin script into these screen names')

    def test_ai_strings_are_translated(self):
        # AI messages are translated in every catalog; scripts other than
        # Latin keep only product and protocol names in Latin letters.
        product_words = {
            'AI', 'API', 'URL', 'HTTP', 'HTTPS', 'JSON', 'Mergeline',
            'GitLab', 'OpenAI', 'Anthropic', 'OpenRouter', 'OpenCode', 'Azure',
            'Gemini', 'DeepSeek', 'xAI', 'Ollama', 'LM', 'Studio',
            'GPT', 'Claude', 'Grok', 'Google',
        }
        non_latin = {'ar', 'hi', 'th', 'ru', 'uk', 'ko', 'ja', 'zh-CN', 'zh-TW'}
        # Wire-format and header names are protocol identifiers: they stay
        # exactly as in English in every language.
        protocol_keys = {
            'aiProviderFormatChat', 'aiProviderFormatResponses', 'aiProviderFormatAnthropic',
            'aiConsentFormatChatCompletions', 'aiConsentFormatResponses',
            'aiConsentFormatAnthropicMessages', 'aiProviderAuthBearer', 'aiProviderAuthApiKey',
            'aiProviderAuthXApiKey',
        }
        # Both Chinese catalogs call a job log "Log" everywhere (viewJobLog)
        # and keep "Pipeline" untranslated (runPipeline, noPipelines).
        local_words = {'zh-TW': {'Log', 'Pipeline'}, 'zh-CN': {'Log', 'Pipeline'}}
        keys, catalogs = l10n.load()
        ai_keys = [key for key in keys if key.startswith('ai')]
        self.assertTrue(ai_keys)
        self.assertLessEqual(protocol_keys, set(ai_keys))
        english = catalogs['en']
        for tag, catalog in catalogs.items():
            if tag == 'en':
                continue
            for key in ai_keys:
                with self.subTest(tag=tag, key=key):
                    if key in protocol_keys:
                        self.assertEqual(catalog[key], english[key], 'protocol names stay exact')
                        continue
                    self.assertNotEqual(catalog[key], english[key], 'AI text needs translation')
                    if tag in non_latin:
                        # Placeholders are argument names, not displayed text.
                        text = re.sub(r'\{[^}]*\}', '', catalog[key])
                        # A URL path the user must type (`/models`) stays literal.
                        text = re.sub(r'(?<![A-Za-z])/models(?![A-Za-z])', '', text)
                        words = set(re.findall(r'[A-Za-z]+', text))
                        allowed = product_words | local_words.get(tag, set())
                        self.assertEqual(words - allowed, set(), 'unexpected Latin text')

    def test_generated_dart_escapes_bidi_controls(self):
        # Raw embedding, override or isolate characters in a Dart literal
        # fail `text_direction_code_point_in_literal`; they must be escapes.
        controls = {chr(c) for c in (*range(0x202A, 0x202F), *range(0x2066, 0x206A))}
        for path in sorted((LIB / 'l10n').glob('strings*.g.dart')):
            with self.subTest(path=path.name):
                found = controls & set(path.read_text(encoding='utf-8'))
                self.assertEqual(found, set())

    def test_rtl_catalogs_isolate_a_literal_path(self):
        # In a right-to-left line a leading slash takes the paragraph's
        # direction, so `/models` would read `models/` unless it is isolated.
        _, catalogs = l10n.load()
        for tag, catalog in catalogs.items():
            if tag.split('-')[0] not in l10n.RTL_LANGUAGES:
                continue
            for key, value in catalog.items():
                for match in re.finditer(r'/models', value):
                    with self.subTest(tag=tag, key=key):
                        start, end = match.span()
                        self.assertEqual(value[start - 1:start], '\u2066')
                        self.assertEqual(value[end:end + 1], '\u2069')

    def test_ai_runner_notices_keep_security_and_budget_semantics(self):
        # Each replay notice must say both why the run stopped and why already
        # sent content cannot be retracted. These are reviewed glossary phrases,
        # not whole-message snapshots, so translators can still improve prose.
        replay_markers = {
            'ar': ('سر جديد', 'لا يمكن سحب'),
            'cs': ('nový tajný údaj', 'nelze vzít zpět'),
            'de': ('neues Geheimnis', 'nicht zurückgezogen'),
            'en': ('new secret', 'cannot be retracted'),
            'es': ('secreto nuevo', 'no se puede retirar'),
            'fr': ('nouveau secret', 'ne peut pas être retiré'),
            'hi': ('नया रहस्य', 'वापस नहीं ली जा सकती'),
            'id': ('Rahasia baru', 'tidak dapat ditarik kembali'),
            'it': ('nuovo segreto', 'non possono essere ritirati'),
            'ja': ('新しい秘密情報', '取り消せない'),
            'ko': ('새로운 비밀 정보', '취소할 수 없어'),
            'ms': ('Rahsia baharu', 'tidak boleh ditarik balik'),
            'nl': ('nieuw geheim', 'niet kan worden ingetrokken'),
            'pl': ('nowy sekret', 'nie można wycofać'),
            'pt-BR': ('novo segredo', 'não pode ser retirado'),
            'ro': ('secret nou', 'nu poate fi retras'),
            'ru': ('новый секрет', 'нельзя отозвать'),
            'sv': ('ny hemlighet', 'inte kan återkallas'),
            'th': ('ความลับใหม่', 'ไม่สามารถเรียกคืน'),
            'tr': ('yeni bir gizli bilgi', 'geri alınamayacağı'),
            'uk': ('новий секрет', 'неможливо відкликати'),
            'vi': ('bí mật mới', 'không thể thu hồi'),
            'zh-CN': ('新的秘密', '无法撤回'),
            'zh-TW': ('新的秘密', '無法撤回'),
        }
        _, catalogs = l10n.load()
        self.assertEqual(set(replay_markers), set(catalogs))
        for tag, catalog in catalogs.items():
            with self.subTest(tag=tag):
                self.assertIn('GitLab', catalog['aiBudgetGitLabReads'])
                replay = catalog['aiReplayProtectionStopped']
                for marker in replay_markers[tag]:
                    self.assertIn(marker, replay)
                self.assertTrue(catalog['aiEndTokenBudget'].strip())

    def test_ai_history_uses_stable_ai_and_api_terms(self):
        _, catalogs = l10n.load()
        history_keys = [
            'aiHistoryCleanupTitle',
            'aiHistoryCleanupDetail',
            'aiHistoryInvalidData',
            'aiHistoryIndexRepaired',
            'aiHistoryUnsupported',
        ]
        for tag, catalog in catalogs.items():
            for key in history_keys:
                with self.subTest(tag=tag, key=key):
                    self.assertIn('AI', catalog[key])

        self.assertNotIn('المساعد الذكي', catalogs['ar']['aiHistoryCleanupTitle'])
        self.assertIn('Sie', catalogs['de']['aiHistoryCleanupDetail'])

    def test_ai_history_recovery_messages_are_complete(self):
        required = {
            'aiHistoryReadFailed',
            'aiHistoryTemporaryFilesRemoved',
            'aiHistoryClearUnsupported',
        }
        keys, catalogs = l10n.load()
        self.assertTrue(required.issubset(keys))
        self.assertNotIn('aiKeyTooShort', keys)
        for tag, catalog in catalogs.items():
            with self.subTest(tag=tag):
                self.assertTrue(required.issubset(catalog))

    def test_no_chinese_string_literals_outside_the_catalogs(self):
        found = []
        for path in sorted(LIB.rglob('*.dart')):
            if path.parent == LIB / 'l10n':
                continue
            for line, text in string_literals(path.read_text(encoding='utf-8')):
                if HAN.search(text):
                    found.append(f'{path.relative_to(l10n.ROOT)}:{line}: {text[:60]}')
        self.assertEqual(found, [], 'UI text belongs in lib/l10n/arb; reference it through l10n')


class LoadValidationTest(unittest.TestCase):
    def _write(self, folder: Path, catalogs: dict[str, dict]) -> None:
        for _, suffix, *_ in l10n.LANGUAGES:
            data = catalogs.get(suffix, catalogs['*'])
            (folder / f'app_{suffix}.arb').write_text(
                json.dumps({'@@locale': suffix, **data}, ensure_ascii=False), encoding='utf-8')

    def _template(self) -> dict:
        return {'greeting': '你好 {name}', '@greeting': {'placeholders': {'name': {}}}, 'plain': '一般'}

    def test_a_complete_set_loads(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._write(Path(tmp), {'zh_TW': self._template(), '*': {'greeting': 'Hi {name}', 'plain': 'Plain'}})
            keys, catalogs = l10n.load(Path(tmp))
        self.assertEqual(keys, ['greeting', 'plain'])
        self.assertEqual(catalogs['ja']['greeting'], 'Hi {name}')

    def test_rejects_missing_messages_and_placeholder_drift(self):
        cases = {
            'missing': {'greeting': 'Hi {name}'},
            'renamed placeholder': {'greeting': 'Hi {who}', 'plain': 'Plain'},
            'dropped placeholder': {'greeting': 'Hi', 'plain': 'Plain'},
            'stray brace': {'greeting': 'Hi {name} }', 'plain': 'Plain'},
            'empty': {'greeting': 'Hi {name}', 'plain': ' '},
            'unknown key': {'greeting': 'Hi {name}', 'plain': 'Plain', 'extra': 'x'},
        }
        for name, other in cases.items():
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                self._write(Path(tmp), {'zh_TW': self._template(), '*': other})
                with self.assertRaises(l10n.CatalogError):
                    l10n.load(Path(tmp))

    def test_rejects_placeholders_that_are_not_parameter_names(self):
        for name in ('class', 'language', 'this'):
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                template = {'note': f'值 {{{name}}}', '@note': {'placeholders': {name: {}}}}
                self._write(Path(tmp), {'zh_TW': template, '*': {'note': f'Value {{{name}}}'}})
                with self.assertRaises(l10n.CatalogError):
                    l10n.load(Path(tmp))

    def test_rejects_a_key_given_twice(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._write(Path(tmp), {'zh_TW': self._template(), '*': {'greeting': 'Hi {name}', 'plain': 'Plain'}})
            path = Path(tmp) / 'app_ja.arb'
            path.write_text(path.read_text(encoding='utf-8').replace('"plain": "Plain"', '"plain": "Plain", "plain": "Again"'),
                            encoding='utf-8')
            with self.assertRaises(l10n.CatalogError):
                l10n.load(Path(tmp))

    def test_rejects_keys_that_are_not_dart_identifiers(self):
        for key in ('Upper', 'with-dash', 'class', 'language'):
            with self.subTest(key), tempfile.TemporaryDirectory() as tmp:
                self._write(Path(tmp), {'zh_TW': {key: '文字'}, '*': {key: 'Text'}})
                with self.assertRaises(l10n.CatalogError):
                    l10n.load(Path(tmp))

    def test_rendered_dart_escapes_quotes_dollars_and_newlines(self):
        keys = ['note']
        catalogs = {tag: {'note': "它's $5\n下一行\r"} for tag, *_ in l10n.LANGUAGES}
        files = l10n.render(keys, catalogs)
        self.assertIn("'它\\'s \\$5\\n下一行\\r'", files['strings_zh_TW.g.dart'])
        self.assertNotIn('\r', files['strings.g.dart'], 'a carriage return would end the doc comment')
        self.assertIn('String get note =>', files['strings.g.dart'])

    def test_only_right_to_left_languages_are_marked_rtl(self):
        # Their messages isolate placeholder values, so a GitLab name or
        # reference keeps its own direction inside Arabic text.
        files = l10n.render(['note'], {tag: {'note': '{name}'} for tag, *_ in l10n.LANGUAGES})
        generated = files['strings.g.dart']
        for tag, _, _, language, *_ in l10n.LANGUAGES:
            with self.subTest(tag):
                entry = re.search(rf"AppLanguage\._\('{re.escape(tag)}', .*, (true|false), _messages", generated)
                self.assertIsNotNone(entry)
                self.assertEqual(entry.group(1), 'true' if language == 'ar' else 'false')
        self.assertIn('String note(Object? name) => _format(language, ', generated)


if __name__ == '__main__':
    unittest.main()
