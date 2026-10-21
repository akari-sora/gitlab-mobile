import contextlib
import importlib.util
import io
import json
from pathlib import Path
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
