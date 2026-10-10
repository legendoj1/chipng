# Chipng

A Mac and Windows app that alpha-bleeds PNGs, like [Pixelfix](https://devforum.roblox.com/t/pixelfix-remove-the-black-edges-on-scaled-images/201802), so they don't get dark outlines when Roblox scales them. It then compresses them with Google's [Squoosh](https://github.com/GoogleChromeLabs/squoosh) codecs, so you don't need TinyPNG afterwards.

## Build & install (Mac)

```bash
./build-app.sh --install
```

This compiles the app and installs it to `/Applications`. Leave off `--install` to build a test copy at `build/Chipng.app` instead. It needs Xcode or the Command Line Tools (macOS 14+).

To work on the code, open `Package.swift` in Xcode and press ⌘R.

## Build (Windows)

```bash
./Windows/build-windows.sh
```

This writes a single `Windows/Chipng.exe` that runs on 64-bit Windows 10 and 11 with nothing to install. It needs the [.NET 10 SDK](https://dotnet.microsoft.com/download) and builds on macOS, Linux or Windows.

- **First launch:** Windows SmartScreen may warn about an unrecognised app, because the exe isn't code-signed. Click **More info → Run anyway**.
- **Compression** uses the Microsoft Edge WebView2 Runtime. It's built into Windows 11 and almost every Windows 10 PC.
- **Editing the code:** open `Windows/Chipng.slnx` in Visual Studio.

## Using it

Shortcuts are shown as Mac / Windows.

1. Drop PNGs or folders onto the window or the Dock icon, or press ⌘O. They're processed right away.
2. Then pick one:
   - **Replace Originals** (⇧⌘R / Ctrl+Shift+R) overwrites the files you added. By default, a copy of each original goes to the Trash (Recycle Bin on Windows) first.
   - **Export** (⇧⌘E / Ctrl+Shift+E) saves every image as a separate file in a folder you choose.
   - **Export as ZIP** (⌥⌘E / Ctrl+Alt+E) saves them all in one archive.

**Windows quick fix:** drop PNGs or folders straight onto `Chipng.exe` (or a shortcut to it), like Pixelfix. A small window bleeds and compresses them, replaces the originals, then closes itself. It uses the same two settings as the main window.

Right-click rows to act on just those images. The inspector previews the selected image. **Show Hidden Colors** reveals the colours alpha bleeding put behind transparent pixels.

There are two settings, both on by default:

- **Compress with Squoosh** shrinks images after bleeding them.
- **Keep originals in Trash** (Recycle Bin on Windows) makes Replace Originals put a copy of each original there first. Turn it off to overwrite files without a backup.

## What happens to each image

1. **Alpha bleed.** This is the original chipng / [urraka](https://github.com/urraka/alpha-bleeding) algorithm, ported to Swift (`AlphaBleed.swift`). PNGs are decoded with a custom decoder (`PNGCodec.swift`), because macOS's image APIs premultiply alpha and would erase the hidden colours.
2. **Squoosh compression.** This uses Squoosh's own default settings. Its WebAssembly codecs run in a hidden WebKit view with a pool of workers (`Resources/Squoosh`).
   - **Reduce Palette** uses libimagequant at 256 colours with full dithering, like TinyPNG.
   - **OxiPNG** runs at level 2.
3. **Bleed protection.** Stock Squoosh and TinyPNG both turn every invisible pixel black, which brings the dark edges back. Chipng prevents this in two ways:
   - OxiPNG always runs with alpha optimisation off. It uses [jSquash](https://github.com/jamsinclair/jSquash)'s build of Squoosh's OxiPNG codec, which exposes that switch.
   - After palette reduction, the image is bled again. Invisible pixels are snapped to "twins" of the visible palette colours, so the result is still a small 8-bit PNG (`PaletteBleed` in `AlphaBleed.swift`).
4. **Quality guard.** If palette reduction would visibly change an image (below 32 dB PSNR, e.g. photos or noisy gradients), that image is compressed losslessly with OxiPNG instead.

## Project layout

| Path | What's there |
|---|---|
| `Sources/Chipng`, `Package.swift` | Mac app (SwiftUI) |
| `Windows/Chipng` | Windows app (WPF with [WPF-UI](https://github.com/lepoco/wpfui) for the Windows 11 look) |
| `Windows/Chipng.Core` | Windows image pipeline: a C# port of the Swift PNG codec, alpha bleed and palette bleed |
| `Windows/Chipng.CoreCheck` | Cross-platform checks that the C# pipeline matches the Mac app pixel for pixel |
| `Resources/Squoosh` | Squoosh engine shared by both apps (WKWebView on Mac, WebView2 on Windows) |

## Command line

```bash
build/Chipng.app/Contents/MacOS/Chipng --cli in.png out.png [--no-compress]
```

## History

This started as a fork of [chipng](https://github.com/rbxxaxa/chipng), a web app for alpha-bleeding images. The alpha-bleed algorithm is ported from it. The website has been removed from this repository; it's still in the git history.

## Licences

| Component | Licence |
|---|---|
| Squoosh | Apache-2.0 |
| WPF-UI | MIT |
| OxiPNG | MIT |
| libimagequant | GPL-3.0 |

Each codec's licence file is in `Resources/Squoosh/codecs/`.
