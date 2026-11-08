import AVFoundation
import EventKit
import Foundation
import LocalSummaryCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var recordings: [Recording] = []
    @Published var path: [Recording.ID] = []
    @Published var errorMessage: String?
    /// A short confirmation shown at the bottom of the detail screen, e.g. "Added 3 reminders".
    @Published var notice: String?

    // Progress of the item being processed
    @Published var progress: Double?
    @Published var progressText = ""

    // Recording
    @Published var isRecording = false
    /// A quick voice note (from the mic button, Siri, Shortcuts or the Action button), not a long recording.
    @Published var isQuickNote = false
    @Published var recordingStartedAt: Date?
    @Published var inputLevel: Float = 0  // 0...1
    @Published var levelHistory: [Float] = Array(repeating: 0, count: 48)

    @Published var showImporter = false
    @Published var showSettings = false

    let settings = AppSettings()
    let player = AudioPlayer()

    private let transcriber = Transcriber()
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var currentRecordingID: Recording.ID?
    private var worker: Task<Void, Never>?
    private var workingOn: Recording.ID?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    static let audioTypes: [UTType] = [.audio, .movie]

    // MARK: Storage

    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "LocalNotes", directoryHint: .isDirectory)
        for sub in ["Library", "Audio"] {
            try? FileManager.default.createDirectory(at: base.appending(path: sub), withIntermediateDirectories: true)
        }
        return base
    }()
    private var libraryDir: URL { Self.supportDir.appending(path: "Library") }
    private var audioDir: URL { Self.supportDir.appending(path: "Audio") }

    func audioURL(for r: Recording) -> URL { audioDir.appending(path: r.audioFileName) }
    func recording(_ id: Recording.ID) -> Recording? { recordings.first { $0.id == id } }

    private init() {
        load()
        // Anything interrupted when the app was closed goes back in the queue.
        for i in recordings.indices where recordings[i].status == .processing {
            recordings[i].status = .queued
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            // A phone call or Siri took the mic: keep what was recorded so far.
            if type == .began { Task { @MainActor in self?.stopRecording() } }
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
        guard let r = recording(id) else { return }
        path.removeAll { $0 == id }
        if player.loadedURL == audioURL(for: r) { player.load(nil) }
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
        guard let r = recording(id) else { return }
        let lines = actionItems(of: r)
        let picked = indices.filter { $0 < lines.count }
        guard !picked.isEmpty else { return }
        let items = picked.map { ActionItem(lines[$0], speakerNames: r.speakerNames) }
        Task {
            do {
                let n = try await ActionItemSender.shared.addReminders(items, from: r.title)
                update(id) { $0.sentToReminders = ($0.sentToReminders ?? []).union(picked) }
                showNotice(n == 1 ? "Added to Reminders" : "Added \(n) reminders")
            } catch {
                errorMessage = error.localizedDescription
                    .replacingOccurrences(of: "System Settings › Privacy & Security", with: "Settings › Privacy & Security")
            }
        }
    }

    /// An unsaved event for the system event editor, where the user picks the time and saves.
    func draftEvent(_ index: Int, in id: Recording.ID) -> EKEvent? {
        guard let r = recording(id) else { return nil }
        let lines = actionItems(of: r)
        guard index < lines.count else { return nil }
        return ActionItemSender.shared.draftEvent(ActionItem(lines[index], speakerNames: r.speakerNames), from: r.title)
    }

    func markAddedToCalendar(_ index: Int, in id: Recording.ID) {
        update(id) { $0.sentToCalendar = ($0.sentToCalendar ?? []).union([index]) }
        showNotice("Added to Calendar")
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

    /// A Markdown file of the summary and transcript, for the share sheet.
    func exportFile(for r: Recording) -> URL {
        let safe = r.title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        let url = FileManager.default.temporaryDirectory.appending(path: "\(safe).md")
        try? r.markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
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
        if added.count == 1, let id = added.first?.id { path = [id] }
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

    func cancelProcessing() { worker?.cancel() }

    private func processQueue() {
        guard workingOn == nil,
              let next = recordings.filter({ $0.status == .queued }).min(by: { $0.createdAt < $1.createdAt })
        else { endBackgroundTask(); return }
        let id = next.id
        workingOn = id
        update(id) { $0.status = .processing; $0.errorMessage = nil }
        progress = 0
        progressText = "Starting…"
        beginBackgroundTask()
        worker = Task { [weak self] in
            await self?.run(id)
            guard let self else { return }
            self.workingOn = nil
            self.progress = nil
            self.processQueue()
        }
    }

    /// Asks iOS for extra time so a job started just before leaving the app can finish.
    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Transcribe") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func setProgress(_ value: Double?, _ text: String, for id: Recording.ID? = nil) {
        // Late callbacks from a finished/cancelled job must not overwrite the next job's progress.
        if let id, id != workingOn { return }
        progress = value
        progressText = text
    }

    private func run(_ id: Recording.ID) async {
        guard let r = recording(id) else { return }
        let settings = self.settings
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
                }
            }
            guard let transcript = recording(id)?.transcript else { return }

            let summarizer = Summarizer(engine: settings.engineSettings.makeEngine())

            // 2a. Short recordings: clean up into a voice note instead of summarizing.
            if !transcript.text.isEmpty, transcript.audioDuration < Summarizer.voiceNoteMaxDuration {
                setProgress(0.6, "Writing your note…")
                let note = try await summarizer.voiceNote(from: transcript)
                try Task.checkCancellation()
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
            }

            // 2b. Longer recordings: meeting-style summary.
            let summary: String
            if transcript.text.isEmpty {
                summary = "_No speech detected._"
            } else {
                setProgress(0.5, "Summarizing…")
                summary = try await summarizer.summarize(transcript) { p in
                    Task { @MainActor in
                        switch p {
                        case .summarizingChunk(let i, let n):
                            self.setProgress(0.5 + 0.4 * Double(i - 1) / Double(n), "Reading part \(i) of \(n)…", for: id)
                        case .combining:
                            self.setProgress(0.9, "Writing summary…", for: id)
                        }
                    }
                }
            }
            try Task.checkCancellation()
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
            if settings.suggestTitles, !transcript.text.isEmpty, recording(id)?.titleIsAutomatic == true {
                setProgress(0.97, "Naming…")
                if let title = try? await summarizer.suggestTitle(for: summary), !title.isEmpty,
                   recording(id)?.titleIsAutomatic == true {
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

    /// Video files (and some containers) can't be read by AVAudioFile. Extract their audio
    /// track to .m4a once, and use that for both transcription and playback.
    private func readableAudio(for id: Recording.ID) async throws -> URL {
        guard let r = recording(id) else { throw CancellationError() }
        let url = audioURL(for: r)
        if (try? AVAudioFile(forReading: url)) != nil { return url }
        let outName = "\(id.uuidString)-audio.m4a"
        let out = audioDir.appending(path: outName)
        try? FileManager.default.removeItem(at: out)
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: url), presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "LocalNotes", code: 2, userInfo: [NSLocalizedDescriptionKey: "This file has no audio track that can be read."])
        }
        try await export.export(to: out, as: .m4a)
        try? FileManager.default.removeItem(at: url)
        update(id) { $0.audioFileName = outName; $0.duration = Self.duration(of: out) }
        return out
    }

    // MARK: Recording

    /// Hold-to-talk: the release came before the recorder finished starting (permission prompt etc.).
    private var pendingStopAfterStart = false

    func toggleRecording(quick: Bool = false) {
        if isRecording { stopRecording() } else { startRecording(quick: quick) }
    }

    /// Hold-to-talk on the quick note button.
    func holdBegan() {
        guard !isRecording else { return }
        pendingStopAfterStart = false
        startRecording(quick: true)
    }

    func holdEnded() {
        if isRecording { stopRecording() } else { pendingStopAfterStart = true }
    }

    func startRecording(quick: Bool) {
        guard !isRecording else { return }
        player.pause()
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in
                guard granted else {
                    self.errorMessage = "Microphone access is off. Turn it on in Settings › Privacy & Security › Microphone."
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
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
                    try session.setActive(true)
                    let r = try AVAudioRecorder(url: self.audioDir.appending(path: name), settings: settings)
                    r.isMeteringEnabled = true
                    guard r.record() else {
                        throw NSError(domain: "LocalNotes", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "Couldn't start recording."])
                    }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    self.recorder = r
                    self.currentRecordingID = id
                    self.isQuickNote = quick
                    self.isRecording = true
                    self.recordingStartedAt = Date()
                    self.levelHistory = Array(repeating: 0, count: self.levelHistory.count)
                    self.meterTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                        Task { @MainActor in self.updateMeter() }
                    }
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
        levelHistory.removeFirst()
        levelHistory.append(inputLevel)
    }

    /// Stops and discards the current recording.
    func discardRecording() {
        guard let r = recorder else { return }
        r.stop()
        r.deleteRecording()
        resetRecorder()
    }

    func stopRecording() {
        guard let r = recorder, let id = currentRecordingID else { return }
        let started = recordingStartedAt ?? Date()
        let quick = isQuickNote
        r.stop()
        resetRecorder()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        var rec = Recording(id: id, title: Recording.defaultRecordingTitle(started), createdAt: started,
                            audioFileName: r.url.lastPathComponent)
        rec.duration = Self.duration(of: r.url)
        // An accidental tap: discard instead of cluttering the library.
        if (rec.duration ?? 0) < 0.6 {
            try? FileManager.default.removeItem(at: r.url)
            return
        }
        save(rec)
        recordings.insert(rec, at: 0)
        // Long recordings open their page; quick notes stay in the list so you can keep going.
        if !quick { path = [id] }
        processQueue()
    }

    private func resetRecorder() {
        meterTimer?.invalidate()
        recorder = nil
        currentRecordingID = nil
        isRecording = false
        isQuickNote = false
        recordingStartedAt = nil
        inputLevel = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Debug hooks for simulator testing

    func applyLaunchArguments() {
        #if DEBUG
        let args = UserDefaults.standard
        if let p = args.string(forKey: "importPath") {
            let url = URL(filePath: p)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
               !recordings.contains(where: { $0.title == url.deletingPathExtension().lastPathComponent }) {
                importFiles([url])
            }
        }
        if args.bool(forKey: "openFirst"), let first = recordings.first { path = [first.id] }
        if let s = args.string(forKey: "openID"), let id = UUID(uuidString: s), let r = recording(id) {
            path = [id]
            // -sendToReminders YES: sends the opened recording's action items (grant access with simctl privacy first).
            if args.bool(forKey: "sendToReminders") { sendToReminders(Array(actionItems(of: r).indices), in: id) }
        }
        if args.bool(forKey: "openSettings") { showSettings = true }
        #endif
    }
}
