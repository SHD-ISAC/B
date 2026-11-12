#!/usr/bin/env bash
set -euo pipefail

app=build/macos/Build/Products/Release/Breeze.app
plist="$app/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")
binary=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$plist")

test "$(lipo -archs "$app/Contents/MacOS/$binary")" = arm64
codesign --verify --deep --strict --verbose=2 "$app"
codesign -dv --verbose=4 "$app" 2>&1 | grep -E '^CodeDirectory .*flags=.*runtime'

work=$(mktemp -d)
mkdir -p "$work/staging" "$work/mount" build-dmg
mounted=false
pid=

cleanup() {
  if [[ -n "$pid" ]]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  if [[ "$mounted" == true ]]; then
    hdiutil detach "$work/mount" || return
  fi
  rm -rf "$work"
}
trap cleanup EXIT

ditto "$app" "$work/staging/Breeze.app"
ln -s /Applications "$work/staging/Applications"
dmg="build-dmg/Breeze-Hardened-macOS-$version-arm64.dmg"
hdiutil create -volname 'Breeze Hardened' -srcfolder "$work/staging" \
  -format UDZO -fs HFS+ -ov "$dmg"
hdiutil verify "$dmg"
hdiutil attach -readonly -nobrowse -mountpoint "$work/mount" "$dmg"
mounted=true

packaged_app="$work/mount/Breeze.app"
codesign --verify --deep --strict --verbose=2 "$packaged_app"

while IFS= read -r -d '' native_file; do
  if file -b "$native_file" | grep -Fq 'Mach-O'; then
    lipo -verify_arch arm64 "$native_file"
  fi
done < <(find "$packaged_app" -type f -print0)
echo "Verified arm64 slices in the packaged Mach-O files"

if [[ "${GITHUB_ACTIONS:-}" == true && "$(uname -m)" == arm64 ]]; then
  "$packaged_app/Contents/MacOS/$binary" >"$work/startup.log" 2>&1 &
  pid=$!
  database="$HOME/Library/Application Support/com.zephyr.breeze/db/breeze_db/data.mdb"
  for attempt in {1..30}; do
    kill -0 "$pid" 2>/dev/null || break
    [[ -s "$database" ]] && break
    sleep 1
  done
  if [[ ! -s "$database" ]] || ! kill -0 "$pid" 2>/dev/null; then
    cat "$work/startup.log"
    echo "::error::The packaged Breeze app did not initialize its database"
    exit 1
  fi
  sleep 3
  if ! kill -0 "$pid" 2>/dev/null || grep -qF 'App Setup Failed' "$work/startup.log"; then
    cat "$work/startup.log"
    echo "::error::The packaged Breeze app did not remain running after initialization"
    exit 1
  fi
  echo "The packaged arm64 app launched and initialized its database"
fi
