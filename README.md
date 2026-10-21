# Easel Studio

Six native macOS apps that work together, all processing on your Mac (macOS 14+, Apple silicon and Intel).

**Website & downloads:** https://infernalkingjr.github.io/easel-studio/

| App | Like | What it does |
|---|---|---|
| **Easel** | Photoshop | Photo editing: layers, AI background tools, 14 export formats |
| **Reel** | Premiere | Video editing: timeline, 13 transitions, titles, auto captions, H.264/HEVC/GIF |
| **Tone** | Audition | Audio: multitrack recording, mixer & effects, noise/hum/click restoration |
| **Flip** | Animate | 2D animation: frame-by-frame drawing, onion skin, motion tweens, video/GIF export |
| **Quill** | Illustrator | Vector art: Bézier pen, shapes, type, Pathfinder, gradients, layers; SVG/PDF/PNG export |
| **Folio** | Preview / Acrobat Reader | PDF reader: search, contents, thumbnails, highlights/underlines/notes, bookmarks, night & sepia modes, rotate/insert/delete pages, print |

## Install

Get them from the [latest release](https://github.com/Infernalkingjr/easel-studio/releases/latest):

- **EaselStudio.dmg**: drag the apps onto Applications.
- **EaselStudio.pkg**: an installer that lets you choose which apps to install.
- **Terminal:** `curl -fsSL https://infernalkingjr.github.io/easel-studio/install.sh | bash`
  (add app names such as `| bash -s -- folio reel` to install only those, or `--uninstall` to remove them).

The apps aren't notarized, so the first time you open one from the .dmg or .pkg, right-click it and choose **Open**.
The Terminal installer doesn't need that.

## Build

```sh
./Scripts/build_app.sh                # builds all six into build/
./Scripts/build_app.sh folio          # just one: easel, reel, tone, flip, quill or folio
UNIVERSAL=1 ./Scripts/build_app.sh    # Apple silicon + Intel
./Scripts/make_installers.sh --build  # universal build, then dist/EaselStudio.dmg, .pkg and .zip
```

## How they connect

- **Easel → Reel / Flip / Quill / Folio:** *Send to* adds your image as a clip, overlay, animation layer, artwork or PDF page.
- **Reel → Easel:** *Edit in Easel* on a photo clip; ⌘S in Easel updates it in Reel. *Frame → Easel* opens a video frame.
- **Reel → Tone:** *Edit in Tone* on a music clip; ⌘S in Tone updates the soundtrack in Reel.
- **Tone → Reel:** *Send Mix to Reel* adds the mix as music.
- **Flip → Reel:** *Send to Reel* adds the animation (transparent backgrounds stay transparent).
- **Quill → Folio:** *Send to Folio* opens the artwork as a vector PDF. Quill can also send PNGs to Easel, Reel and Flip.
- **Folio → Easel / Reel:** *Send Page* sends the current PDF page as a picture. When a document is open, files sent to Folio can be added as pages.

Round-trip edits always work on copies, so original files are never changed. Shared files live in
`~/Library/Application Support/Easel Studio/`.

## Code layout

- `Sources/EaselKit`: shared looks, adjustments, bitmap helpers and the app-to-app link.
- `Sources/Easel`, `Sources/Reel`, `Sources/Tone`, `Sources/Flip`, `Sources/Quill`, `Sources/Folio`: the apps.
- `Scripts/`: app bundling, icons and installers.
- `docs/`: the website (GitHub Pages) and `install.sh`.

## Self-tests (debug builds)

```sh
swift build
EASEL_SELFTEST=/tmp/t .build/debug/Easel
REEL_SELFTEST=/tmp/t  .build/debug/Reel
TONE_SELFTEST=/tmp/t  .build/debug/Tone
FLIP_SELFTEST=/tmp/t  .build/debug/Flip
QUILL_SELFTEST=/tmp/t .build/debug/Quill
FOLIO_SELFTEST=/tmp/t .build/debug/Folio
```
