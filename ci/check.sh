#!/usr/bin/env bash
set -euo pipefail
mode="${1:-default}"
list_only=false
if [ "$#" -eq 2 ] && [ "$2" = --list-tests ]; then
  list_only=true
elif [ "$#" -gt 1 ]; then
  echo 'Usage: ci/check.sh [default|ai] [--list-tests]' >&2
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
  *) echo 'Usage: ci/check.sh [default|ai] [--list-tests]' >&2; exit 2 ;;
esac
# flutter test gets an explicit list: every *_test.dart under test/, as it would
# find on its own, except that the MR7 sandbox tool tests
# (test/ai/mr7_sandbox_*_test.dart and any test/ai/mr7_live_*_test.dart) run
# only in the ai lane. They exercise the host sandbox runner in tool/mr7/, not
# the app's AI gate. The gate tests (mr7_release_gate_test.dart,
# mr7_background_gate_test.dart) run in both lanes. See docs/CI.md "Test lanes".
# --list-tests prints the selection and stops before Flutter is touched.
test_files=()
found=0
while IFS= read -r file; do
  found=$((found + 1))
  case "$file" in
    test/ai/*/*) ;; # deeper paths are not sandbox tool tests
    test/ai/mr7_sandbox_*_test.dart | test/ai/mr7_live_*_test.dart)
      [ "$mode" = ai ] || continue ;;
  esac
  test_files+=("$file")
done < <(find test -name '*_test.dart' -type f | LC_ALL=C sort)
if [ "${#test_files[@]}" -eq 0 ]; then
  echo 'ci/check.sh: no test files found under test/' >&2
  exit 1
fi
echo "ci/check.sh: $mode lane runs ${#test_files[@]} of $found test files" >&2
if [ "$list_only" = true ]; then
  printf '%s\n' "${test_files[@]}"
  exit 0
fi
mkdir -p "$output_dir" "$coverage_dir"
if [ "${CI:-false}" = true ]; then
  python3 ci/install_packages.py fonts-noto-cjk
fi
flutter pub get --enforce-lockfile
cp pubspec.lock "$output_dir/pubspec.lock"
set +e
flutter analyze --no-pub 2>&1 | tee "$output_dir/analyze.txt"
analysis_status=${PIPESTATUS[0]}
timeout --signal=TERM --kill-after=15s 22m flutter test --no-pub --coverage --timeout=60s --machine ${test_options[@]+"${test_options[@]}"} "${test_files[@]}" 2>"$output_dir/test-stderr.txt" | tee "$output_dir/tests.jsonl" | python3 -u ci/test_progress.py
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
