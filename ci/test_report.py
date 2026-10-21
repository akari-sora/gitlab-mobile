#!/usr/bin/env python3
"""Convert actual Flutter JSON events to JUnit; incomplete runs fail closed."""
import json
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

# Characters XML 1.0 does not allow anywhere. A test named after an HTML
# fragment or an error with terminal colours would otherwise make the whole
# report unreadable to GitLab ("invalid character in attribute value").
_NOT_XML = re.compile('[\x00-\x08\x0b\x0c\x0e-\x1f\ud800-\udfff\ufffe\uffff]')


def xml_text(value: object) -> str:
    """[value] as text that XML can hold, with each forbidden character
    written as a visible escape (form feed becomes `\\x0c`)."""
    return _NOT_XML.sub(lambda match: f'\\x{ord(match.group()):02x}' if ord(match.group()) < 0x100
                        else f'\\u{ord(match.group()):04x}', str(value))


def events(source: Path):
    for line in source.read_text(encoding='utf-8').splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        for event in value if isinstance(value, list) else [value]:
            if isinstance(event, dict) and isinstance(event.get('type'), str):
                yield event


def convert(source: Path, destination: Path) -> int:
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
    # Escaping can make two names equal (a form feed and a literal "\x0c"),
    # and Dart can repeat a name. The first keeps its name; each later one
    # gets the lowest " (n)" that is still free, which stays stable across
    # runs as long as the order of the repeats does.
    seen = set()

    def distinct(classname, name):
        candidate, number = name, 1
        while (classname, candidate) in seen:
            number += 1
            candidate = f'{name} ({number})'
        seen.add((classname, candidate))
        return candidate

    for ident, item in tests.items():
        if item.get('hidden', False) and item.get('result') == 'success' and not errors.get(ident):
            continue
        count += 1
        classname = xml_text(suites.get(item.get('suiteID'), 'flutter'))
        name = distinct(classname, xml_text(item.get('name', str(ident))))
        case = ET.SubElement(suite, 'testcase', name=name,
            classname=classname,
            time=str(max(0, item.get('ended', item['started']) - item['started']) / 1000))
        if item.get('skipped') and not errors.get(ident):
            skipped += 1
            ET.SubElement(case, 'skipped')
        elif item.get('result') != 'success' or errors.get(ident):
            failures += 1
            message = '\n'.join(errors.get(ident, ['Test did not complete successfully.']))
            ET.SubElement(case, 'failure', message=xml_text(item.get('result', 'incomplete'))).text = xml_text(message)
            print('FAILED:', item.get('name', str(ident)))
            print(message)
    if done is None or count == 0 or (done.get('success') is not True and failures == 0):
        count += 1
        failures += 1
        case = ET.SubElement(suite, 'testcase', name=distinct('ci', 'test protocol completion'), classname='ci')
        ET.SubElement(case, 'failure', message='Incomplete or unsuccessful test run')
    suite.set('tests', str(count))
    suite.set('failures', str(failures))
    suite.set('skipped', str(skipped))
    destination.parent.mkdir(parents=True, exist_ok=True)
    ET.indent(root)
    ET.ElementTree(root).write(destination, encoding='utf-8', xml_declaration=True)
    print(f'JUnit: {count} tests, {failures} failures, {skipped} skipped')
    return failures


if __name__ == '__main__':
    # A failing test's name or message can hold a lone surrogate; printing it
    # must not abort the run before the report is written.
    sys.stdout.reconfigure(errors='backslashreplace')
    raise SystemExit(1 if convert(Path(sys.argv[1]), Path(sys.argv[2])) else 0)
