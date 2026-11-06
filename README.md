# LocalSummary

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

## Requirements

- Apple Silicon Mac, macOS 15+ (macOS 26+ for the Apple Intelligence summarizer)
- Xcode 16.3+ / Swift 6.1+

## Run

```sh
# Command line
swift run -c release localsummary ~/Desktop/meeting.m4a
swift run -c release localsummary talk.mp3 --engine server --model qwen3:8b   # via Ollama

# Desktop app (built as a proper .app so the mic permission prompt works)
./scripts/make-app.sh && open build/LocalSummary.app
```

You can also open `Package.swift` in Xcode and run the `LocalSummaryApp` scheme.

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
| `Sources/LocalSummaryCore/Transcriber.swift` | FluidAudio ASR wrapper, sentence segmentation |
| `Sources/LocalSummaryCore/Summarizer.swift` | Prompts and map-reduce chunking |
| `Sources/LocalSummaryCore/Engines.swift` | Apple Intelligence + OpenAI-compatible local server engines |
| `Sources/LocalSummaryCore/Pipeline.swift` | audio → transcript → summary |
| `Sources/localsummary/` | CLI |
| `Sources/LocalSummaryApp/` | SwiftUI app: record (with level meter + menu bar icon), upload / drag & drop / Open With, queue with progress and cancel, audio player with clickable timestamps, search, rename, export |

## Ideas / next steps

- Speaker labels via FluidAudio's diarizer (`traits: ["Diarizer"]`, `OfflineDiarizerManager`)
- Live transcript while recording (`SlidingWindowAsrManager`)
- Embedded MLX model so no separate server is needed for large models
- "Ask questions about this recording" chat

## iPhone and iPad app (`iOS/`)

A SwiftUI app (working name LocalNotes, bundle id `dev.chrisswimlee.LocalNotes`, iOS 26+) built on the same
`LocalSummaryCore` library: record, import audio or video, transcript with tap-to-play timestamps, summaries
with checkable action items, and quick voice notes (tap or hold the mic button, or use the "New Voice Note"
shortcut from Siri, Shortcuts, Spotlight or the Action button).

```sh
brew install xcodegen          # once
cd iOS && xcodegen && open LocalNotes.xcodeproj
```

`project.yml` is the source of truth for the Xcode project; edit it and re-run `xcodegen`.
Summaries need Apple Intelligence (iPhone 15 Pro or newer), or a Mac on the same network running Ollama / LM Studio.

Simulator testing (Debug builds only): `xcrun simctl launch booted dev.chrisswimlee.LocalNotes -importPath /path/to/audio.m4a`
imports a file on launch; `-openFirst YES` opens the newest item; `-openSettings YES` opens Settings.
