#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="EZCompleteUI"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$ROOT_DIR/.cache}"
export THEOS_PACKAGE_SCHEME="rootless"
export THEOS_STAGING_DIR="${THEOS_STAGING_DIR:-$ROOT_DIR/.theos/_}"

fail() { echo "ERROR: $*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }

info "Preflight: host tools, Theos and SDK"
command -v make >/dev/null || fail "make is required"
command -v python3 >/dev/null || fail "python3 is required"
command -v zip >/dev/null || fail "zip is required to produce the IPA"
command -v dpkg-deb >/dev/null || fail "dpkg-deb is required to inspect the package"
[ -n "${THEOS:-}" ] || fail "THEOS is not set. Install Theos and export THEOS=/path/to/theos."
[ -d "$THEOS" ] || fail "THEOS does not point to a directory: $THEOS"
[ -d "${THEOS_SDKS_PATH:-$THEOS/sdks}" ] || fail "iPhoneOS SDK directory not found at ${THEOS_SDKS_PATH:-$THEOS/sdks}"
SDK_COUNT=$(find "${THEOS_SDKS_PATH:-$THEOS/sdks}" -maxdepth 1 -type d -name 'iPhoneOS*.sdk' | wc -l | tr -d ' ')
[ "$SDK_COUNT" -gt 0 ] || fail "No iPhoneOS*.sdk found under ${THEOS_SDKS_PATH:-$THEOS/sdks}"
printf '  THEOS: %s\n  SDKs:  %s iPhoneOS SDK(s)\n  stage: %s\n' "$THEOS" "$SDK_COUNT" "$THEOS_STAGING_DIR"

info "Preflight: redesign source tree"
python3 scripts/validate_redesign.py --strict || fail "source preflight failed; recover the missing implementation files before packaging"

info "Clean and package rootless app"
make clean
make package FINALPACKAGE=1 DEBUG=0 debug=0

info "Locate the actual Theos staged app"
STAGED_APP=""
while IFS= read -r plist; do
    candidate="${plist%/Info.plist}"
    if [ "$(basename "$candidate")" = "${APP_NAME}.app" ] && [ -x "$candidate/${APP_NAME}" ]; then
        STAGED_APP="$candidate"
        break
    fi
done < <(find "$THEOS_STAGING_DIR" -type f -path "*/Applications/${APP_NAME}.app/Info.plist" -print 2>/dev/null)
[ -n "$STAGED_APP" ] || fail "Theos produced no staged ${APP_NAME}.app under $THEOS_STAGING_DIR"
case "$STAGED_APP" in
  *"/var/jb/Applications/${APP_NAME}.app") ;;
  *) fail "staged app is not rootless (/var/jb/Applications): $STAGED_APP";;
esac
printf '  staged app: %s\n' "$STAGED_APP"

INFO_PLIST="$STAGED_APP/Info.plist"
python3 - "$INFO_PLIST" <<'PY'
import plistlib, sys
p = sys.argv[1]
d = plistlib.loads(open(p, 'rb').read())
for key in ('CFBundleIdentifier', 'CFBundleExecutable', 'CFBundleVersion'):
    if not d.get(key):
        raise SystemExit(f'ERROR: staged Info.plist missing {key}')
print(f"  bundle: {d['CFBundleIdentifier']} v{d['CFBundleVersion']}")
PY

info "Build IPA from the staged app (no re-signing or post-sign plist patching)"
rm -rf Payload
mkdir -p Payload
cp -R "$STAGED_APP" "Payload/${APP_NAME}.app"
rm -f "${APP_NAME}.ipa"
(
  cd Payload
  zip -r9 "../${APP_NAME}.ipa" "${APP_NAME}.app" >/dev/null
)
rm -rf Payload
unzip -Z1 "${APP_NAME}.ipa" | grep -qx "Payload/${APP_NAME}.app/Info.plist" || fail "IPA does not contain the staged app Info.plist"
printf '  IPA: %s (%s bytes)\n' "${APP_NAME}.ipa" "$(wc -c < "${APP_NAME}.ipa" | tr -d ' ')"

info "Validate final Debian package"
DEB="$(python3 - <<'PY2'
from pathlib import Path

packages = list(Path('packages').glob('*.deb'))
if not packages:
    raise SystemExit(0)
print(max(packages, key=lambda path: path.stat().st_mtime))
PY2
)"
[ -n "$DEB" ] || fail "make package did not produce a .deb in packages/"
dpkg-deb --info "$DEB" | grep -Eq '^ Package:|^ Version:|^ Architecture:' || fail "invalid Debian control metadata"
printf '  DEB: %s (%s bytes)\n' "$DEB" "$(wc -c < "$DEB" | tr -d ' ')"

info "Build complete"
printf '  Output IPA: %s\n  Output DEB: %s\n' "$ROOT_DIR/${APP_NAME}.ipa" "$ROOT_DIR/$DEB"
