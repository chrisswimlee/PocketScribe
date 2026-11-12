# PocketPad

Record or drop in an audio file, get a transcript and a structured summary. Everything runs on your Mac. No audio or text leaves the machine.

## How it works

```
audio (record / upload / drag & drop: m4a, mp3, wav, mov…)
   │
   ▼
FluidAudio · Parakeet TDT (CoreML on the Neural Engine)    ← same engine as FluidVoice
   │   transcript + word timings → timestamped sentences
   ▼
Summarizer (map-reduce for long recordings)
   ├─ Apple Intelligence on-device model (default, nothing to install)
   └─ any local OpenAI-compatible server: Ollama, LM Studio, llama.cpp, mlx_lm.server
   │
   ▼
Markdown: TL;DR · Key points · Decisions · Action items · Notable moments [mm:ss]
```

FluidVoice itself is a dictation app with no API for transcribing files, so this project uses
[FluidAudio](https://github.com/FluidInference/FluidAudio), the Swift SDK FluidVoice is built on, directly.
The Parakeet model (~500 MB) downloads once on first run to `~/Library/Application Support/FluidAudio`, then works offline.

## Speaker labels and action items

- Recordings over 3 minutes get **speaker labels** (Speaker 1, Speaker 2…) from FluidAudio's offline
  diarizer (pyannote + WeSpeaker + VBx on Core ML, ~30 MB of models downloaded once). Click or tap a
  name in the transcript to rename it; the new name is used in the transcript, the summary and exports.
  Turn it off in Settings, or `--no-speakers` in the CLI. Older recordings show a "Label speakers" button.
- **Action items** can be sent to Reminders (one at a time or all at once) or Calendar. Deadlines like
  "by Friday" or "Thursday at 3pm" become due dates. On iPhone, Calendar opens the system event sheet so
  you pick the time; on the Mac the event is added at the said time, or 9:00 that day / tomorrow.
- `swift test` runs the unit tests for both.

## Requirements

- Apple Silicon Mac, macOS 15+ (macOS 26+ for the Apple Intelligence summarizer)
- Xcode 16.3+ / Swift 6.1+

## Run

```sh
# Command line
swift run -c release pocketpad ~/Desktop/meeting.m4a
swift run -c release pocketpad talk.mp3 --engine server --model qwen3:8b   # via Ollama

# Desktop app (built as a proper .app so the mic permission prompt works)
./scripts/make-app.sh && open build/PocketPad.app
```

You can also open `Package.swift` in Xcode and run the `PocketPadApp` scheme.

## Using a bigger local model (optional)

The Apple on-device model is small (~4k token context), so long recordings get chunked heavily.
For better summaries of long meetings, run a larger model locally:

```sh
brew install ollama && ollama serve &
ollama pull qwen3:8b        # or gemma3:12b, llama3.1:8b …
```

Then pick **Local model server** in the app's Settings (⌘,) or pass `--engine server` on the CLI.
LM Studio works too: start its server and use `http://localhost:1234/v1`.

## Layout

| Path | What |
|---|---|
| `Sources/PocketPadCore/Transcriber.swift` | FluidAudio ASR wrapper, sentence segmentation |
| `Sources/PocketPadCore/Summarizer.swift` | Prompts and map-reduce chunking |
| `Sources/PocketPadCore/Engines.swift` | Apple Intelligence + OpenAI-compatible local server engines |
| `Sources/PocketPadCore/Pipeline.swift` | audio → transcript → summary |
| `Sources/pocketpad/` | CLI |
| `Sources/PocketPadApp/` | SwiftUI app: record (with level meter + menu bar icon), upload / drag & drop / Open With, queue with progress and cancel, audio player with clickable timestamps, search, rename, export |

## Ideas / next steps

- Live transcript while recording (`SlidingWindowAsrManager`)
- Embedded MLX model so no separate server is needed for large models
- "Ask questions about this recording" chat

## iPhone and iPad app (`iOS/`)

A SwiftUI app (PocketPad, bundle id `dev.chrisswimlee.PocketPad`, iOS 26+) built on the same
`PocketPadCore` library: record, import audio or video, transcript with tap-to-play timestamps, summaries
with checkable action items, and quick voice notes (tap or hold the mic button, or use the "New Voice Note"
shortcut from Siri, Shortcuts, Spotlight or the Action button).

```sh
brew install xcodegen          # once
cd iOS && xcodegen && open PocketPad.xcodeproj
```

`project.yml` is the source of truth for the Xcode project; edit it and re-run `xcodegen`.
Summaries need Apple Intelligence (iPhone 15 Pro or newer), or a Mac on the same network running Ollama / LM Studio.

Simulator testing (Debug builds only): `xcrun simctl launch booted dev.chrisswimlee.PocketPad -importPath /path/to/audio.m4a`
imports a file on launch; `-openFirst YES` opens the newest item; `-openSettings YES` opens Settings.
