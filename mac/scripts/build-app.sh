#!/bin/bash
# Builds not-loom.app into mac/build/.
#   ./scripts/build-app.sh            build only (also makes build/not-loom.zip)
#   ./scripts/build-app.sh --install  build, copy to /Applications and launch
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/NotLoom"
APP="build/not-loom.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NotLoom"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# macOS ties the Screen Recording permission to the app's signature. Signing with an
# "Apple Development" certificate (free with Xcode + an Apple ID) keeps the permission
# across rebuilds. Ad-hoc signing, the fallback, means re-allowing it after each rebuild.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}' || true)}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc signature}"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x NotLoom 2>/dev/null || true
  rm -rf "/Applications/not-loom.app"
  cp -R "$APP" /Applications/
  echo "Installed /Applications/not-loom.app"
  open "/Applications/not-loom.app"
else
  rm -f build/not-loom.zip
  (cd build && ditto -c -k --keepParent not-loom.app not-loom.zip)
  echo "Built $APP"
fi
