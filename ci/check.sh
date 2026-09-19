#!/usr/bin/env bash
set -euo pipefail
mkdir -p ci-output
if git ls-files --error-unmatch pubspec.lock >/dev/null 2>&1; then
  flutter pub get --enforce-lockfile
else
  flutter pub get
  echo 'BEGIN_RESOLVED_PUBSPEC_LOCK'
  cat pubspec.lock
  echo 'END_RESOLVED_PUBSPEC_LOCK'
fi
cp pubspec.lock ci-output/pubspec.lock
set +e
flutter analyze --no-pub 2>&1 | tee ci-output/analyze.txt
analysis_status=${PIPESTATUS[0]}
timeout --signal=TERM --kill-after=15s 8m flutter test --no-pub --coverage --timeout=60s --machine 2>ci-output/test-stderr.txt | tee ci-output/tests.jsonl | python3 -u ci/test_progress.py
test_status=${PIPESTATUS[0]}
set -e
cat ci-output/test-stderr.txt
python3 ci/test_report.py ci-output/tests.jsonl ci-output/junit.xml
printf 'analysis_exit=%s\ntest_exit=%s\n' "$analysis_status" "$test_status" | tee ci-output/check-status.txt
if [ -f coverage/lcov.info ]; then
  python3 - <<'PY'
from pathlib import Path
lines = Path('coverage/lcov.info').read_text().splitlines()
found = sum(int(line[3:]) for line in lines if line.startswith('LF:'))
hit = sum(int(line[3:]) for line in lines if line.startswith('LH:'))
print(f'Coverage: {100 * hit / found:.2f}%' if found else 'Coverage: unavailable')
PY
fi
if [ "$analysis_status" -ne 0 ] || [ "$test_status" -ne 0 ]; then
  exit 1
fi
