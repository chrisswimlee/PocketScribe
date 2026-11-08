import Foundation
import LocalSummaryCore

let usage = """
usage: localsummary <audio-file> [options]

  --engine apple|server     Summarizer (default: apple = on-device Apple Intelligence)
  --model NAME              Model for --engine server (default: qwen3:8b)
  --url URL                 OpenAI-compatible base URL (default: http://localhost:11434/v1)
  --asr v3|v2               Speech model: v3 multilingual (default) or v2 English-only
  --no-speakers             Don't label speakers (Speaker 1, Speaker 2…) in recordings over 3 minutes
  --out DIR                 Where to write <name>.md (default: next to the audio file)
"""

var args = Array(CommandLine.arguments.dropFirst())
func take(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

var settings = EngineSettings()
if let e = take("--engine") { settings.kind = (e == "server") ? .localServer : .apple }
if let m = take("--model") { settings.serverModel = m; settings.kind = .localServer }
if let u = take("--url") { settings.serverURL = u; settings.kind = .localServer }
let asr = ASRModelChoice(rawValue: take("--asr") ?? "v3") ?? .multilingual
let labelSpeakers = !args.contains("--no-speakers")
args.removeAll { $0 == "--no-speakers" }
let outDir = take("--out").map { URL(fileURLWithPath: $0, isDirectory: true) }

guard let path = args.first, !path.hasPrefix("-") else {
    print(usage)
    exit(2)
}
let audioURL = URL(fileURLWithPath: path)
guard FileManager.default.fileExists(atPath: audioURL.path) else {
    FileHandle.standardError.write(Data("No such file: \(path)\n".utf8))
    exit(1)
}

let pipeline = Pipeline(engine: settings.makeEngine(), asrModel: asr, labelSpeakers: labelSpeakers)
let started = Date()
do {
    let result = try await pipeline.run(audio: audioURL) { stage in
        let msg: String
        switch stage {
        case .loadingSpeechModel: msg = "Loading speech model (first run downloads it)…"
        case .transcribing: msg = "Transcribing…"
        case .summarizing(let s): msg = s
        case .done: msg = "Done."
        }
        FileHandle.standardError.write(Data("› \(msg)\n".utf8))
    }
    let dir = outDir ?? audioURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let out = dir.appending(path: "\(result.sourceName).summary.md")
    try result.markdown.write(to: out, atomically: true, encoding: .utf8)
    print(result.summary)
    let t = result.transcript
    FileHandle.standardError.write(Data(String(
        format: "\n%@ of audio transcribed in %.1fs, total %.1fs. Saved %@\n",
        formatTimestamp(t.audioDuration), t.processingTime, Date().timeIntervalSince(started), out.path).utf8))
} catch {
    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
