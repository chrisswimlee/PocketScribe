import EventKit
import EventKitUI
import PocketScribeCore
import MarkdownUI
import SwiftUI

struct DetailView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: AudioPlayer
    let id: Recording.ID

    enum Tab: String, CaseIterable { case summary = "Summary", transcript = "Transcript" }
    @State private var tab: Tab = Self.initialTab

    private static var initialTab: Tab {
        #if DEBUG
        // Test hook: -detailTab transcript
        if UserDefaults.standard.string(forKey: "detailTab") == "transcript" { return .transcript }
        #endif
        return .summary
    }
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var confirmDelete = false
    /// A page or slide tapped in the notes ("p. 3"), shown and highlighted in the Text tab.
    @State private var pageTarget: Int?
    /// False once the full player has scrolled off screen; a compact bar then stays at the bottom.
    @State private var playerOnScreen = true

    var body: some View {
        if let r = model.recording(id) {
            content(r)
                .onAppear { player.load(r.isDocument ? nil : model.audioURL(for: r)) }
                .onChange(of: r.audioFileName) { player.load(r.isDocument ? nil : model.audioURL(for: r)) }
                .onDisappear { player.pause() }
        } else {
            ContentUnavailableView("Recording deleted", systemImage: "trash")
        }
    }

    private func content(_ r: Recording) -> some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(r)
                if player.isAvailable {
                    PlayerControls().padding(.vertical, 4)
                        .onScrollVisibilityChange(threshold: 0.2) { playerOnScreen = $0 }
                }
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) {
                        Text($0 == .transcript && r.isDocument ? "Text" : $0.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                switch tab {
                case .summary: summarySection(r)
                case .transcript:
                    if let doc = r.document { DocumentTextSection(document: doc, highlighted: pageTarget) } else { TranscriptSection(recording: r) }
                }
            }
            .padding()
        }
        .onChange(of: pageTarget) { _, n in
            guard let n else { return }
            DispatchQueue.main.async { withAnimation { proxy.scrollTo("page-\(n)", anchor: .top) } }
        }
        #if DEBUG
        // Test hook: -scrollTo actions
        .onAppear {
            if let target = UserDefaults.standard.string(forKey: "scrollTo") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { proxy.scrollTo(target, anchor: .top) }
            }
        }
        #endif
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showMiniPlayer {
                MiniPlayer()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: playerOnScreen)
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 4, y: 2)
                    .padding(.bottom, showMiniPlayer ? 76 : 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: model.notice)
        // The big title is in the header, so the bar stays clean.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.openURL, OpenURLAction { url in
            if let s = SummaryLayout.seekSeconds(url) { player.seek(to: s); return .handled }
            // "p. 3" / "slide 7" in a document's notes open that page in the Text tab.
            if let n = SourceLinker.pageNumber(url) {
                tab = .transcript
                pageTarget = nil
                DispatchQueue.main.async { pageTarget = n }
                return .handled
            }
            return .systemAction
        })
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: model.exportFile(for: r), preview: SharePreview(r.title)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(r.summary == nil && r.transcript == nil && r.document == nil)
            }
            ToolbarItem(placement: .topBarTrailing) { menu(r) }
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Save") { model.rename(r.id, to: newTitle) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(r.title)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.delete(r.id) }
        } message: {
            Text(r.isDocument ? "The file, its text and summary are removed from this iPhone."
                 : "The audio, transcript and summary are removed from this iPhone.")
        }
    }

    private var showMiniPlayer: Bool { player.isAvailable && !playerOnScreen }

    private func menu(_ r: Recording) -> some View {
        Menu {
            Button { newTitle = r.title; renaming = true } label: { Label("Rename", systemImage: "pencil") }
            if let s = r.summary {
                Button { UIPasteboard.general.string = Speakers.apply(r.speakerNames, to: s) } label: { Label("Copy summary", systemImage: "doc.on.doc") }
            }
            if let t = r.transcript {
                Button { UIPasteboard.general.string = r.speakerNames == nil && t.speakers.isEmpty ? t.text : t.timestampedText(speakerNames: r.speakerNames) } label: { Label("Copy transcript", systemImage: "text.quote") }
            }
            if !r.isDocument, r.transcript?.text.isEmpty == false, r.status == .ready || r.status == .failed {
                if r.noteKind != nil {
                    Button { model.setSummaryStyle(.meeting, for: r.id) } label: {
                        Label("Show as meeting summary", systemImage: "person.2")
                    }
                } else {
                    Button { model.setSummaryStyle(.note, for: r.id) } label: {
                        Label("Show as note", systemImage: "note.text")
                    }
                }
            }
            if r.status == .ready || r.status == .failed {
                Button { model.retry(r.id) } label: {
                    Label(r.transcript == nil && !r.isDocument ? "Transcribe again" : "Summarize again", systemImage: "arrow.clockwise")
                }
            }
            Divider()
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }

    private func header(_ r: Recording) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(r.title).font(.title2.weight(.bold))
            HStack(spacing: 6) {
                Text(r.createdAt.formatted(date: .abbreviated, time: .shortened))
                if let d = r.duration { Text("·"); Text(formatTimestamp(d)).monospacedDigit() }
                if let doc = r.document { Text("·"); Label(doc.sizeDescription, systemImage: doc.kind.symbol) }
            }
            .font(.subheadline).foregroundStyle(.secondary)
            if r.noteKind != nil || !(r.tags ?? []).isEmpty {
                HStack(spacing: 6) {
                    if let kind = r.noteKind {
                        Label(kind.label, systemImage: kind.symbol)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.tint.opacity(0.15), in: Capsule())
                    }
                    ForEach(r.tags ?? [], id: \.self) { tag in
                        Text("#\(tag)").font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
    }

    @ViewBuilder private func summarySection(_ r: Recording) -> some View {
        switch r.status {
        case .ready:
            if r.noteKind == nil { NameSuggestionCard(recording: r) }
            if let s = r.summary { SummaryBody(recording: r, summary: s) }
            if let e = r.engineName {
                Text("Written on this device by \(e)").font(.caption).foregroundStyle(.tertiary).padding(.top, 8)
            }
        case .queued:
            ProgressRow(text: "Waiting for the recording ahead of it…", value: nil)
        case .processing:
            if model.isWorking(on: r.id) {
                VStack(alignment: .leading, spacing: 10) {
                    ProgressRow(text: model.progressText, value: model.progress)
                    Button("Cancel", role: .cancel) { model.cancelProcessing() }.font(.subheadline)
                }
            }
        case .failed:
            VStack(alignment: .leading, spacing: 10) {
                Label(r.errorMessage ?? "Something went wrong.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                if r.transcript != nil {
                    Text("The transcript is saved. You can read it in the Transcript tab.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if r.document != nil {
                    Text("The text is saved. You can read it in the Text tab.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button { model.retry(r.id) } label: {
                    Label(r.transcript == nil && r.document == nil ? "Try again" : "Try the summary again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

private struct ProgressRow: View {
    let text: String
    let value: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let value { ProgressView(value: value) } else { ProgressView().frame(maxWidth: .infinity, alignment: .leading) }
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Player

struct PlayerControls: View {
    @EnvironmentObject var player: AudioPlayer

    var body: some View {
        VStack(spacing: 6) {
            Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0, andPlay: player.isPlaying) }),
                   in: 0...max(player.duration, 0.1))
                .accessibilityLabel("Position")
            HStack {
                Text(formatTimestamp(player.currentTime)).monospacedDigit()
                Spacer()
                Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                    .accessibilityLabel("Back 15 seconds")
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 44))
                        .foregroundStyle(.tint)
                }
                .padding(.horizontal, 18)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
                    .accessibilityLabel("Forward 15 seconds")
                Spacer()
                Menu {
                    ForEach([0.75, 1, 1.25, 1.5, 2] as [Float], id: \.self) { r in
                        Button("\(r.formatted())×") { player.rate = r }
                    }
                } label: {
                    Text("\(player.rate.formatted())×").monospacedDigit().frame(minWidth: 40, alignment: .trailing)
                }
                .accessibilityLabel("Playback speed")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
        }
    }
}

/// A slim bar pinned to the bottom while the full player is scrolled out of view, so audio
/// started from a time deep in the summary can always be paused or followed.
struct MiniPlayer: View {
    @EnvironmentObject var player: AudioPlayer

    var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: min(player.currentTime, player.duration), total: max(player.duration, 0.1))
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .accessibilityHidden(true)
            HStack(spacing: 4) {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Text("\(formatTimestamp(player.currentTime)) / \(formatTimestamp(player.duration))")
                    .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button { player.skip(-15) } label: {
                    Image(systemName: "gobackward.15").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Back 15 seconds")
                Button { player.skip(15) } label: {
                    Image(systemName: "goforward.15").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Forward 15 seconds")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
        }
        .background(.bar)
    }
}

/// "Speaker 1 might be Maria…" with a button to use the names, guessed from people introducing
/// themselves or being addressed in the recording.
struct NameSuggestionCard: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording

    var body: some View {
        let names = recording.nameSuggestionsDismissed == true ? [:]
            : Speakers.pendingSuggestions(in: recording.transcript, names: recording.speakerNames)
        if !names.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label(Speakers.suggestionSentence(names), systemImage: "person.crop.circle.badge.questionmark")
                    .font(.subheadline)
                Text("Based on what people said in the recording.")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button(names.count == 1 ? "Use name" : "Use names") { model.acceptSuggestedNames(names, in: recording.id) }
                        .buttonStyle(.borderedProminent)
                    Button("Not now") { model.dismissNameSuggestions(in: recording.id) }
                        .buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Summary

/// Renders the summary as Markdown, with the action items (or a note's tasks) as real, saved
/// checkboxes, and every [mm:ss] turned into a link that plays the audio from there.
/// Each item can go to Reminders or Calendar.
struct SummaryBody: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    let summary: String
    @State private var eventDraft: EventDraft?

    /// The summary with any renamed speakers ("Speaker 2" → "Maria").
    private var text: String { Speakers.apply(recording.speakerNames, to: summary) }

    var body: some View {
        Group {
            if recording.noteKind != nil { noteBody } else { summaryBody }
        }
        .sheet(item: $eventDraft) { draft in
            EventEditor(event: draft.event, store: ActionItemSender.shared.store) { saved in
                if saved { model.markAddedToCalendar(draft.index, in: recording.id) }
                eventDraft = nil
            }
            .ignoresSafeArea()
        }
    }

    private var noteBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(SummaryLayout.noteBlocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let t): md(t)
                case .task(let i, let t): checkbox(i, t)
                }
            }
        }
        .textSelection(.enabled)
    }

    private var summaryBody: some View {
        let parts = SummaryLayout.splitActions(text)
        let unsent = parts.actions.indices.filter { recording.sentToReminders?.contains($0) != true }
        return VStack(alignment: .leading, spacing: 14) {
            if !parts.before.isEmpty { md(parts.before) }
            if !parts.actions.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text("Action items").font(.title3.weight(.semibold))
                    Spacer()
                    if !unsent.isEmpty {
                        Button {
                            model.sendToReminders(unsent, in: recording.id)
                        } label: {
                            Label(unsent.count == parts.actions.count ? "Add all to Reminders" : "Add \(unsent.count) to Reminders",
                                  systemImage: "checklist")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.top, 6)
                .id("actions")
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(parts.actions.enumerated()), id: \.offset) { i, item in checkbox(i, item) }
                }
            }
            if !parts.after.isEmpty { md(parts.after) }
            sourcesNote
        }
        .textSelection(.enabled)
    }

    /// Says whether every point links back to the recording or document, so the reader knows
    /// what they can check and which points to double-check.
    @ViewBuilder private var sourcesNote: some View {
        let c = SourceLinker.coverage(of: text)
        let source = recording.isDocument ? (recording.document?.kind == .slides ? "slide" : "page") : "moment"
        let what = recording.isDocument ? "the document" : "the recording"
        if c.linked > 0 {
            Divider().padding(.top, 4)
            if c.unlinked == 0 {
                Label("Every point links to the \(source) it came from. Tap a \(recording.isDocument ? "page number" : "time") to check it.",
                      systemImage: "checkmark.seal")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Label("\(c.unlinked) point\(c.unlinked == 1 ? "" : "s") without a link couldn't be found in \(what). Double-check \(c.unlinked == 1 ? "it" : "them").",
                      systemImage: "exclamationmark.magnifyingglass")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func checkbox(_ i: Int, _ item: String) -> some View {
        let done = recording.checkedActions.contains(i)
        let inReminders = recording.sentToReminders?.contains(i) == true
        let inCalendar = recording.sentToCalendar?.contains(i) == true
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { model.toggleAction(i, in: recording.id) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(done ? Color.accentColor : .secondary)
                        .font(.title3)
                    Text(SourceLinkStyle.attributed(SourceLinker.linkAll(item, pages: recording.isDocument)))
                        .strikethrough(done)
                        .foregroundStyle(done ? .secondary : .primary)
                        .multilineTextAlignment(.leading)
                }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(done ? .isSelected : [])
            Spacer(minLength: 4)
            Menu {
                Button { model.sendToReminders([i], in: recording.id) } label: {
                    Label(inReminders ? "Add to Reminders again" : "Add to Reminders", systemImage: "checklist")
                }
                Button {
                    if let e = model.draftEvent(i, in: recording.id) { eventDraft = EventDraft(index: i, event: e) }
                } label: {
                    Label(inCalendar ? "Add to Calendar again" : "Add to Calendar", systemImage: "calendar.badge.plus")
                }
            } label: {
                HStack(spacing: 3) {
                    if inReminders { Image(systemName: "checklist") }
                    if inCalendar { Image(systemName: "calendar") }
                    if !inReminders && !inCalendar { Image(systemName: "ellipsis.circle") }
                }
                .font(.body)
                .foregroundStyle(inReminders || inCalendar ? Color.accentColor : .secondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(inReminders || inCalendar ? "Sent. Send again" : "Send to Reminders or Calendar")
        }
    }

    private func md(_ text: String) -> some View {
        Markdown(SourceLinker.linkAll(text, pages: recording.isDocument))
            .markdownTextStyle(\.link) { ForegroundColor(.accentColor); FontWeight(.semibold); FontDigitVariant(.monospaced) }
    }
}

struct EventDraft: Identifiable {
    let id = UUID()
    let index: Int
    let event: EKEvent
}

/// The system "New Event" sheet. It saves through Calendar itself, so no Calendar permission is needed.
struct EventEditor: UIViewControllerRepresentable {
    let event: EKEvent
    let store: EKEventStore
    let done: (Bool) -> Void

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let vc = EKEventEditViewController()
        vc.eventStore = store
        vc.event = event
        vc.editViewDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: EKEventEditViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let done: (Bool) -> Void
        init(done: @escaping (Bool) -> Void) { self.done = done }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            done(action == .saved)
        }
    }
}

// MARK: - Transcript

/// A steady color per speaker number.
enum SpeakerColor {
    static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo]
    static func color(_ n: Int) -> Color { palette[(max(n, 1) - 1) % palette.count] }
}

