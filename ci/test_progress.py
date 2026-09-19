#!/usr/bin/env python3
"""Print compact live test progress while retaining raw JSON as an artifact."""
import json
import sys
names = {}
for line in sys.stdin:
    try:
        value = json.loads(line)
    except json.JSONDecodeError:
        continue
    for event in value if isinstance(value, list) else [value]:
        if not isinstance(event, dict):
            continue
        kind = event.get('type')
        if kind == 'testStart':
            test = event.get('test', {})
            names[test.get('id')] = test.get('name', 'unknown test')
            print('START', names[test.get('id')], flush=True)
        elif kind == 'testDone':
            print(event.get('result', 'incomplete').upper(), names.get(event.get('testID'), event.get('testID')), flush=True)
        elif kind == 'error':
            print('ERROR', event.get('error', ''), flush=True)
        elif kind == 'done':
            print('RUN COMPLETE:', event.get('success'), flush=True)
