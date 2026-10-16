#!/bin/bash
# Builds not-loom.app into mac/build/.
#   ./scripts/build-app.sh            build only (also makes build/not-loom.zip)
#   ./scripts/build-app.sh --install  build, copy to /Applications and launch
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/NotLoom"
APP="build/not-loom.app"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' Resources/Info.plist)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NotLoom"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# --- Signing ---------------------------------------------------------------
# macOS ties the screen recording, camera and mic permissions to the app's
# signature. Signing every build with the same certificate keeps them; an
# ad-hoc signature changes on every build, so macOS forgets them.
#
# Order of preference: $SIGN_IDENTITY, an "Apple Development" certificate,
# then a local self-signed certificate this script creates once.
LOCAL_CERT="not-loom Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

identity_named() {
  security find-identity -p codesigning 2>/dev/null | awk -F'"' -v name="$1" 'index($2, name) == 1 {print $2; exit}' || true
}

create_local_cert() {
  echo
  echo "Creating a code-signing certificate, \"$LOCAL_CERT\", in your login keychain."
  echo "This happens once, so macOS remembers not-loom's permissions across rebuilds."
  local tmp
  tmp="$(mktemp -d)"
  cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $LOCAL_CERT
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -out "$tmp/cert.p12" -passout pass:not-loom
  security import "$tmp/cert.p12" -k "$KEYCHAIN" -P not-loom -T /usr/bin/codesign >/dev/null
  echo "macOS will now ask for your password to trust it for code signing."
  security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$tmp/cert.pem" \
    || echo "Couldn't mark it as trusted; signing may still work."
  rm -rf "$tmp"

  # Permissions granted to earlier builds belong to their old signatures.
  # Clear them so macOS asks once more, for the last time.
  tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1 || true
  echo "Done. Allow screen recording, camera and mic once more when not-loom asks."
  echo
}

IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then IDENTITY="$(identity_named "Apple Development")"; fi
if [[ -z "$IDENTITY" && -z "${CI:-}" ]]; then
  IDENTITY="$(identity_named "$LOCAL_CERT")"
  if [[ -z "$IDENTITY" ]]; then
    create_local_cert
    IDENTITY="$(identity_named "$LOCAL_CERT")"
  fi
fi

if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "Signed with: $IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "Signed ad hoc (permissions won't survive a rebuild)"
fi

# --- Install -----------------------------------------------------------------
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
