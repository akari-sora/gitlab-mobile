#!/usr/bin/env bash
set -euo pipefail
: "${FLUTTER_HOME:?Source ci/install_flutter.sh first}"
ROOT="${CI_PROJECT_DIR:-$(pwd)}"
export ANDROID_HOME="$ROOT/.android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
TOOLS_REVISION=15859902
TOOLS_SHA256=4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583
TOOLS_HOME="$ANDROID_HOME/cmdline-tools/$TOOLS_REVISION"
if [ ! -x "$TOOLS_HOME/bin/sdkmanager" ]; then
  python3 "$ROOT/ci/install_android_tools.py" \
    --url "https://dl.google.com/android/repository/commandlinetools-linux-${TOOLS_REVISION}_latest.zip" \
    --sha256 "$TOOLS_SHA256" \
    --destination "$TOOLS_HOME" \
    --ipv4
fi
export PATH="$TOOLS_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"
export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
java -version
compile_sdk="$(python3 - <<'PY'
import os, pathlib, re
source = pathlib.Path(os.environ['FLUTTER_HOME']) / 'packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt'
text = source.read_text()
match = re.search(r'compileSdkVersion\s*:\s*Int\s*=\s*(\d+)', text)
if not match:
    raise SystemExit('Cannot determine pinned Flutter compileSdkVersion; review SDK template')
print(match.group(1))
PY
)"
printf 'Installing Android API %s for the pinned Flutter SDK\n' "$compile_sdk"
# sdkmanager exits after consuming its prompts; avoid treating yes's SIGPIPE as failure.
set +o pipefail
yes | sdkmanager --sdk_root="$ANDROID_HOME" --licenses > /tmp/gitlab-mobile-android-licenses.log
license_status=${PIPESTATUS[1]}
set -o pipefail
if [ "$license_status" -ne 0 ]; then
  cat /tmp/gitlab-mobile-android-licenses.log
  exit "$license_status"
fi
sdkmanager --sdk_root="$ANDROID_HOME" "platform-tools" "platforms;android-$compile_sdk" "build-tools;36.0.0"
flutter config --android-sdk "$ANDROID_HOME"
