#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: verify-artifacts.sh YTKACE.dylib [YTKACE_YouTube.ipa]" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DYLIB="$1"
test -f "$DYLIB"

if command -v lipo >/dev/null 2>&1; then
  INFO="$(lipo -info "$DYLIB")"
elif command -v llvm-lipo >/dev/null 2>&1; then
  INFO="$(llvm-lipo -info "$DYLIB")"
else
  INFO=""
fi

if [[ -n "$INFO" ]]; then
  [[ "$INFO" == *arm64* ]]
fi

if command -v otool >/dev/null 2>&1; then
  DEPS="$(otool -L "$DYLIB")"
  [[ "$DEPS" != *CydiaSubstrate* ]]
  [[ "$DEPS" != *MobileSubstrate* ]]
fi

if [[ $# -eq 2 ]]; then
  IPA="$2"
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  unzip -q "$IPA" -d "$WORK"
  APP="$(find "$WORK/Payload" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print -quit)"
  test -n "$APP"
  test ! -e "$APP/Frameworks/CydiaSubstrate.framework"
  test -f "$APP/Frameworks/YTKACE.dylib"

  EXECUTABLE="$(
    python3 - "$APP/Info.plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], "rb") as handle:
    print(plistlib.load(handle)["CFBundleExecutable"])
PY
  )"
  LOADS="$(python3 "$ROOT/Tools/macho_inject.py" "$APP/$EXECUTABLE" --list)"
  [[ "$LOADS" == *'@rpath/YTKACE.dylib'* ]]
  python3 - "$APP" <<'PY'
import json
import pathlib
import plistlib
import sys

app = pathlib.Path(sys.argv[1])
info = plistlib.loads((app / 'Info.plist').read_bytes())
schemes = [scheme for entry in info.get('CFBundleURLTypes', [])
           for scheme in entry.get('CFBundleURLSchemes', [])]
assert 'youtube' in schemes, 'YouTube URL handler missing'
for name, point in [('YTKACEOpenSafari', 'com.apple.Safari.web-extension'),
                    ('YTKACEOpenShare', 'com.apple.share-services')]:
    extension = app / 'PlugIns' / (name + '.appex')
    metadata = plistlib.loads((extension / 'Info.plist').read_bytes())
    assert metadata['CFBundleIdentifier'] == info['CFBundleIdentifier'] + '.' + name
    assert metadata['CFBundleVersion'] == info['CFBundleVersion']
    assert metadata['CFBundleShortVersionString'] == info['CFBundleShortVersionString']
    assert metadata['NSExtension']['NSExtensionPointIdentifier'] == point
    assert (extension / metadata['CFBundleExecutable']).is_file()
safari = app / 'PlugIns' / 'YTKACEOpenSafari.appex'
manifest = json.loads((safari / 'manifest.json').read_text())
assert (safari / manifest['browser_action']['default_popup']).is_file()
for content in manifest['content_scripts']:
    for script in content['js']:
        assert (safari / script).is_file()
print('Safari and share extensions verified')
PY
fi

echo "verified"
