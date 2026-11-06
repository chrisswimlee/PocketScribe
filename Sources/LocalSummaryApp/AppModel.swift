import AppKit
import AVFoundation
import Foundation
import LocalSummaryCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var recordings: [Recording] = []
    @Published var selection: Recording.ID? {
        didSet { player.load(selected.map { audioURL(for: $0) }) }
    }
    @Published var errorMessage: String?

    // Progress of the item being processed
    @Published var progress: Double?
    @Published var progressText = ""

    // Recording
    @Published var isRecording = false
    @Published var recordingStartedAt: Date?
    @Published var inputLevel: Float = 0  // 0...1

    // UI requests coming from menus / menu bar
    @Published var showImporter = false
    @Published var pendingDelete: Recording.ID?
    @Published var pendingRename: Recording.ID?

    let settings = AppSettings()
    let player = AudioPlayer()

    private let transcriber = Transcriber()
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var currentRecordingID: Recording.ID?
    private var worker: Task<Void, Never>?
    private var workingOn: Recording.ID?

    static let audioTypes: [UTType] = [.audio, .movie]

    // MARK: Storage

    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "LocalSummary", directoryHint: .isDirectory)
        for sub in ["Library", "Audio"] {
            try? FileManager.default.createDirectory(at: base.appending(path: sub), withIntermediateDirectories: true)
        }
        return base
    }()
    private var libraryDir: URL { Self.supportDir.appending(path: "Library") }
    private var audioDir: URL { Self.supportDir.appending(path: "Audio") }

    func audioURL(for r: Recording) -> URL { audioDir.appending(path: r.audioFileName) }

    var selected: Recording? { recordings.first { $0.id == selection } }

    private init() {
        load()
        // Anything interrupted by a quit goes back in the queue.
        for i in recordings.indices where recordings[i].status == .processing {
            recordings[i].status = .queued
        }
        processQueue()
    }

    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: libraryDir, includingPropertiesForKeys: nil)) ?? []
        recordings = files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Recording.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func save(_ r: Recording) {
        try? JSONEncoder().encode(r).write(to: libraryDir.appending(path: "\(r.id.uuidString).json"))
    }

    private func update(_ id: Recording.ID, _ change: (inout Recording) -> Void) {
        guard let i = recordings.firstIndex(where: { $0.id == id }) else { return }
        change(&recordings[i])
        save(recordings[i])
    }

    // MARK: Library actions

    func rename(_ id: Recording.ID, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        update(id) { $0.title = t; $0.titleIsAutomatic = false }
    }

    func delete(_ id: Recording.ID) {
        if workingOn == id { cancelProcessing() }
        guard let r = recordings.first(where: { $0.id == id }) else { return }
        if selection == id { selection = nil }
        recordings.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: libraryDir.appending(path: "\(id.uuidString).json"))
        try? FileManager.default.removeItem(at: audioURL(for: r))
    }

    func toggleAction(_ index: Int, in id: Recording.ID) {
        update(id) { r in
            if r.checkedActions.contains(index) { r.checkedActions.remove(index) } else { r.checkedActions.insert(index) }
        }
    }

    func copySummary(_ id: Recording.ID? = nil) {
        guard let r = recordings.first(where: { $0.id == (id ?? selection) }), let s = r.summary else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    func exportSelected() {
        guard let r = selected else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(r.title).md"
        if panel.runModal() == .OK, let url = panel.url {
            do { try r.markdown.write(to: url, atomically: true, encoding: .utf8) } catch { errorMessage = error.localizedDescription }
        }
    }

    // MARK: Import

    /// Copies files into the library and queues them. Non-audio files are skipped.
    func importFiles(_ urls: [URL]) {
        var added: [Recording] = []
        var skipped: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let type = UTType(filenameExtension: url.pathExtension),
                  Self.audioTypes.contains(where: { type.conforms(to: $0) }) else {
                skipped.append(url.lastPathComponent)
                continue
            }
            let id = UUID()
            let name = "\(id.uuidString).\(url.pathExtension.lowercased())"
            do {
                try FileManager.default.copyItem(at: url, to: audioDir.appending(path: name))
            } catch {
                errorMessage = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
                continue
            }
            var r = Recording(id: id, title: url.deletingPathExtension().lastPathComponent, audioFileName: name)
            r.duration = Self.duration(of: audioDir.appending(path: name))
            added.append(r)
        }
        if !skipped.isEmpty {
            errorMessage = "Skipped files that aren't audio or video: \(skipped.joined(separator: ", "))"
        }
        guard !added.isEmpty else { return }
        for r in added { save(r) }
        recordings.insert(contentsOf: added, at: 0)
        selection = added.first?.id
        processQueue()
    }

    static func duration(of url: URL) -> TimeInterval? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        return Double(f.length) / f.processingFormat.sampleRate
    }

    // MARK: Processing queue

    var isProcessing: Bool { workingOn != nil }
    func isWorking(on id: Recording.ID) -> Bool { workingOn == id }
    var queuedCount: Int { recordings.filter { $0.status == .queued }.count }

    func retry(_ id: Recording.ID) {
        update(id) { $0.status = .queued; $0.errorMessage = nil }
        processQueue()
    }

    func cancelProcessing() {
        worker?.cancel()
    }

    private func processQueue() {
        guard workingOn == nil,
              let next = recordings.filter({ $0.status == .queued }).min(by: { $0.createdAt < $1.createdAt })
        else { return }
        let id = next.id
        workingOn = id
        update(id) { $0.status = .processing; $0.errorMessage = nil }
        progress = 0
        progressText = "Starting…"
        worker = Task { [weak self] in
            await self?.run(id)
            guard let self else { return }
            self.workingOn = nil
            self.progress = nil
            self.processQueue()
        }
    }

    private func setProgress(_ value: Double?, _ text: String) {
        progress = value
        progressText = text
    }

    private func run(_ id: Recording.ID) async {
        guard let r = recordings.first(where: { $0.id == id }) else { return }
        let settings = self.settings
        do {
            // 1. Transcript (skipped on "Retry summary" when we already have one)
            if r.transcript == nil {
                try await transcriber.prepare(model: settings.asrModel) { fraction, text in
                    Task { @MainActor in self.setProgress(fraction * 0.4, text) }
                }
                try Task.checkCancellation()
                setProgress(0.45, "Transcribing…")
                let t = try await transcriber.transcribe(fileAt: audioURL(for: r), model: settings.asrModel)
                try Task.checkCancellation()
                update(id) { $0.transcript = t; $0.duration = $0.duration ?? t.audioDuration }
            }
            guard let transcript = recordings.first(where: { $0.id == id })?.transcript else { return }

            // 2. Summary
            let summarizer = Summarizer(engine: settings.engineSettings.makeEngine())
            let summary: String
            if transcript.text.isEmpty {
                summary = "_No speech detected._"
            } else {
                setProgress(0.5, "Summarizing…")
                summary = try await summarizer.summarize(transcript) { p in
                    Task { @MainActor in
                        switch p {
                        case .summarizingChunk(let i, let n):
                            self.setProgress(0.5 + 0.4 * Double(i - 1) / Double(n), "Reading part \(i) of \(n)…")
                        case .combining:
                            self.setProgress(0.9, "Writing summary…")
                        }
                    }
                }
            }
            try Task.checkCancellation()
            update(id) {
                $0.summary = summary
                $0.engineName = summarizer.engine.displayName
                $0.status = .ready
                $0.checkedActions = []
            }

            // 3. Title (best effort)
            if settings.suggestTitles, !transcript.text.isEmpty,
               recordings.first(where: { $0.id == id })?.titleIsAutomatic == true {
                setProgress(0.97, "Naming…")
                if let title = try? await summarizer.suggestTitle(for: summary), !title.isEmpty,
                   recordings.first(where: { $0.id == id })?.titleIsAutomatic == true {
                    update(id) { $0.title = title }
                }
            }
        } catch is CancellationError {
            update(id) { $0.status = .failed; $0.errorMessage = "Cancelled." }
        } catch {
            let message = Task.isCancelled ? "Cancelled." : error.localizedDescription
            update(id) { $0.status = .failed; $0.errorMessage = message }
        }
    }

    // MARK: Recording

    func toggleRecording() { isRecording ? stopRecording() : startRecording() }

    private func startRecording() {
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in
                guard granted else {
                    self.errorMessage = "Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone."
                    return
                }
                let id = UUID()
                let name = "\(id.uuidString).m4a"
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                ]
                do {
                    let r = try AVAudioRecorder(url: self.audioDir.appending(path: name), settings: settings)
                    r.isMeteringEnabled = true
                    guard r.record() else {
                        throw NSError(domain: "LocalSummary", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "Couldn't start recording."])
                    }
                    self.recorder = r
                    self.currentRecordingID = id
                    self.isRecording = true
                    self.recordingStartedAt = Date()
                    self.meterTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                        Task { @MainActor in self.updateMeter() }
                    }
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func updateMeter() {
        guard let r = recorder else { return }
        r.updateMeters()
        let db = r.averagePower(forChannel: 0)  // -160...0
        let level = max(0, min(1, (db + 50) / 50))
        inputLevel = inputLevel * 0.6 + level * 0.4
    }

    private func stopRecording() {
        guard let r = recorder, let id = currentRecordingID else { return }
        let started = recordingStartedAt ?? Date()
        r.stop()
        meterTimer?.invalidate()
        recorder = nil
        currentRecordingID = nil
        isRecording = false
        recordingStartedAt = nil
        inputLevel = 0
        var rec = Recording(id: id, title: Recording.defaultRecordingTitle(started), createdAt: started,
                            audioFileName: r.url.lastPathComponent)
        rec.duration = Self.duration(of: r.url)
        save(rec)
        recordings.insert(rec, at: 0)
        selection = id
        processQueue()
    }
}
