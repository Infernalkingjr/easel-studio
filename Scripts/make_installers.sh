#!/bin/bash
# Packages the six apps in build/ into installers in dist/:
#   EaselStudio.dmg   disk image: drag the apps to Applications
#   EaselStudio.pkg   macOS Installer package: pick which apps to install
#   EaselStudio.zip   plain archive, used by the one-line installer (docs/install.sh)
#
#   Scripts/make_installers.sh           # package what's in build/ (builds it first if anything is missing)
#   Scripts/make_installers.sh --build   # rebuild all apps first, for Apple silicon and Intel
# The file names carry no version, so github.com/<owner>/<repo>/releases/latest/download/<name> always works.
set -euo pipefail
cd "$(dirname "$0")/.."

APPS=(Easel Reel Tone Flip Quill Folio)
VERSION="${VERSION:-1.0}"
OUT=dist
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

missing=0
for a in "${APPS[@]}"; do [[ -d "build/$a.app" ]] || missing=1; done
if [[ "${1:-}" == "--build" || $missing == 1 ]]; then UNIVERSAL=1 ./Scripts/build_app.sh; fi

rm -rf "$OUT" && mkdir -p "$OUT"
ARCHS="$(lipo -archs build/Easel.app/Contents/MacOS/Easel)"
HOST_ARCHS="$(echo "$ARCHS" | tr ' ' ',')"
echo "Packaging Easel Studio $VERSION ($ARCHS)"

blurb() {
  case "$1" in
    Easel) echo "Photo editing: layers, AI background tools, 14 export formats." ;;
    Reel)  echo "Video editing: timeline, transitions, titles, auto captions." ;;
    Tone)  echo "Audio: multitrack recording, mixer and effects, restoration." ;;
    Flip)  echo "2D animation: frame-by-frame drawing, onion skin, tweens." ;;
    Quill) echo "Vector art: Bézier pen, shapes, type, Pathfinder, gradients." ;;
    Folio) echo "PDF reader: search, highlights, notes, bookmarks, page tools." ;;
  esac
}

bundle_id() { /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "build/$1.app/Contents/Info.plist"; }

# MARK: Shared read-me (apps are ad-hoc signed, so macOS asks once before opening them)

cat > "$WORK/Read Me First.txt" <<TXT
Easel Studio $VERSION: six apps for macOS 14 or later.

Install: drag the apps you want onto the Applications folder.

First launch: these apps aren't notarized by Apple, so macOS may say an app
"can't be opened" or "is damaged". To open it anyway, either:
  - Right-click (Control-click) the app in Applications, choose Open, then Open; or
  - Open System Settings > Privacy & Security and click "Open Anyway"; or
  - In Terminal run:  xattr -dr com.apple.quarantine /Applications/{Easel,Reel,Tone,Flip,Quill,Folio}.app

The one-line Terminal installer skips all of this:
  curl -fsSL https://infernalkingjr.github.io/easel-studio/install.sh | bash
TXT

# MARK: Disk image

DMG_ROOT="$WORK/dmg"
mkdir -p "$DMG_ROOT"
for a in "${APPS[@]}"; do ditto "build/$a.app" "$DMG_ROOT/$a.app"; done
ln -s /Applications "$DMG_ROOT/Applications"
cp "$WORK/Read Me First.txt" "$DMG_ROOT/"
hdiutil create -quiet -volname "Easel Studio" -srcfolder "$DMG_ROOT" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUT/EaselStudio.dmg"
echo "Made $OUT/EaselStudio.dmg"

# MARK: Installer package, one choosable component per app

PKGS="$WORK/pkgs"
RES="$WORK/resources"
mkdir -p "$PKGS" "$RES"
choices=""
outline=""
refs=""
for a in "${APPS[@]}"; do
  root="$WORK/root-$a"
  mkdir -p "$root"
  ditto "build/$a.app" "$root/$a.app"
  # Install into /Applications even if a copy lives somewhere else (no bundle relocation).
  pkgbuild --analyze --root "$root" "$WORK/$a.plist" >/dev/null
  plutil -replace 0.BundleIsRelocatable -bool NO "$WORK/$a.plist"
  id="$(bundle_id "$a")"
  pkgbuild --quiet --root "$root" --component-plist "$WORK/$a.plist" --identifier "$id.pkg" --version "$VERSION" \
    --install-location /Applications "$PKGS/$a.pkg"
  key="$(echo "$a" | tr '[:upper:]' '[:lower:]')"
  outline+="    <line choice=\"$key\"/>"$'\n'
  choices+="  <choice id=\"$key\" title=\"$a\" description=\"$(blurb "$a")\"><pkg-ref id=\"$id.pkg\"/></choice>"$'\n'
  refs+="  <pkg-ref id=\"$id.pkg\" version=\"$VERSION\" onConclusion=\"none\">$a.pkg</pkg-ref>"$'\n'
done

cat > "$RES/welcome.html" <<HTML
<html><body style="font-family: -apple-system, sans-serif; font-size: 13px">
<h2 style="margin-top:0">Easel Studio $VERSION</h2>
<p>Six creative apps that hand work to each other, and everything runs on your Mac:</p>
<ul>
$(for a in "${APPS[@]}"; do echo "<li><b>$a</b>: $(blurb "$a")</li>"; done)
</ul>
<p>On the next screens you can choose which apps to install. They go in your Applications folder.</p>
</body></html>
HTML

cat > "$RES/conclusion.html" <<HTML
<html><body style="font-family: -apple-system, sans-serif; font-size: 13px">
<h2 style="margin-top:0">You’re all set</h2>
<p>Find the apps in your Applications folder or Launchpad.</p>
<p>If macOS says an app can’t be opened the first time, right-click it in Applications and choose <b>Open</b>.
That’s only needed once per app.</p>
</body></html>
HTML

cat > "$WORK/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>Easel Studio</title>
  <welcome file="welcome.html" mime-type="text/html"/>
  <conclusion file="conclusion.html" mime-type="text/html"/>
  <options customize="always" require-scripts="false" hostArchitectures="$HOST_ARCHS"/>
  <domains enable_localSystem="true"/>
  <volume-check>
    <allowed-os-versions><os-version min="14.0"/></allowed-os-versions>
  </volume-check>
  <choices-outline>
$outline  </choices-outline>
$choices$refs</installer-gui-script>
XML

productbuild --quiet --distribution "$WORK/distribution.xml" --resources "$RES" --package-path "$PKGS" "$OUT/EaselStudio.pkg"
echo "Made $OUT/EaselStudio.pkg"

# MARK: Zip for the Terminal installer

ZIP_ROOT="$WORK/zip/Easel Studio"
mkdir -p "$ZIP_ROOT"
for a in "${APPS[@]}"; do ditto "build/$a.app" "$ZIP_ROOT/$a.app"; done
ditto -c -k --keepParent "$ZIP_ROOT" "$OUT/EaselStudio.zip"
echo "Made $OUT/EaselStudio.zip"

ls -lh "$OUT"
