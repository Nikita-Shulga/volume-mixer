# Volume Mixer

A tiny macOS menu bar app that gives every app its own volume slider and mute button, like the Windows volume mixer.

macOS only has one system-wide volume. Volume Mixer sits in the menu bar (top right), and clicking it shows each app that can play sound with:

- a **volume slider** (0–100%)
- a **mute button**
- a green dot while the app is actually playing

Settings are remembered per app, so a muted app stays muted after it restarts.

## Download

[Download the latest version](https://github.com/Nikita-Shulga/volume-mixer/releases/latest) (`VolumeMixer-1.0-mac-universal.zip`). One app for both Apple Silicon and Intel Macs, macOS 14.2 or later.

Unzip it and drag **Volume Mixer** to Applications. The app isn't signed by Apple yet, so the first time you open it macOS blocks it: go to *System Settings → Privacy & Security* and click *Open Anyway*. If macOS says the app is damaged, run `xattr -cr "/Applications/Volume Mixer.app"` once.

## Which apps are listed

- Open apps that have registered with the macOS audio system (Core Audio)
- Apps that have done so before, remembered across restarts, so they appear as soon as they launch
- Web browsers, always
- Any app whose volume you changed

Apps like Finder or Numbers, which never set up audio, are hidden.

Helper processes are grouped under their app. For example, Chrome's helper processes show as one "Google Chrome" row, and Safari's WebKit audio process shows as "Safari".

## Resource usage

Volume Mixer does no polling. macOS notifies it when apps start or stop playing.

| App state | What runs |
|---|---|
| 100% | Nothing, the app's audio is untouched |
| Muted | macOS silences the app at the source; no audio thread runs |
| Lowered, while playing | One lightweight audio callback that scales the samples |
| Lowered, while silent | Nothing, the audio callback is stopped |

When idle, it uses 0% CPU and about 11 MB of memory.

## Requirements

- macOS 14.2 or later (uses Core Audio process taps)
- Xcode Command Line Tools to build (`xcode-select --install`)

## Build and install

```bash
./build.sh
cp -R "build/Volume Mixer.app" /Applications/
open "/Applications/Volume Mixer.app"
```

The first time you change an app's volume, macOS asks whether **Volume Mixer** may record system audio. Click **Allow**. The app uses this permission to route an app's sound through its slider; nothing is recorded or saved.

If you rebuild, the ad-hoc signature changes and macOS may ask again. If a slider seems to do nothing, open **System Settings → Privacy & Security → Screen & System Audio Recording** and switch Volume Mixer off and on under "System Audio Recording Only".

To start it automatically, tick **Launch at login** at the bottom of the popover.

## How it works

For each app you adjust, Volume Mixer creates a private [Core Audio process tap](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) with `muteBehavior = .muted`, which stops the app's sound from reaching the speakers directly:

- **Muted:** that's all; the app is silent.
- **Lowered:** a private aggregate device reads the tap, multiplies the samples by the slider value (with a short ramp to avoid clicks), and plays them on the current output device.

Taps and aggregate devices are private to the process, so if Volume Mixer quits or crashes, every app's sound goes back to normal.

| File | Purpose |
|---|---|
| `Sources/AppTap.swift` | Tap, aggregate device and real-time gain callback |
| `Sources/Mixer.swift` | App discovery, grouping, settings, applying taps |
| `Sources/MixerView.swift` | SwiftUI popover |
| `Sources/main.swift` | Menu bar item and app entry point |
| `build.sh` | Compiles, bundles, renders the icon and signs |

### Diagnostics

```bash
"/Applications/Volume Mixer.app/Contents/MacOS/VolumeMixer" --list
```

prints the apps Volume Mixer currently lists.

## Known limitations

- When a lowered app starts playing, there can be a very short moment of silence while its audio path starts.
- Apps that spawn a new audio process right as they start playing may be briefly heard at full volume until the new process is picked up.

## License

MIT. See [LICENSE](LICENSE).
