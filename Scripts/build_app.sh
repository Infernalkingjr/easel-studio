#!/bin/bash
# Builds Easel, Reel, Tone, Flip, Quill and Folio (release, native for this Mac) into ./build.
#   Scripts/build_app.sh          # all apps
#   Scripts/build_app.sh easel    # just Easel
#   Scripts/build_app.sh reel     # just Reel (also: tone, flip, quill, folio)
#   UNIVERSAL=1 Scripts/build_app.sh   # Apple silicon + Intel in one binary (for installers)
set -euo pipefail
cd "$(dirname "$0")/.."

WHICH="${1:-all}"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  # Built separately and merged, which works with just the Command Line Tools.
  OTHER="$([[ "$(uname -m)" == "arm64" ]] && echo x86_64 || echo arm64)"
  swift build -c release --triple "$OTHER-apple-macosx14.0" --scratch-path ".build-$OTHER"
  OTHER_BIN_DIR="$(swift build -c release --triple "$OTHER-apple-macosx14.0" --scratch-path ".build-$OTHER" --show-bin-path)"
fi
mkdir -p build

icon() { # name style
  local set="build/$1.iconset"
  rm -rf "$set" && mkdir -p "$set"
  swift Scripts/make_icon.swift "build/$1-1024.png" "$2"
  for s in 16 32 128 256 512; do
    sips -z $s $s "build/$1-1024.png" --out "$set/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "build/$1-1024.png" --out "$set/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$set" -o "build/$1.app/Contents/Resources/AppIcon.icns"
}

bundle() { # name
  local app="build/$1.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  if [[ -n "${OTHER_BIN_DIR:-}" ]]; then
    lipo -create "$BIN_DIR/$1" "$OTHER_BIN_DIR/$1" -output "$app/Contents/MacOS/$1"
  else
    cp "$BIN_DIR/$1" "$app/Contents/MacOS/$1"
  fi
}

finish() { # name
  codesign --force --deep --sign - "build/$1.app" >/dev/null 2>&1 || true
  # Register with Launch Services so the apps can find each other and open their files.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "build/$1.app" >/dev/null 2>&1 || true
  echo "Built build/$1.app"
}

if [[ "$WHICH" == "all" || "$WHICH" == "easel" ]]; then
  bundle Easel
  icon Easel easel
  cat > build/Easel.app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Easel</string>
  <key>CFBundleDisplayName</key><string>Easel</string>
  <key>CFBundleIdentifier</key><string>app.easel.editor</string>
  <key>CFBundleExecutable</key><string>Easel</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>app.easel.project</string>
      <key>UTTypeDescription</key><string>Easel Project</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>easel</string></array></dict>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Easel Project</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key><array><string>app.easel.project</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Image</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.image</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST
  finish Easel
fi

if [[ "$WHICH" == "all" || "$WHICH" == "reel" ]]; then
  bundle Reel
  icon Reel reel
  cat > build/Reel.app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Reel</string>
  <key>CFBundleDisplayName</key><string>Reel</string>
  <key>CFBundleIdentifier</key><string>app.easel.reel</string>
  <key>CFBundleExecutable</key><string>Reel</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Reel turns the speech in your videos into captions, on your Mac.</string>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>app.easel.reel.project</string>
      <key>UTTypeDescription</key><string>Reel Project</string>
      <key>UTTypeConformsTo</key><array><string>public.json</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>reel</string></array></dict>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Reel Project</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key><array><string>app.easel.reel.project</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Media</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.movie</string><string>public.audio</string><string>public.image</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST
  finish Reel
fi

if [[ "$WHICH" == "all" || "$WHICH" == "tone" ]]; then
  bundle Tone
  icon Tone tone
  cat > build/Tone.app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Tone</string>
  <key>CFBundleDisplayName</key><string>Tone</string>
  <key>CFBundleIdentifier</key><string>app.easel.tone</string>
  <key>CFBundleExecutable</key><string>Tone</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key><string>Tone records audio from your microphone.</string>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>app.easel.tone.project</string>
      <key>UTTypeDescription</key><string>Tone Session</string>
      <key>UTTypeConformsTo</key><array><string>public.json</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>tone</string></array></dict>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Tone Session</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key><array><string>app.easel.tone.project</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Audio</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.audio</string><string>public.movie</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST
  finish Tone
fi

if [[ "$WHICH" == "all" || "$WHICH" == "flip" ]]; then
  bundle Flip
  icon Flip flip
  cat > build/Flip.app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Flip</string>
  <key>CFBundleIdentifier</key><string>app.easel.flip</string>
  <key>CFBundleExecutable</key><string>Flip</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>app.easel.flip.project</string>
      <key>UTTypeDescription</key><string>Flip Animation</string>
      <key>UTTypeConformsTo</key><array><string>public.json</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>flip</string></array></dict>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Flip Animation</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key><array><string>app.easel.flip.project</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Image</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.image</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST
  finish Flip
fi

if [[ "$WHICH" == "all" || "$WHICH" == "quill" ]]; then
  bundle Quill
  icon Quill quill
  cat > build/Quill.app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Quill</string>
  <key>CFBundleDisplayName</key><string>Quill</string>
  <key>CFBundleIdentifier</key><string>app.easel.quill</string>
  <key>CFBundleExecutable</key><string>Quill</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>app.easel.quill.project</string>
      <key>UTTypeDescription</key><string>Quill Artwork</string>
      <key>UTTypeConformsTo</key><array><string>public.json</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>quill</string></array></dict>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Quill Artwork</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key><array><string>app.easel.quill.project</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Image</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.image</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST
  finish Quill
fi

if [[ "$WHICH" == "all" || "$WHICH" == "folio" ]]; then
  bundle Folio
  icon Folio folio
  cat > build/Folio.app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Folio</string>
  <key>CFBundleDisplayName</key><string>Folio</string>
  <key>CFBundleIdentifier</key><string>app.easel.folio</string>
  <key>CFBundleExecutable</key><string>Folio</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>PDF Document</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Default</string>
      <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Image</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.image</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST
  finish Folio
fi
