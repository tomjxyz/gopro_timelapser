# GoPro Timelapser

A small Windows 10/11 app that turns a batch of GoPro clips into one sped-up timelapse.
It's a single `GoProTimelapser.exe`: no installer and no admin rights, and it works offline
because ffmpeg is built into the exe.

## Using it

1. **Clips**: drag `.MP4` files (or a whole folder) from Explorer into the list. Each row shows
   the file name, when it was recorded (read from the clip's metadata) and its length.
   New clips are put in recording order. To change the order, drag rows, use the
   **Move up / Move down / top / bottom** buttons, or press **Alt+↑ / Alt+↓**. **Del** removes a clip.
2. **Speed**: 2× – 400×, using the slider, the number box or the presets. The app shows the
   resulting output length.
3. **Quality**
   * **Resolution**: 720p / 1080p / 1440p / 4K / Original. It never upscales beyond the source.
   * **Quality** slider: smaller file ↔ better quality. This sets ICQ `-global_quality` for
     QuickSync or `-crf` for x264, from 40 (smallest) to 18 (best). The default is 26.
   * **Output frame rate**: 30 fps by default.
   * **Encoder**: *Auto* tries Intel QuickSync first and falls back to the CPU (x264) if that fails.
4. Pick the output file and click **Create timelapse**.

The first launch unpacks ffmpeg to `%LOCALAPPDATA%\GoProTimelapser\`, which takes a few seconds. Later
launches reuse it.

### What it runs

All clips are joined with ffmpeg's concat demuxer in the order shown, then (Auto/QuickSync):

```
ffmpeg -hwaccel qsv -hwaccel_output_format qsv -f concat -safe 0 -i list.txt -map 0:v:0 -an
       -vf "setpts=PTS/40,fps=30,scale_qsv=w=-1:h='min(1080,ih)'"
       -c:v h264_qsv -preset medium -global_quality 26 -movflags +faststart out.mp4
```

If GPU decoding fails (e.g. 10-bit HEVC on an older iGPU), it retries with CPU decode + QuickSync
encode, then with plain `libx264 -preset veryfast -crf N`. The **Show log** box shows the exact
commands and ffmpeg output.

## Building

The GitHub Actions workflow (`.github/workflows/build.yml`) builds the exe on every push. Download it
from the run's **Artifacts**. Pushing a `v*` tag also attaches it to a GitHub Release.

To build locally on Windows (needs the .NET 8 SDK):

```powershell
./build.ps1          # downloads ffmpeg once, then publishes publish\GoProTimelapser.exe
```

## License note

The embedded ffmpeg is the GPL build from [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds).
