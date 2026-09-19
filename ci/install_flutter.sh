#!/usr/bin/env bash
set -euo pipefail
ROOT="${CI_PROJECT_DIR:-$(pwd)}"
VERSION="$(python3 -c 'import json; print(json.load(open(".fvmrc"))["flutter"])')"
export FLUTTER_HOME="$ROOT/.ci-cache/flutter-$VERSION"
export PUB_CACHE="$ROOT/.pub-cache"
export PATH="$FLUTTER_HOME/bin:$PATH"
if [ ! -x "$FLUTTER_HOME/bin/flutter" ]; then
  mkdir -p "$ROOT/.ci-cache"
  git clone --depth 1 --branch "$VERSION" https://github.com/flutter/flutter.git "$FLUTTER_HOME"
fi
git config --global --add safe.directory "$FLUTTER_HOME"
flutter config --no-analytics
flutter --version --machine > /tmp/gitlab-mobile-flutter-version.json
python3 - "$VERSION" <<'PY'
import json, sys
with open('/tmp/gitlab-mobile-flutter-version.json') as stream:
    data = json.load(stream)
actual = data.get('frameworkVersion')
if actual != sys.argv[1]:
    raise SystemExit(f'Flutter version mismatch: expected {sys.argv[1]}, got {actual}')
print('Verified Flutter', actual, 'Dart', data.get('dartSdkVersion'))
PY
