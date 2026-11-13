import AppKit
import AVFoundation
import Foundation
import PocketScribeCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var recordings: [Recording] = []
    @Published var selection: Recording.ID? {
        didSet { player.load(selected.flatMap { $0.isDocument ? nil : audioURL(for: $0) }) }
    }
    @Published var errorMessage: String?
    /// A short confirmation shown at the bottom of the detail view, e.g. "Added 3 reminders".
    @Published var notice: String?

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
    /// Everything the importer and drag and drop accept: audio, video and documents.
    static let importTypes: [UTType] = audioTypes + DocumentReader.contentTypes

    // MARK: Storage

    static let supportDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = appSupport.appending(path: "PocketScribe", directoryHint: .isDirectory)
        // Earlier builds were called LocalSummary, then PocketPad: carry the library over on first launch.
        for oldName in ["PocketPad", "LocalSummary"] where !FileManager.default.fileExists(atPath: base.path) {
            let old = appSupport.appending(path: oldName, directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: old.path) {
                try? FileManager.default.moveItem(at: old, to: base)
            }
        }
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
        GlobalHotKey.shared.onPress = { [weak self] in self?.voiceShortcutPressed() }
        GlobalHotKey.shared.onRelease = { [weak self] in self?.voiceShortcutReleased() }
        DispatchQueue.main.async { self.applyVoiceShortcut() }
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

    // MARK: Speakers

    func renameSpeaker(_ speaker: Int, to name: String, in id: Recording.ID) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) { r in
            var names = r.speakerNames ?? [:]
            names[speaker] = (t.isEmpty || t == Speakers.defaultName(speaker)) ? nil : t
            r.speakerNames = names.isEmpty ? nil : names
        }
    }

    /// Transcribes again with speaker labels (for recordings made before labels existed),
    /// then writes a new summary that can say who does what.
    func labelSpeakers(_ id: Recording.ID) {
        if !settings.labelSpeakers { settings.labelSpeakers = true }
        update(id) { $0.transcript = nil; $0.speakerNames = nil; $0.status = .queued; $0.errorMessage = nil }
        processQueue()
    }

    /// Rewrites a recording as a note or as a meeting summary (keeps the transcript).
    func setSummaryStyle(_ style: SummaryStyle, for id: Recording.ID) {
        update(id) { r in
            r.summaryStyle = style
            // Notes made before speakers were labeled on short recordings: label them now,
            // so the meeting summary can say who does what.
            if style == .meeting, settings.labelSpeakers, let t = r.transcript, t.speakers.isEmpty,
               t.audioDuration >= Speakers.minimumDuration {
                r.transcript = nil
                r.speakerNames = nil
            }
            r.status = .queued
            r.errorMessage = nil
        }
        processQueue()
    }

    /// Uses the speaker names guessed from the conversation ("I'm Maria").
    func acceptSuggestedNames(_ names: [Int: String], in id: Recording.ID) {
        update(id) { r in
            var all = r.speakerNames ?? [:]
            for (n, name) in names where (all[n] ?? "").isEmpty { all[n] = name }
            r.speakerNames = all.isEmpty ? nil : all
            r.nameSuggestionsDismissed = true
        }
    }

    func dismissNameSuggestions(in id: Recording.ID) {
        update(id) { $0.nameSuggestionsDismissed = true }
    }

    // MARK: Action items → Reminders / Calendar

    /// Action item lines of a recording: the "Action items" section, or a voice note's tasks.
    func actionItems(of r: Recording) -> [String] {
        guard let s = r.summary else { return [] }
        if r.noteKind != nil {
            return SummaryLayout.noteBlocks(s).compactMap { if case .task(_, let t) = $0 { return t } else { return nil } }
        }
        return SummaryLayout.splitActions(s).actions
    }

    func sendToReminders(_ indices: [Int], in id: Recording.ID) {
        guard let r = recordings.first(where: { $0.id == id }) else { return }
        let lines = actionItems(of: r)
        let picked = indices.filter { $0 < lines.count }
        guard !picked.isEmpty else { return }
        let items = picked.map { ActionItem(lines[$0], speakerNames: r.speakerNames) }
        Task {
            do {
                let n = try await ActionItemSender.shared.addReminders(items, from: r.title)
                update(id) { $0.sentToReminders = ($0.sentToReminders ?? []).union(picked) }
                showNotice(n == 1 ? "Added to Reminders: \(items[0].title)" : "Added \(n) reminders")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func addToCalendar(_ index: Int, in id: Recording.ID) {
        guard let r = recordings.first(where: { $0.id == id }) else { return }
        let lines = actionItems(of: r)
        guard index < lines.count else { return }
        let item = ActionItem(lines[index], speakerNames: r.speakerNames)
        Task {
            do {
                let start = try await ActionItemSender.shared.addEvent(item, from: r.title)
                update(id) { $0.sentToCalendar = ($0.sentToCalendar ?? []).union([index]) }
                showNotice("Added to Calendar, \(start.formatted(date: .abbreviated, time: .shortened))")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var noticeTask: Task<Void, Never>?
    func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self?.notice = nil }
        }
    }

    func copySummary(_ id: Recording.ID? = nil) {
        guard let r = recordings.first(where: { $0.id == (id ?? selection) }), let s = r.summary else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Speakers.apply(r.speakerNames, to: s), forType: .string)
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

    /// Copies files into the library and queues them. Audio and video get transcribed;
    /// PDFs, Word files, slide decks and text files get read. Anything else is skipped.
    func importFiles(_ urls: [URL]) {
        var added: [Recording] = []
        var skipped: [String] = []
        var problems: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let why = DocumentReader.unsupportedReason(fileName: url.lastPathComponent) {
                problems.append(why)
                continue
            }
            let isDocument = DocumentReader.canRead(fileName: url.lastPathComponent)
            guard isDocument || UTType(filenameExtension: url.pathExtension).map({ type in
                Self.audioTypes.contains(where: { type.conforms(to: $0) }) }) == true else {
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
            r.originalFileName = url.lastPathComponent
            if isDocument {
                // A document's file name usually says what it is, so keep it as the title.
                r.titleIsAutomatic = false
            } else {
                r.duration = Self.duration(of: audioDir.appending(path: name))
            }
            added.append(r)
        }
        if !skipped.isEmpty {
            problems.append("Skipped files that aren't audio, video, PDF, Word, PowerPoint or text: \(skipped.joined(separator: ", "))")
        }
        if !problems.isEmpty { errorMessage = problems.joined(separator: "\n\n") }
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

    private func setProgress(_ value: Double?, _ text: String, for id: Recording.ID? = nil) {
        // Late callbacks from a finished/cancelled job must not overwrite the next job's progress.
        if let id, id != workingOn { return }
        progress = value
        progressText = text
    }

    private func run(_ id: Recording.ID) async {
        guard let r = recordings.first(where: { $0.id == id }) else { return }
        let settings = self.settings
        if r.isDocument { await runDocument(id); return }
        do {
            // 1. Transcript (skipped on "Retry summary" when we already have one)
            if r.transcript == nil {
                try await transcriber.prepare(model: settings.asrModel) { fraction, text in
                    Task { @MainActor in self.setProgress(fraction * 0.4, text, for: id) }
                }
                try Task.checkCancellation()
                setProgress(0.42, "Preparing audio…")
                let audio = try await readableAudio(for: id)
                try Task.checkCancellation()
                setProgress(0.45, "Transcribing…")
                let t = try await transcriber.transcribe(
                    fileAt: audio, model: settings.asrModel, labelSpeakers: settings.labelSpeakers
                ) { text in
                    Task { @MainActor in self.setProgress(0.47, text, for: id) }
                }
                try Task.checkCancellation()
                update(id) {
                    $0.transcript = t
                    $0.duration = $0.duration ?? t.audioDuration
                    $0.speakerNames = nil
                    $0.nameSuggestionsDismissed = nil
                }
            }
            guard let transcript = recordings.first(where: { $0.id == id })?.transcript else { return }

            let summarizer = Summarizer(engine: settings.engineSettings.makeEngine())

            // 2. A cleaned-up note for one person's quick thought, a meeting summary for a
            //    conversation (however short) or anything long. The user can switch it.
            let style = recordings.first(where: { $0.id == id })?.summaryStyle
            let willNote = !transcript.text.isEmpty && (style ?? Summarizer.automaticStyle(for: transcript)) == .note
            setProgress(willNote ? 0.6 : 0.5, willNote ? "Writing your note…" : "Summarizing…")
            let written = try await summarizer.write(transcript, style: style) { p in
                Task { @MainActor in
                    switch p {
                    case .summarizingChunk(let i, let n):
                        self.setProgress(0.5 + 0.4 * Double(i - 1) / Double(n), "Reading part \(i) of \(n)…", for: id)
                    case .combining:
                        self.setProgress(0.9, "Writing summary…", for: id)
                    }
                }
            }
            try Task.checkCancellation()
            let summary: String
            switch written {
            case .note(let note):
                update(id) {
                    $0.summary = note.body
                    $0.noteKind = note.kind
                    $0.tags = note.tags
                    $0.engineName = summarizer.engine.displayName
                    $0.status = .ready
                    $0.checkedActions = []
                    $0.sentToReminders = nil
                    $0.sentToCalendar = nil
                    if $0.titleIsAutomatic, settings.suggestTitles, !note.title.isEmpty { $0.title = note.title }
                }
                return
            case .meeting(let s):
                summary = s
            }
            update(id) {
                $0.summary = summary
                $0.noteKind = nil
                $0.tags = nil
                $0.engineName = summarizer.engine.displayName
                $0.status = .ready
                $0.checkedActions = []
                $0.sentToReminders = nil
                $0.sentToCalendar = nil
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

    /// PDF, Word, PowerPoint or text: read the text (once), then write notes and a summary.
    private func runDocument(_ id: Recording.ID) async {
        guard let r = recordings.first(where: { $0.id == id }) else { return }
        let settings = self.settings
        do {
            if r.document == nil {
                setProgress(0.05, "Reading \(r.originalFileName ?? "the file")…", for: id)
                let url = audioURL(for: r)
                let doc = try await Task.detached(priority: .userInitiated) { try DocumentReader.read(url) }.value
                try Task.checkCancellation()
                if doc.isEmpty {
                    throw DocumentError.empty("No text was found in this file.")
                }
                update(id) { $0.document = doc }
            }
            guard let doc = recordings.first(where: { $0.id == id })?.document else { return }
            let summarizer = Summarizer(engine: settings.engineSettings.makeEngine())
            setProgress(0.2, "Writing notes…", for: id)
            let summary = try await summarizer.summarize(document: doc) { p in
                Task { @MainActor in
                    switch p {
                    case .summarizingChunk(let i, let n):
                        self.setProgress(0.2 + 0.7 * Double(i - 1) / Double(n), "Reading part \(i) of \(n)…", for: id)
                    case .combining:
                        self.setProgress(0.92, "Writing summary…", for: id)
                    }
                }
            }
            try Task.checkCancellation()
            update(id) {
                $0.summary = summary
                $0.noteKind = nil
                $0.engineName = summarizer.engine.displayName
                $0.status = .ready
                $0.checkedActions = []
                $0.sentToReminders = nil
                $0.sentToCalendar = nil
            }
            if settings.suggestTitles, recordings.first(where: { $0.id == id })?.titleIsAutomatic == true,
               let title = try? await summarizer.suggestTitle(for: summary), !title.isEmpty {
                update(id) { $0.title = title }
            }
        } catch is CancellationError {
            update(id) { $0.status = .failed; $0.errorMessage = "Cancelled." }
        } catch {
            let message = Task.isCancelled ? "Cancelled." : error.localizedDescription
            update(id) { $0.status = .failed; $0.errorMessage = message }
        }
    }

    /// Video files (and some containers) can't be read by AVAudioFile. Extract their audio
    /// track to .m4a once, and use that for both transcription and playback.
    private func readableAudio(for id: Recording.ID) async throws -> URL {
        guard let r = recordings.first(where: { $0.id == id }) else { throw CancellationError() }
        let url = audioURL(for: r)
        if (try? AVAudioFile(forReading: url)) != nil { return url }
        let outName = "\(id.uuidString)-audio.m4a"
        let out = audioDir.appending(path: outName)
        try? FileManager.default.removeItem(at: out)
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: url), presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "PocketScribe", code: 2, userInfo: [NSLocalizedDescriptionKey: "This file has no audio track that can be read."])
        }
        try await export.export(to: out, as: .m4a)
        try? FileManager.default.removeItem(at: url)
        update(id) { $0.audioFileName = outName; $0.duration = Self.duration(of: out) }
        if selection == id { player.load(out) }
        return out
    }

    // MARK: Voice shortcut (tap to start/stop, or hold to talk)

    private var shortcutDownAt: Date?
    private var recordingFromShortcut = false

    func applyVoiceShortcut() {
        if settings.voiceShortcutEnabled { GlobalHotKey.shared.register() } else { GlobalHotKey.shared.unregister() }
    }

    private func voiceShortcutPressed() {
        if isRecording {
            shortcutDownAt = nil
            stopRecording()
        } else {
            shortcutDownAt = Date()
            recordingFromShortcut = true
            pendingStopAfterStart = false
            startRecording()
        }
    }

    private func voiceShortcutReleased() {
        guard let down = shortcutDownAt else { return }
        shortcutDownAt = nil
        // Held longer than half a second: push-to-talk, so releasing stops.
        if Date().timeIntervalSince(down) > 0.5 {
            if isRecording { stopRecording() } else { pendingStopAfterStart = true }
        }
    }

    /// Release arrived before the recorder finished starting (permission prompt etc.).
    private var pendingStopAfterStart = false

    // MARK: Recording

    func toggleRecording() {
        if isRecording { stopRecording() } else { recordingFromShortcut = false; pendingStopAfterStart = false; startRecording() }
    }

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
                        throw NSError(domain: "PocketScribe", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "Couldn't start recording."])
                    }
                    self.recorder = r
                    self.currentRecordingID = id
                    self.isRecording = true
                    self.recordingStartedAt = Date()
                    self.meterTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                        Task { @MainActor in self.updateMeter() }
                    }
                    if self.recordingFromShortcut { ListeningHUD.shared.show(model: self) }
                    if self.pendingStopAfterStart { self.pendingStopAfterStart = false; self.stopRecording() }
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
        let tooShort = (rec.duration ?? 0) < 0.6
        if recordingFromShortcut {
            recordingFromShortcut = false
            ListeningHUD.shared.hide(after: tooShort ? 0 : 1.4)
        }
        // An accidental tap of the shortcut: discard instead of cluttering the library.
        if tooShort {
            try? FileManager.default.removeItem(at: r.url)
            return
        }
        save(rec)
        recordings.insert(rec, at: 0)
        selection = id
        processQueue()
    }
}
