# GoPro Timelapser for Mac

A native Mac app (Swift + AppKit) that uses macOS's own video engine (AVFoundation / VideoToolbox),
so there is no ffmpeg to bundle. It's a **universal app**: it runs natively on Apple Silicon and on Intel
Macs back to **macOS 10.15 Catalina**.

## Tabs

**Timelapse**
* Drag clips (or a folder) in from Finder, then drag rows or use the buttons to reorder them.
  New clips are sorted by recording time.
* Speed from 2× to 400×.
* Quality: resolution, a quality slider (bitrate), frame rate, and the H.264 or HEVC codec.
* **Sound**: off, or on with either *Keep natural pitch* or *Chipmunk*.

**Join Clips** (normal speed)
* **Lossless** is the default. It copies the video without re-encoding, so it's fast and loses no
  quality. The clips must share codec and resolution, which GoPro chapters always do.
* **Re-encode** shrinks the video or changes its resolution, with the same controls as the timelapse tab.
* Sound on/off, cut time off the start and end, and **keep the original recording date** (written to
  the video's metadata and the file's dates, so Photos and Finder sort it correctly).

## Installing

Download `GoPro-Timelapser-mac.zip` from the latest *Build Mac app* run's **Artifacts** (or a `mac-v*`
release), unzip it, and move **GoPro Timelapser.app** to Applications.

The app isn't notarized by Apple, so the first launch needs one extra step:

* **Catalina / Big Sur / Monterey:** right-click the app → **Open** → **Open**.
* **Ventura and later:** double-click it, dismiss the warning, then go to **System Settings → Privacy &
  Security** and click **Open Anyway**.

To try the Intel version on an Apple Silicon Mac (closest thing to running on an older Intel MacBook):

```
arch -x86_64 "/Applications/GoPro Timelapser.app/Contents/MacOS/GoProTimelapser"
```

## Building

On a Mac with Xcode 15 or later:

```
cd mac
swift test                 # unit + end-to-end tests (generates its own test clips)
./scripts/bundle.sh        # → build/GoPro Timelapser.app and build/GoPro-Timelapser-mac.zip
```

GitHub Actions (`.github/workflows/mac.yml`) does the same on every push that touches `mac/`. It also runs the
tests under Rosetta to exercise the Intel build, and takes screenshots of both tabs.
