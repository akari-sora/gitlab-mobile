#!/usr/bin/env python3
"""Convert Flutter JSON events to JUnit, preserving failures and incomplete runs."""
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET


def events(source: Path):
    for line in source.read_text(encoding='utf-8').splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        for event in value if isinstance(value, list) else [value]:
            if isinstance(event, dict) and isinstance(event.get('type'), str):
                yield event


def convert(source: Path, destination: Path) -> None:
    tests, suites, errors = {}, {}, {}
    done = None
    for event in events(source):
        kind = event['type']
        if kind == 'suite':
            suites[event['suite']['id']] = event['suite'].get('path', 'flutter')
        elif kind == 'testStart':
            test = event['test']
            tests[test['id']] = dict(test, started=event.get('time', 0))
        elif kind == 'error':
            errors.setdefault(event.get('testID'), []).append(str(event.get('error', '')) + '\n' + str(event.get('stackTrace', '')))
        elif kind == 'testDone':
            item = tests.get(event['testID'])
            if item is not None:
                item.update(result=event.get('result'), skipped=event.get('skipped', False), hidden=event.get('hidden', False), ended=event.get('time', 0))
        elif kind == 'done':
            done = event
    root = ET.Element('testsuites')
    suite = ET.SubElement(root, 'testsuite', name='Flutter tests')
    failures = skipped = count = 0
    for ident, item in tests.items():
        if item.get('hidden', False) and item.get('result') == 'success':
            continue
        count += 1
        case = ET.SubElement(suite, 'testcase', name=item.get('name', str(ident)),
            classname=suites.get(item.get('suiteID'), 'flutter'),
            time=str(max(0, item.get('ended', item['started']) - item['started']) / 1000))
        if item.get('skipped'):
            skipped += 1
            ET.SubElement(case, 'skipped')
        elif item.get('result') != 'success':
            failures += 1
            message = '\n'.join(errors.get(ident, ['Test did not complete successfully.']))
            ET.SubElement(case, 'failure', message=str(item.get('result', 'incomplete'))).text = message
            print('FAILED:', item.get('name', str(ident)))
            print(message)
    if done is None or count == 0 or (done.get('success') is False and failures == 0):
        count += 1
        failures += 1
        case = ET.SubElement(suite, 'testcase', name='test protocol completion', classname='ci')
        ET.SubElement(case, 'failure', message='Incomplete or unsuccessful test run')
    suite.set('tests', str(count))
    suite.set('failures', str(failures))
    suite.set('skipped', str(skipped))
    destination.parent.mkdir(parents=True, exist_ok=True)
    ET.indent(root)
    ET.ElementTree(root).write(destination, encoding='utf-8', xml_declaration=True)
    print(f'JUnit: {count} tests, {failures} failures, {skipped} skipped')


if __name__ == '__main__':
    convert(Path(sys.argv[1]), Path(sys.argv[2]))
