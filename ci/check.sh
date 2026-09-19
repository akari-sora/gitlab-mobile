#!/usr/bin/env bash
set -euo pipefail
mkdir -p ci-output
flutter pub get
cp pubspec.lock ci-output/pubspec.lock
set +e
flutter analyze --no-pub > ci-output/analyze.txt 2>&1
analysis_status=$?
flutter test --no-pub --coverage --machine > ci-output/tests.jsonl 2>ci-output/test-stderr.txt
test_status=$?
set -e
cat ci-output/analyze.txt
cat ci-output/test-stderr.txt
python3 ci/test_report.py ci-output/tests.jsonl ci-output/junit.xml
printf 'analysis_exit=%s\ntest_exit=%s\n' "$analysis_status" "$test_status" | tee ci-output/check-status.txt
# Generate reviewable suggestions separately, AFTER testing the exact checkout.
# These changes are NOT counted as tested, nor are they published automatically.
dart fix --apply > ci-output/suggested-fixes.txt 2>&1 || true
dart format lib test > ci-output/suggested-format.txt 2>&1 || true
git diff -- lib test > ci-output/suggested.patch
if [ "$analysis_status" -ne 0 ] || [ "$test_status" -ne 0 ]; then
  exit 1
fi
