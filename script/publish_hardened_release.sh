#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

artifact_root=$1
version="$(awk '/^version:/ {print $2; exit}' pubspec.yaml)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$ ]]
tag="hardened-v$version-${GITHUB_SHA:0:12}"
output="$(mktemp -d)"
trap 'rm -rf "$output"' EXIT

cd "$artifact_root"
macos=("$PROJECT_NAME"-Hardened-macOS-arm64*)
linux=("$PROJECT_NAME"-Hardened-Linux-x64*)
[[ ${#macos[@]} -eq 1 && ${#linux[@]} -eq 1 ]]

for directory in "${macos[0]}" "${linux[0]}" additional-android additional-ios additional-windows; do
  (
    cd "$directory"
    sha256sum --strict -c SHA256SUMS
    case "$directory" in
      *-macOS-*) packages=(*.dmg); expected=1 ;;
      *-Linux-*) packages=(*.deb); expected=1 ;;
      additional-android)
        packages=(*.apk)
        case "$PROJECT_NAME" in JHenTai) expected=3 ;; Breeze) expected=1 ;; *) exit 1 ;; esac
        ;;
      additional-ios) packages=(*-unsigned.ipa); expected=1 ;;
      additional-windows) packages=(*-Windows-x64-portable.zip); expected=1 ;;
      *) exit 1 ;;
    esac
    [[ ${#packages[@]} -eq "$expected" ]]
    for package in "${packages[@]}"; do
      [[ -s "$package" && ! -e "$output/$package" ]]
      digest="$(sha256sum -- "$package")"
      digest="${digest%% *}"
      # Windows checksum tools may write a binary-mode marker after the digest.
      if ! grep -Fxq -e "$digest  $package" -e "$digest *$package" SHA256SUMS; then
        printf '::error::Checksum list is missing the verified digest for %s\n' "$package"
        exit 1
      fi
      cp -- "$package" "$output/"
    done
    if [[ "$PROJECT_NAME" == Breeze ]]; then
      normalized="$output/current-plugin-sha256sums"
      sed -E 's/^([[:xdigit:]]{64}) \*/\1  /' BUILTIN_PLUGIN_SHA256SUMS > "$normalized"
      if [[ -f "$output/BUILTIN_PLUGIN_SHA256SUMS" ]]; then
        cmp "$normalized" "$output/BUILTIN_PLUGIN_SHA256SUMS"
        rm -- "$normalized"
      else
        mv -- "$normalized" "$output/BUILTIN_PLUGIN_SHA256SUMS"
      fi
    fi
  )
done

cd "$output"
packages=(*.apk *.ipa *.dmg *.deb *.zip)
sha256sum -- "${packages[@]}" > SHA256SUMS
assets=("${packages[@]}" SHA256SUMS)
[[ "$PROJECT_NAME" != Breeze ]] || assets+=(BUILTIN_PLUGIN_SHA256SUMS)
expected_assets="$(sha256sum -- "${assets[@]}" | sort)"
repo="$GITHUB_REPOSITORY"
ref="repos/$repo/git/ref/heads/$GITHUB_REF_NAME"
assert_current_head() {
  actual_head="$(gh api "$ref" --jq '.object.sha')"
  if [[ "$actual_head" != "$GITHUB_SHA" ]]; then
    echo "::error::The build commit is no longer at the head of $GITHUB_REF_NAME"
    return 1
  fi
}

# Keep drafts retryable and publish only when GitHub reports matching asset hashes.
if ! release="$(gh release view "$tag" --repo "$repo" --json databaseId,isDraft,url 2>release-error)"; then
  if ! grep -qi 'release not found' release-error; then
    cat release-error >&2
    exit 1
  fi

  assert_current_head
  android_note='Android APK 使用此分支的发布密钥签名。覆盖安装要求原应用与此版本的签名一致。'
  unsigned_apks=(*-unsigned.apk)
  if (( ${#unsigned_apks[@]} > 0 )); then
    android_note='Android APK 未签名，安装前需要签名。覆盖安装要求原应用与重新签名的 APK 使用同一密钥。'
  fi
  cat > release-notes.md <<NOTES
[构建日志和来源证明]($GITHUB_SERVER_URL/$repo/actions/runs/$GITHUB_RUN_ID)

- 源码提交 $GITHUB_SHA
- 提供 macOS arm64、Linux x86_64、Windows x64、Android 和 iOS arm64 构建。
- $android_note
- iOS 为未签名 IPA，安装前需要使用适用的 Apple 签名和描述文件。
- macOS 使用临时签名，未经过 Apple 公证。Windows 构建未做 Authenticode 签名。
- 将所需安装包与 SHA256SUMS 放到同一目录可核对 SHA-256。
NOTES

  gh release create "$tag" --repo "$repo" --target "$GITHUB_SHA" --draft \
    --title "$PROJECT_NAME 加固版 $version (${GITHUB_SHA:0:7})" --notes-file release-notes.md
  release="$(gh release view "$tag" --repo "$repo" --json databaseId,isDraft,url)"
fi

release_id="$(jq -er '.databaseId' <<< "$release")"
if [[ "$(jq -r '.isDraft' <<< "$release")" == true ]]; then
  gh release upload "$tag" --repo "$repo" --clobber "${assets[@]}"
fi

published_assets="$(gh api "repos/$repo/releases/$release_id" --jq '
  .assets[] | select(.state == "uploaded" and (.digest | startswith("sha256:"))) |
  (.digest | ltrimstr("sha256:")) + "  " + .name' | sort)"
if [[ "$published_assets" != "$expected_assets" ]]; then
  echo "::error::Release assets returned by GitHub do not match the build output checksums"
  exit 1
fi

if [[ "$(jq -r '.isDraft' <<< "$release")" == true ]]; then
  assert_current_head
  gh release edit "$tag" --repo "$repo" --draft=false
fi

[[ "$(gh api "repos/$repo/git/ref/tags/$tag" --jq '.object.sha')" == "$GITHUB_SHA" ]]
[[ "$(gh release view "$tag" --repo "$repo" --json isDraft --jq .isDraft)" == false ]]
gh release view "$tag" --repo "$repo" --json url --jq .url
