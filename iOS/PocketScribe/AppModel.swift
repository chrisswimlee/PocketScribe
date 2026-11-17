import AVFoundation
import EventKit
import Foundation
import PocketScribeCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var recordings: [Recording] = []
    /// Items in Recently Deleted, most recently deleted first. Kept for 30 days.
    @Published var trash: [Recording] = []
    /// The item whose text is open in the editor.
    @Published var editingID: Recording.ID?
    /// Just moved to Recently Deleted: a toast offers Undo for a few seconds.
    @Published var undoDeleteID: Recording.ID?
    /// Asks before a new summary replaces text the user edited.
    @Published var confirmRewrite: Recording.ID?
    private var pendingRewrite: (() -> Void)?
    @Published var confirmEmptyTrash = false
    /// The new-note sheet is open.
    @Published var composingNote = false
    @Published var showTrash = false
    @Published var path: [Recording.ID] = []
    @Published var errorMessage: String?
    /// A short confirmation shown at the bottom of the detail screen, e.g. "Added 3 reminders".
    @Published var notice: String?

    // Progress of the item being processed
    @Published var progress: Double?
    @Published var progressText = ""
    /// When the current job started, for the processing screen's elapsed time.
    @Published var workStartedAt: Date?

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
    /// Everything the importer accepts: audio, video and documents.
    static let importTypes: [UTType] = audioTypes + DocumentReader.contentTypes

    // MARK: Storage

    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "PocketScribe", directoryHint: .isDirectory)
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
        recoverInterruptedRecordings()
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
        let loaded = LibraryFiles.load(Recording.self, from: libraryDir)
        let all = loaded.items.sorted { $0.createdAt > $1.createdAt }
        // Recently Deleted keeps items for 30 days.
        for r in all where LibraryFiles.isExpired(deletedAt: r.deletedAt) { removeFiles(of: r) }
        recordings = all.filter { $0.deletedAt == nil }
        trash = all.filter { $0.deletedAt != nil && !LibraryFiles.isExpired(deletedAt: $0.deletedAt) }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
        errorMessage = LibraryFiles.unreadableMessage(loaded.unreadable, in: libraryDir)
    }

    /// A recording that was still going when the app quit, crashed or ran out of battery is
    /// added back to the library and transcribed. Recordings are CAF files, which stay
    /// playable up to the moment they were cut off.
    private func recoverInterruptedRecordings() {
        let known = Set((recordings + trash).map(\.audioFileName))
        let orphans = LibraryFiles.orphanRecordings(in: audioDir, known: known)
        guard !orphans.isEmpty else { return }
        for url in orphans {
            let started = LibraryFiles.creationDate(of: url)
            let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID()
            var r = Recording(id: id, title: Recording.defaultRecordingTitle(started), createdAt: started,
                              audioFileName: url.lastPathComponent)
            r.duration = Self.duration(of: url)
            save(r)
            recordings.append(r)
        }
        recordings.sort { $0.createdAt > $1.createdAt }
        let n = orphans.count
        let message = (n == 1 ? "A recording" : "\(n) recordings")
            + " stopped when Pocket Scribe quit unexpectedly. Everything up to that moment was saved and is being transcribed now."
        errorMessage = [errorMessage, message].compactMap { $0 }.joined(separator: "\n\n")
    }

    private func save(_ r: Recording) {
        do {
            try LibraryFiles.save(r, id: r.id, in: libraryDir)
        } catch {
            errorMessage = "Couldn't save “\(r.title)”: \(error.localizedDescription)"
        }
    }

    private func isSaved(_ id: Recording.ID) -> Bool {
        FileManager.default.fileExists(atPath: libraryDir.appending(path: "\(id.uuidString).json").path(percentEncoded: false))
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

    /// Moves an item to Recently Deleted, where it can be put back for 30 days.
    func delete(_ id: Recording.ID) {
        if workingOn == id { cancelProcessing() }
        guard let i = recordings.firstIndex(where: { $0.id == id }) else { return }
        var r = recordings[i]
        path.removeAll { $0 == id }
        if player.loadedURL == audioURL(for: r) { player.load(nil) }
        recordings.remove(at: i)
        if editingID == id { editingID = nil }
        // A typed note with nothing in it isn't worth keeping.
        if r.isWritten, (r.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            removeFiles(of: r)
            return
        }
        r.deletedAt = Date()
        // Put back mid-processing: it goes back in the queue.
        if r.status == .processing { r.status = .queued }
        save(r)
        trash.insert(r, at: 0)
        undoDeleteID = id
        undoTask?.cancel()
        undoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled, self?.undoDeleteID == id { self?.undoDeleteID = nil }
        }
    }
    private var undoTask: Task<Void, Never>?

    /// Puts an item from Recently Deleted back in the library.
    func restore(_ id: Recording.ID) {
        guard let i = trash.firstIndex(where: { $0.id == id }) else { return }
        var r = trash.remove(at: i)
        r.deletedAt = nil
        save(r)
        recordings.append(r)
        recordings.sort { $0.createdAt > $1.createdAt }
        if undoDeleteID == id { undoDeleteID = nil }
        processQueue()
    }

    /// Removes an item from Recently Deleted for good: its text, summary and file.
    func deleteForever(_ id: Recording.ID) {
        guard let i = trash.firstIndex(where: { $0.id == id }) else { return }
        let r = trash.remove(at: i)
        removeFiles(of: r)
    }

    func emptyTrash() {
        for r in trash { removeFiles(of: r) }
        trash.removeAll()
    }

    private func removeFiles(of r: Recording) {
        try? FileManager.default.removeItem(at: libraryDir.appending(path: "\(r.id.uuidString).json"))
        // A typed note has no file of its own: never remove the Audio folder itself.
        if !r.audioFileName.isEmpty { try? FileManager.default.removeItem(at: audioURL(for: r)) }
    }

    // MARK: Writing and editing

    /// The text the editor starts from: what the summary or note shows, with speaker names filled in.
    static func editableText(_ r: Recording) -> String {
        r.displaySummary ?? ""
    }

    /// Adds a note typed in the app and opens it.
    func addWrittenNote(title: String, body: String) {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !t.isEmpty else { return }
        var r = Recording.writtenNote()
        r.summary = text
        r.titleIsAutomatic = t.isEmpty
        r.title = t.isEmpty ? Recording.title(forNote: text, createdAt: r.createdAt) : t
        save(r)
        recordings.insert(r, at: 0)
        path = [r.id]
    }

    /// Saves the editor. The AI's first version is kept so it can be restored.
    func saveEdit(_ id: Recording.ID, title: String, body: String) {
        editingID = nil
        guard let r = recordings.first(where: { $0.id == id }) else { return }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.isWritten, text.isEmpty, newTitle.isEmpty {
            // An empty typed note: drop it rather than keep a blank page.
            recordings.removeAll { $0.id == id }
            removeFiles(of: r)
            return
        }
        update(id) { r in
            if text != Self.editableText(r) {
                if !r.isWritten, r.originalSummary == nil { r.originalSummary = r.summary }
                r.summary = text
                r.editedAt = Date()
                self.dropStaleActionMarks(&r)
            }
            if r.isWritten {
                r.titleIsAutomatic = newTitle.isEmpty
                r.title = newTitle.isEmpty ? Recording.title(forNote: text, createdAt: r.createdAt) : newTitle
            } else if !newTitle.isEmpty, newTitle != r.title {
                r.title = newTitle
                r.titleIsAutomatic = false
            }
        }
    }

    /// Closes the editor without saving. A new typed note that was never saved goes away.
    func cancelEdit() {
        guard let id = editingID else { return }
        editingID = nil
        if let r = recordings.first(where: { $0.id == id }), r.isWritten, !isSaved(id) {
            recordings.removeAll { $0.id == id }
        }
    }

    /// Goes back to the version the AI wrote, before the user's edits.
    func restoreOriginal(_ id: Recording.ID) {
        update(id) { r in
            guard let original = r.originalSummary else { return }
            r.summary = original
            r.originalSummary = nil
            r.editedAt = nil
            self.dropStaleActionMarks(&r)
        }
    }

    /// Ticks and sent marks point at action items by position; drop any past the end after an edit.
    private func dropStaleActionMarks(_ r: inout Recording) {
        let n = actionItems(of: r).count
        r.checkedActions = r.checkedActions.filter { $0 < n }
        r.sentToReminders = r.sentToReminders?.filter { $0 < n }
        r.sentToCalendar = r.sentToCalendar?.filter { $0 < n }
    }

    /// True when rewriting would replace the user's own edits, so we ask first.
    private func asksBeforeRewrite(_ id: Recording.ID, then action: @escaping () -> Void) -> Bool {
        guard recordings.first(where: { $0.id == id })?.editedAt != nil else { return false }
        pendingRewrite = action
        confirmRewrite = id
        return true
    }

    func confirmPendingRewrite() {
        let action = pendingRewrite
        pendingRewrite = nil
        confirmRewrite = nil
        action?()
    }

    func cancelPendingRewrite() {
        pendingRewrite = nil
        confirmRewrite = nil
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
    func labelSpeakers(_ id: Recording.ID, replacingEdits: Bool = false) {
        if !replacingEdits, asksBeforeRewrite(id, then: { [weak self] in self?.labelSpeakers(id, replacingEdits: true) }) { return }
        if !settings.labelSpeakers { settings.labelSpeakers = true }
        update(id) { $0.transcript = nil; $0.speakerNames = nil; $0.status = .queued; $0.errorMessage = nil }
        processQueue()
    }

    /// Rewrites a recording as a note or as a meeting summary (keeps the transcript).
    func setSummaryStyle(_ style: SummaryStyle, for id: Recording.ID, replacingEdits: Bool = false) {
        if !replacingEdits, asksBeforeRewrite(id, then: { [weak self] in self?.setSummaryStyle(style, for: id, replacingEdits: true) }) { return }
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
        // With owners shown as the names guessed from the recording, as on screen.
        return SummaryLayout.splitActions(r.displaySummary ?? s).actions
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

    func retry(_ id: Recording.ID, replacingEdits: Bool = false) {
        guard recordings.first(where: { $0.id == id })?.isWritten == false else { return }
        if !replacingEdits, asksBeforeRewrite(id, then: { [weak self] in self?.retry(id, replacingEdits: true) }) { return }
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
        workStartedAt = Date()
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
            guard let transcript = recording(id)?.transcript else { return }

            let summarizer = Summarizer(engine: settings.engineSettings.makeEngine())

            // 2. A cleaned-up note for one person's quick thought, a meeting summary for a
            //    conversation (however short) or anything long. The user can switch it.
            let style = recording(id)?.summaryStyle
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
                    $0.originalSummary = nil
                    $0.editedAt = nil
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
                $0.originalSummary = nil
                $0.editedAt = nil
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

    /// PDF, Word, PowerPoint or text: read the text (once), then write notes and a summary.
    private func runDocument(_ id: Recording.ID) async {
        guard let r = recording(id) else { return }
        let settings = self.settings
        do {
            if r.document == nil {
                setProgress(0.05, "Reading \(r.originalFileName ?? "the file")…", for: id)
                let url = audioURL(for: r)
                let doc = try await Task.detached(priority: .userInitiated) { try DocumentReader.read(url) }.value
                try Task.checkCancellation()
                if doc.isEmpty { throw DocumentError.empty("No text was found in this file.") }
                update(id) { $0.document = doc }
            }
            guard let doc = recording(id)?.document else { return }
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
                $0.originalSummary = nil
                $0.editedAt = nil
            }
            if settings.suggestTitles, recording(id)?.titleIsAutomatic == true,
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
        guard let r = recording(id) else { throw CancellationError() }
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
                // CAF, not .m4a: it stays playable if the app quits mid-recording.
                let name = "\(id.uuidString).\(LibraryFiles.recordingExtension)"
                let settings = LibraryFiles.recordingSettings
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
                    try session.setActive(true)
                    let r = try AVAudioRecorder(url: self.audioDir.appending(path: name), settings: settings)
                    r.isMeteringEnabled = true
                    guard r.record() else {
                        throw NSError(domain: "PocketScribe", code: 1,
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
        // The quick note button always makes a note; the Record button decides by what it hears.
        if quick { rec.summaryStyle = .note }
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
        // -composeNote YES / -showTrash YES / -editOpened YES (with -openID)
        if args.bool(forKey: "composeNote") { composingNote = true }
        if args.bool(forKey: "showTrash") { showTrash = true }
        if args.bool(forKey: "editOpened"), let id = path.last { editingID = id }
        #endif
    }
}
