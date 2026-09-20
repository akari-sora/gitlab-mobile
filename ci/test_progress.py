#!/usr/bin/env python3
"""Compact progress with bounded assertion context; unit fixtures contain no live secrets."""
import json
import sys
from collections import defaultdict, deque

names = {}
messages = defaultdict(lambda: deque(maxlen=8))
for line in sys.stdin:
    try:
        value = json.loads(line)
    except json.JSONDecodeError:
        continue
    for event in value if isinstance(value, list) else [value]:
        if not isinstance(event, dict):
            continue
        kind = event.get('type')
        test_id = event.get('testID')
        if kind == 'testStart':
            test = event.get('test', {})
            names[test.get('id')] = test.get('name', 'unknown test')
            print('START', names[test.get('id')], flush=True)
        elif kind == 'print':
            messages[test_id].append(str(event.get('message', ''))[:12000])
        elif kind == 'testDone':
            print(event.get('result', 'incomplete').upper(), names.get(test_id, test_id), flush=True)
            messages.pop(test_id, None)
        elif kind == 'error':
            print('ERROR', event.get('error', ''), flush=True)
            for message in messages.pop(test_id, ()):
                print('ASSERTION CONTEXT:', message, flush=True)
            trace = str(event.get('stackTrace', ''))
            if trace:
                print(trace[:12000], flush=True)
        elif kind == 'done':
            print('RUN COMPLETE:', event.get('success'), flush=True)
