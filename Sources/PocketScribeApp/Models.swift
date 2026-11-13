import AVFoundation
import Foundation
import PocketScribeCore

/// One recording or uploaded file in the library.
struct Recording: Identifiable, Codable, Equatable {
    enum Status: String, Codable { case queued, processing, ready, failed }

    var id = UUID()
    var title: String
    var titleIsAutomatic = true
    var createdAt = Date()
    /// File name inside the app's Audio folder.
    var audioFileName: String
    var duration: TimeInterval?
    var status: Status = .queued
    var errorMessage: String?
    var transcript: Transcript?
    var summary: String?
    var engineName: String?
    /// Indices (within the Action items section) the user ticked off.
    var checkedActions: Set<Int> = []
    /// Set for short recordings that were turned into a voice note (nil = meeting-style summary).
    var noteKind: VoiceNote.Kind?
    var tags: [String]?
    /// Names the user gave to "Speaker 1", "Speaker 2"… (keyed by speaker number).
    var speakerNames: [Int: String]?
    /// Action item indices already sent to Reminders / added to Calendar.
    var sentToReminders: Set<Int>?
    var sentToCalendar: Set<Int>?
    /// Text read from an imported PDF, Word file, slide deck or text file (nil for audio).
    var document: DocumentText?
    /// The imported file's name, e.g. "Q3 plan.pdf".
    var originalFileName: String?
    /// Note or meeting summary, when the user picked one (nil = chosen automatically).
    var summaryStyle: SummaryStyle?
    /// The user waved away the suggested speaker names.
    var nameSuggestionsDismissed: Bool?

    /// PDFs, Word files, slide decks and text files are read, not transcribed.
    var isDocument: Bool { DocumentReader.canRead(fileName: audioFileName) }

    var tldr: String? {
        if noteKind != nil {
            return summary?.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { String($0).replacingOccurrences(of: "- [ ] ", with: "") }
        }
        return summary.flatMap { Summarizer.section("TL;DR", in: $0) }
    }

    var markdown: String {
        var out = "# \(title)\n\n_\(createdAt.formatted(date: .abbreviated, time: .shortened))"
        if let d = duration { out += " · \(formatTimestamp(d))" }
        if let e = engineName { out += " · summarized by \(e)" }
        out += "_\n\n"
        if let s = summary { out += Speakers.apply(speakerNames, to: s) + "\n\n" }
        if let t = transcript { out += "---\n\n## Transcript\n\n\(t.timestampedText(speakerNames: speakerNames))\n" }
        if let d = document { out += "---\n\n_Notes from \(d.sizeDescription) of \(originalFileName ?? title)._\n" }
        return out
    }

    static func defaultRecordingTitle(_ date: Date) -> String {
        "Recording, " + date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

/// Persisted preferences. Plain UserDefaults with @Published so SwiftUI refreshes immediately.
@MainActor
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var engineKind: EngineKind { didSet { d.set(engineKind.rawValue, forKey: "engineKind") } }
    @Published var serverURL: String { didSet { d.set(serverURL, forKey: "serverURL") } }
    @Published var serverModel: String { didSet { d.set(serverModel, forKey: "serverModel") } }
    @Published var asrModel: ASRModelChoice { didSet { d.set(asrModel.rawValue, forKey: "asrModel") } }
    @Published var suggestTitles: Bool { didSet { d.set(suggestTitles, forKey: "suggestTitles") } }
    @Published var labelSpeakers: Bool { didSet { d.set(labelSpeakers, forKey: "labelSpeakers") } }
    @Published var voiceShortcutEnabled: Bool {
        didSet { d.set(voiceShortcutEnabled, forKey: "voiceShortcutEnabled"); AppModel.shared.applyVoiceShortcut() }
    }

    init() {
        engineKind = EngineKind(rawValue: d.string(forKey: "engineKind") ?? "") ?? .apple
        serverURL = d.string(forKey: "serverURL") ?? LocalServerEngine.ollamaDefault.absoluteString
        serverModel = d.string(forKey: "serverModel") ?? "qwen3:8b"
        asrModel = ASRModelChoice(rawValue: d.string(forKey: "asrModel") ?? "") ?? .multilingual
        suggestTitles = d.object(forKey: "suggestTitles") as? Bool ?? true
        labelSpeakers = d.object(forKey: "labelSpeakers") as? Bool ?? true
        voiceShortcutEnabled = d.object(forKey: "voiceShortcutEnabled") as? Bool ?? true
    }

    var engineSettings: EngineSettings {
        var s = EngineSettings()
        s.kind = engineKind
        s.serverURL = serverURL
        s.serverModel = serverModel
        return s
    }
}

/// Plays the selected recording; timestamps in the UI seek it.
@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var loadedURL: URL?
    @Published var rate: Float = 1 { didSet { player?.rate = rate } }

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ url: URL?) {
        guard url != loadedURL else { return }
        stop()
        loadedURL = url
        player = nil
        currentTime = 0
        duration = 0
        guard let url, let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.enableRate = true
        p.rate = rate
        p.prepareToPlay()
        player = p
        duration = p.duration
    }

    var isAvailable: Bool { player != nil }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard let p = player else { return }
        p.play()
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
    }

    func stop() {
        pause()
        player?.currentTime = 0
        currentTime = 0
    }

    func seek(to t: TimeInterval, andPlay: Bool = true) {
        guard let p = player else { return }
        p.currentTime = max(0, min(t, p.duration))
        currentTime = p.currentTime
        if andPlay { play() }
    }

    func skip(_ delta: TimeInterval) { seek(to: currentTime + delta, andPlay: isPlaying) }

    private func tick() {
        guard let p = player else { return }
        currentTime = p.currentTime
        if !p.isPlaying { isPlaying = false; timer?.invalidate() }
    }
}
