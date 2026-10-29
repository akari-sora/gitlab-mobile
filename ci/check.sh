#!/usr/bin/env bash
set -euo pipefail
mode="${1:-default}"
if [ "$#" -gt 1 ]; then
  echo 'Usage: ci/check.sh [default|ai]' >&2
  exit 2
fi
output_dir=ci-output
coverage_dir=coverage
test_options=()
case "$mode" in
  default) ;;
  ai)
    output_dir=ci-output-ai
    coverage_dir=coverage-ai
    test_options=(--dart-define=MERGELINE_AI_ASSISTANT=true
      --dart-define=MERGELINE_AI_BACKGROUND=false --coverage-path=coverage-ai/lcov.info)
    ;;
  *) echo 'Usage: ci/check.sh [default|ai]' >&2; exit 2 ;;
esac
mkdir -p "$output_dir" "$coverage_dir"
if [ "${CI:-false}" = true ]; then
  python3 ci/install_packages.py fonts-noto-cjk
fi
flutter pub get --enforce-lockfile
cp pubspec.lock "$output_dir/pubspec.lock"
set +e
flutter analyze --no-pub 2>&1 | tee "$output_dir/analyze.txt"
analysis_status=${PIPESTATUS[0]}
timeout --signal=TERM --kill-after=15s 36m flutter test --no-pub --coverage --timeout=60s --machine ${test_options[@]+"${test_options[@]}"} 2>"$output_dir/test-stderr.txt" | tee "$output_dir/tests.jsonl" | python3 -u ci/test_progress.py
test_status=${PIPESTATUS[0]}
cat "$output_dir/test-stderr.txt"
python3 ci/test_report.py "$output_dir/tests.jsonl" "$output_dir/junit.xml"
report_status=$?
set -e
printf 'analysis_exit=%s\ntest_exit=%s\nreport_exit=%s\n' "$analysis_status" "$test_status" "$report_status" | tee "$output_dir/check-status.txt"
if [ -f "$coverage_dir/lcov.info" ]; then
  python3 - "$coverage_dir/lcov.info" <<'PY'
from pathlib import Path
import sys
lines = Path(sys.argv[1]).read_text().splitlines()
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
# The visual fixture writes to ci-output independently of the check mode.
if [ "$mode" = ai ]; then
  for evidence in screenshots projects-light-preview.png ui-preview-base64.txt; do
    if [ -e "ci-output/$evidence" ]; then
      cp -R "ci-output/$evidence" "$output_dir/"
    fi
  done
fi
if [ "$analysis_status" -ne 0 ] || [ "$test_status" -ne 0 ] || [ "$report_status" -ne 0 ]; then
  exit 1
fi
