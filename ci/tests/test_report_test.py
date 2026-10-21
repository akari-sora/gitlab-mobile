import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

SPEC = importlib.util.spec_from_file_location('report', Path(__file__).resolve().parents[1] / 'test_report.py')
report = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(report)


class ReportTests(unittest.TestCase):
    def convert(self, events):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'events.jsonl'
            output = Path(folder) / 'junit.xml'
            source.write_text('\n'.join(json.dumps(event) for event in events))
            with contextlib.redirect_stdout(io.StringIO()):
                failures = report.convert(source, output)
            return failures, ET.parse(output).getroot().find('testsuite')

    def case(self, result='success', **extra):
        return [
            {'type': 'suite', 'suite': {'id': 1, 'path': 'test/example.dart'}},
            {'type': 'testStart', 'test': {'id': 7, 'name': 'an actual test', 'suiteID': 1}, 'time': 0},
            {'type': 'testDone', 'testID': 7, 'result': result, 'time': 100, **extra},
        ]

    def test_success(self):
        failures, suite = self.convert(self.case() + [{'type': 'done', 'success': True}])
        self.assertEqual(failures, 0)
        self.assertEqual(suite.get('tests'), '1')
        self.assertEqual(suite.find('testcase').get('time'), '0.1')

    def test_non_event_json_and_arrays(self):
        values = [None, 42, 'native-hook-output', [{'foo': 'bar'}], self.case(), {'type': 'done', 'success': True}]
        self.assertEqual(self.convert(values)[0], 0)

    def test_failure_retains_message(self):
        values = self.case('failure') + [
            {'type': 'error', 'testID': 7, 'error': 'expected true < false', 'stackTrace': 'example:3'},
            {'type': 'done', 'success': False},
        ]
        failures, suite = self.convert(values)
        self.assertEqual(failures, 1)
        self.assertIn('expected true < false', suite.find('testcase/failure').text)

    def test_characters_xml_forbids_are_escaped(self):
        # A test named after an HTML fragment with a form feed, and an error
        # with terminal colours, must still give a report GitLab can parse.
        values = [
            {'type': 'suite', 'suite': {'id': 1, 'path': 'test/example.dart'}},
            {'type': 'testStart', 'test': {'id': 7, 'name': 'tag <img\x0csrc=x>', 'suiteID': 1}, 'time': 0},
            {'type': 'error', 'testID': 7, 'error': '\x1b[31mred\x1b[0m \x00', 'stackTrace': ''},
            {'type': 'testDone', 'testID': 7, 'result': 'failure', 'time': 1},
            {'type': 'done', 'success': False},
        ]
        failures, suite = self.convert(values)
        self.assertEqual(failures, 1)
        case = suite.find('testcase')
        self.assertEqual(case.get('name'), 'tag <img\\x0csrc=x>')
        self.assertIn('\\x1b[31mred', case.find('failure').text)
        self.assertIn('\\x00', case.find('failure').text)

    def test_every_forbidden_character_is_escaped_and_allowed_ones_kept(self):
        # A list: adjacent surrogate escapes in one literal would pair up.
        forbidden = ['\x00', '\x08', '\x0b', '\x0c', '\x0e', '\x1f', '\ud800', '\udfff', '\ufffe', '\uffff']
        for char in forbidden:
            escape = f'\\x{ord(char):02x}' if ord(char) < 0x100 else f'\\u{ord(char):04x}'
            with self.subTest(code=hex(ord(char))):
                self.assertEqual(report.xml_text(f'a{char}b'), f'a{escape}b')
        allowed = 'tab\tline\ncr\r\x7f\ud7ff\ue000\ufffd\U0010ffff'
        self.assertEqual(report.xml_text(allowed), allowed)

    def test_classname_and_failure_message_are_escaped(self):
        values = [
            {'type': 'suite', 'suite': {'id': 1, 'path': 'test/a\x0bb.dart'}},
            {'type': 'testStart', 'test': {'id': 7, 'name': 'plain', 'suiteID': 1}, 'time': 0},
            {'type': 'testDone', 'testID': 7, 'result': 'fail\x0bure', 'time': 1},
            {'type': 'done', 'success': False},
        ]
        _, suite = self.convert(values)
        case = suite.find('testcase')
        self.assertEqual(case.get('classname'), 'test/a\\x0bb.dart')
        self.assertEqual(case.find('failure').get('message'), 'fail\\x0bure')

    def test_names_that_escape_alike_stay_distinct(self):
        values = [{'type': 'suite', 'suite': {'id': 1, 'path': 'test/example.dart'}}]
        for ident, name in [(1, 'tag <img\x0csrc=x>'), (2, 'tag <img\\x0csrc=x>'), (3, 'same'), (4, 'same')]:
            values += [
                {'type': 'testStart', 'test': {'id': ident, 'name': name, 'suiteID': 1}, 'time': 0},
                {'type': 'testDone', 'testID': ident, 'result': 'success', 'time': 1},
            ]
        values.append({'type': 'done', 'success': True})
        _, suite = self.convert(values)
        names = [case.get('name') for case in suite.findall('testcase')]
        self.assertEqual(names, ['tag <img\\x0csrc=x>', 'tag <img\\x0csrc=x> (2)', 'same', 'same (2)'])

    def test_a_numbered_name_already_taken_is_skipped(self):
        values = [{'type': 'suite', 'suite': {'id': 1, 'path': 'test/a.dart'}},
                  {'type': 'suite', 'suite': {'id': 2, 'path': 'test/b.dart'}}]
        for ident, name, suite_id in [(1, 'foo (2)', 1), (2, 'foo', 1), (3, 'foo', 1), (4, 'foo', 2)]:
            values += [
                {'type': 'testStart', 'test': {'id': ident, 'name': name, 'suiteID': suite_id}, 'time': 0},
                {'type': 'testDone', 'testID': ident, 'result': 'success', 'time': 1},
            ]
        values.append({'type': 'done', 'success': True})
        _, suite = self.convert(values)
        cases = [(case.get('classname'), case.get('name')) for case in suite.findall('testcase')]
        self.assertEqual(cases, [('test/a.dart', 'foo (2)'), ('test/a.dart', 'foo'),
                                 ('test/a.dart', 'foo (3)'), ('test/b.dart', 'foo')])

    def test_a_failing_lone_surrogate_still_writes_the_report(self):
        # The CI image prints in UTF-8, which cannot encode a lone surrogate.
        events = self.case('failure') + [
            {'type': 'error', 'testID': 7, 'error': 'Expected: \ud83d', 'stackTrace': ''},
            {'type': 'done', 'success': False},
        ]
        script = Path(__file__).resolve().parents[1] / 'test_report.py'
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'events.jsonl'
            output = Path(folder) / 'junit.xml'
            source.write_text('\n'.join(json.dumps(event) for event in events))
            env = dict(os.environ, LC_ALL='C.UTF-8', PYTHONIOENCODING='utf-8')
            run = subprocess.run([sys.executable, str(script), str(source), str(output)],
                                 capture_output=True, env=env)
            self.assertEqual(run.returncode, 1, run.stderr.decode(errors='replace'))
            failure = ET.parse(output).getroot().find('testsuite/testcase/failure')
            self.assertIn('Expected: \\ud83d', failure.text)

    def test_missing_done_is_not_success(self):
        self.assertGreater(self.convert(self.case())[0], 0)

    def test_zero_tests_is_not_success(self):
        self.assertGreater(self.convert([{'type': 'done', 'success': True}])[0], 0)

    def test_overall_failure_is_not_lost(self):
        self.assertGreater(self.convert(self.case() + [{'type': 'done', 'success': False}])[0], 0)

    def test_skipped_test_is_not_counted_as_pass(self):
        failures, suite = self.convert(self.case(skipped=True) + [{'type': 'done', 'success': True}])
        self.assertEqual(failures, 0)
        self.assertEqual(suite.get('skipped'), '1')

    def test_hidden_success_loader_is_not_a_test(self):
        values = self.case(hidden=True)
        values += [{'type': 'testStart', 'test': {'id': 8, 'name': 'real test', 'suiteID': 1}},
                   {'type': 'testDone', 'testID': 8, 'result': 'success'}, {'type': 'done', 'success': True}]
        failures, suite = self.convert(values)
        self.assertEqual(failures, 0)
        self.assertEqual(suite.get('tests'), '1')

    def test_unfinished_test_is_failure(self):
        self.assertGreater(self.convert(self.case()[:2] + [{'type': 'done', 'success': False}])[0], 0)

    def test_error_cannot_be_overridden_by_success(self):
        values = self.case() + [{'type': 'error', 'testID': 7, 'error': 'late exception'}, {'type': 'done', 'success': True}]
        self.assertGreater(self.convert(values)[0], 0)


if __name__ == '__main__':
    unittest.main()
