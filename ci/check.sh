#!/usr/bin/env bash
set -euo pipefail
mkdir -p ci-output
if [ "${CI:-false}" = true ]; then
  python3 ci/install_packages.py fonts-noto-cjk
fi
flutter pub get --enforce-lockfile
cp pubspec.lock ci-output/pubspec.lock
set +e
flutter analyze --no-pub 2>&1 | tee ci-output/analyze.txt
analysis_status=${PIPESTATUS[0]}
timeout --signal=TERM --kill-after=15s 22m flutter test --no-pub --coverage --timeout=60s --machine 2>ci-output/test-stderr.txt | tee ci-output/tests.jsonl | python3 -u ci/test_progress.py
test_status=${PIPESTATUS[0]}
cat ci-output/test-stderr.txt
python3 ci/test_report.py ci-output/tests.jsonl ci-output/junit.xml
report_status=$?
set -e
printf 'analysis_exit=%s\ntest_exit=%s\nreport_exit=%s\n' "$analysis_status" "$test_status" "$report_status" | tee ci-output/check-status.txt
if [ -f coverage/lcov.info ]; then
  python3 - <<'PY'
from pathlib import Path
lines = Path('coverage/lcov.info').read_text().splitlines()
found = sum(int(line[3:]) for line in lines if line.startswith('LF:'))
hit = sum(int(line[3:]) for line in lines if line.startswith('LH:'))
print(f'Coverage: {100 * hit / found:.2f}%' if found else 'Coverage: unavailable')
PY
fi
if [ -f ci-output/screenshots/projects-light.png ]; then
  python3 -m pip install --quiet 'Pillow==11.3.0'
  python3 ci/ui_evidence.py
fi
if [ -f ci-output/ui-preview-base64.txt ]; then
  echo BEGIN_SYNTHETIC_FLUTTER_UI_PNG
  cat ci-output/ui-preview-base64.txt
  echo
  echo END_SYNTHETIC_FLUTTER_UI_PNG
fi
if [ "$analysis_status" -ne 0 ] || [ "$test_status" -ne 0 ] || [ "$report_status" -ne 0 ]; then
  exit 1
fi