/// The text of a PDF, Word file or slide deck, page by page, with find.
struct DocumentTextSection: View {
    let document: DocumentText
    /// Page or slide to highlight (tapped in the notes).
    var highlighted: Int? = nil
    @State private var find = ""

    private var parts: [DocumentText.Part] {
        let q = find.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? document.parts : document.parts.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in text", text: $find)
                if !find.isEmpty {
                    Text("\(parts.count)").font(.caption).foregroundStyle(.secondary)
                    Button { find = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(.secondary).accessibilityLabel("Clear search")
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            if let pages = document.recognizedPages, !pages.isEmpty {
                Label("Some pages are scans, so their text was read from the image on this iPhone. Check names and numbers.",
                      systemImage: "text.viewfinder")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(parts) { part in
                    VStack(alignment: .leading, spacing: 4) {
                        if let label = document.label(part) {
                            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        Text(part.text.isEmpty ? "(No text)" : part.text)
                            .foregroundStyle(part.text.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(highlighted == part.number ? 10 : 0)
                    .background(highlighted == part.number ? Color.accentColor.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .id("page-\(part.number)")
                }
            }
        }
        .onChange(of: highlighted) { _, n in if n != nil { find = "" } }
    }
}

struct TranscriptSection: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: AudioPlayer
    let recording: Recording
    @State private var find = ""
    @State private var renaming: Int?
    @State private var newName = ""

    private var transcript: Transcript? { recording.transcript }
    private func name(_ n: Int) -> String { Speakers.name(n, in: recording.speakerNames) }

    private var segments: [(Int, TranscriptSegment)] {
        let all = Array((transcript?.segments ?? []).enumerated())
        let q = find.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter {
            $0.1.text.localizedCaseInsensitiveContains(q)
                || ($0.1.speaker.map { name($0).localizedCaseInsensitiveContains(q) } ?? false)
        }
    }

    private var activeIndex: Int? {
        guard player.isPlaying || player.currentTime > 0 else { return nil }
        return transcript?.segments.lastIndex { $0.start <= player.currentTime + 0.05 }
    }

    var body: some View {
        if let transcript {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find in transcript", text: $find)
                    if !find.isEmpty {
                        Text("\(segments.count)").font(.caption).foregroundStyle(.secondary)
                        Button { find = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .foregroundStyle(.secondary).accessibilityLabel("Clear search")
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))

                NameSuggestionCard(recording: recording)
                speakerBar(transcript)

                if transcript.segments.isEmpty {
                    Text(transcript.text.isEmpty ? "No speech detected." : transcript.text).textSelection(.enabled)
                } else {
                    let rows = segments
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(rows.enumerated()), id: \.element.0) { pos, entry in
                            let (i, seg) = entry
                            if let n = seg.speaker, pos == 0 || rows[pos - 1].1.speaker != n {
                                Button { startRename(n) } label: {
                                    Text(name(n)).font(.subheadline.weight(.semibold)).foregroundStyle(SpeakerColor.color(n))
                                }
                                .buttonStyle(.plain)
                                .padding(.top, pos == 0 ? 0 : 6)
                                .accessibilityHint("Renames this speaker")
                            }
                            Button { player.seek(to: seg.start) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(formatTimestamp(seg.start))
                                        .font(.caption.monospacedDigit()).foregroundStyle(.tint)
                                        .frame(minWidth: 44, alignment: .leading)
                                    Text(seg.text).multilineTextAlignment(.leading)
                                        .foregroundStyle(.primary)
                                }
                                .padding(.vertical, 2).padding(.horizontal, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(i == activeIndex ? Color.accentColor.opacity(0.12) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Plays from here")
                        }
                    }
                }
                Text("Transcribed on this device in \(String(format: "%.1f", transcript.processingTime)) s")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .alert("Rename \(renaming.map(name) ?? "speaker")", isPresented: Binding(
                get: { renaming != nil }, set: { if !$0 { renaming = nil } })
            ) {
                TextField("Name", text: $newName)
                Button("Rename") {
                    if let n = renaming { model.renameSpeaker(n, to: newName, in: recording.id) }
                    renaming = nil
                }
                if let n = renaming, recording.speakerNames?[n] != nil {
                    Button("Use “\(Speakers.defaultName(n))”") {
                        model.renameSpeaker(n, to: "", in: recording.id)
                        renaming = nil
                    }
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            } message: {
                Text("The new name is used in the transcript, the summary and when you share.")
            }
        } else {
            Text("The transcript will appear here when it's ready.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func speakerBar(_ t: Transcript) -> some View {
        if !t.speakers.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(t.speakers, id: \.self) { n in
                        Button { startRename(n) } label: {
                            HStack(spacing: 5) {
                                Circle().fill(SpeakerColor.color(n)).frame(width: 8, height: 8)
                                Text(name(n))
                                Image(systemName: "pencil").font(.caption2).foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.quaternary.opacity(0.6), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Rename \(name(n))")
                    }
                }
            }
        } else if !t.text.isEmpty, t.audioDuration >= Speakers.minimumDuration, recording.noteKind == nil {
            HStack(spacing: 8) {
                Image(systemName: "person.2").foregroundStyle(.secondary)
                Text("No speaker labels yet.").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Label speakers") { model.labelSpeakers(recording.id) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    private func startRename(_ n: Int) {
        newName = recording.speakerNames?[n] ?? ""
        renaming = n
    }
}

/// Links in plain text (action items) styled like the summary's: accent color, semibold,
/// even-width digits, so a time looks the same everywhere.
enum SourceLinkStyle {
    static func attributed(_ markdown: String) -> AttributedString {
        guard var out = try? AttributedString(markdown: markdown) else { return AttributedString(markdown) }
        for run in out.runs where run.link != nil {
            out[run.range].font = .body.weight(.semibold).monospacedDigit()
            out[run.range].foregroundColor = .accentColor
        }
        return out
    }
}
