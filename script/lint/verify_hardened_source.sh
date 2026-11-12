#!/usr/bin/env bash
set -euo pipefail

deny_source() {
  local pattern=$1
  shift

  if git grep -nEi "$pattern" -- "$@"; then
    echo "::error::Hardened source policy failed"
    exit 1
  else
    test "$?" -eq 1
  fi
}

deny_source \
  'sentry_(flutter|dsn|dart_plugin|auth_token)|sentry-cocoa|sentry-apple-binaries|SentryFlutter|SentryWidget|Sentry\.capture|sendDefaultPii|flatpak-spawn|org\.freedesktop\.Flatpak' \
  lib pubspec.yaml pubspec.lock script/build flatpak macos ios linux/flutter windows/flutter

deny_source \
  'setTlsVerifyEnabled\([[:space:]]*enabled:[[:space:]]*false\)|disable_tls_verify[[:space:]]*[:=][[:space:]]*true|danger_accept_invalid_(certs|hostnames)\(' \
  lib/main.dart rust/build.rs rust/src/api/http.rs rust/src/api/simple.rs \
  rust/src/qjs/mod.rs rust/rquickjs_playground/src/web_runtime/http.rs

deny_source 'allow_private_network[[:space:]]*=[[:space:]]*true' rust/src/api/simple.rs
deny_source 'injectFilesystem:[[:space:]]*true' lib
deny_source 'scheduleSilentCloudUpdate|runSilentCloudUpdateOnce|silentUpdateFromCloud' lib
deny_source '@latest' rust/build.rs
deny_source 'NSAllowsArbitraryLoads|NSAllowsArbitraryLoadsInWebContent' macos/Runner/Info.plist

grep -qF 'setTlsVerifyEnabled(enabled: true)' lib/main.dart
grep -qF 'breeze-plugin-jm-comic@0.0.11' rust/build.rs
grep -qF 'breeze-plugin-bika-comic@0.0.10' rust/build.rs
test "$(grep -cF 'injectFilesystem: false' lib/plugin/plugin_registry_service.dart)" -ge 2
grep -qF 'injectFilesystem: false' lib/network/http/plugin/qjs_download_runtime.dart
