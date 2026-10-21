#!/bin/bash
# Easel Studio installer: downloads the latest release and puts the apps in /Applications.
#   curl -fsSL https://infernalkingjr.github.io/easel-studio/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- folio reel     # only some apps
#   curl -fsSL .../install.sh | bash -s -- --uninstall    # remove them all
# Files fetched with curl aren't quarantined, so the apps open without Gatekeeper prompts.
set -euo pipefail

REPO="Infernalkingjr/easel-studio"
ALL=(Easel Reel Tone Flip Quill Folio)
URL="https://github.com/$REPO/releases/latest/download/EaselStudio.zip"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Easel Studio is for macOS."
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 14 )) || fail "Easel Studio needs macOS 14 Sonoma or later (this Mac has $(sw_vers -productVersion))."

# /Applications when we can write there, else ~/Applications.
DEST=/Applications
[[ -w "$DEST" ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

pick=()
uninstall=0
for arg in "$@"; do
  case "$arg" in
    --uninstall) uninstall=1 ;;
    -h|--help) sed -n '2,6p' "$0" 2>/dev/null || true; exit 0 ;;
    *)
      name="$(echo "${arg:0:1}" | tr '[:lower:]' '[:upper:]')$(echo "${arg:1}" | tr '[:upper:]' '[:lower:]')"
      [[ " ${ALL[*]} " == *" $name "* ]] || fail "Unknown app “${arg}”. Choose from: ${ALL[*]}"
      pick+=("$name") ;;
  esac
done
(( ${#pick[@]} )) || pick=("${ALL[@]}")

if (( uninstall )); then
  for a in "${pick[@]}"; do
    for dir in /Applications "$HOME/Applications"; do
      if [[ -d "$dir/$a.app" ]]; then rm -rf "$dir/$a.app" && echo "Removed $dir/$a.app"; fi
    done
  done
  echo "Your files in ~/Library/Application Support/Easel Studio were left alone."
  exit 0
fi

bold "Installing Easel Studio: ${pick[*]}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Downloading…"
curl -fL --progress-bar "$URL" -o "$TMP/EaselStudio.zip" || fail "Download failed. Check your connection, or get the installer from https://github.com/$REPO/releases"
ditto -x -k "$TMP/EaselStudio.zip" "$TMP/x"
SRC="$TMP/x/Easel Studio"

arch="$(uname -m)"
if ! lipo -archs "$SRC/Easel.app/Contents/MacOS/Easel" | grep -qw "$arch"; then
  fail "This release isn't built for $arch Macs yet. You can build it yourself: https://github.com/$REPO#build"
fi

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for a in "${pick[@]}"; do
  if pgrep -xq "$a"; then echo "Quitting ${a}…"; osascript -e "quit app \"$a\"" >/dev/null 2>&1 || true; sleep 1; fi
  rm -rf "$DEST/$a.app"
  ditto "$SRC/$a.app" "$DEST/$a.app"
  xattr -dr com.apple.quarantine "$DEST/$a.app" 2>/dev/null || true
  "$LSREGISTER" -f "$DEST/$a.app" >/dev/null 2>&1 || true
  echo "  ✓ $a"
done
bold "Done. The apps are in $DEST."
