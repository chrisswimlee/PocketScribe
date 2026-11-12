import PocketScribeCore
import MarkdownUI
import SwiftUI

struct DetailView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: AudioPlayer
    let recording: Recording
    @Binding var tab: DetailTab
    @AppStorage("textSize") private var textSize: Double = 14
    /// A page or slide the user tapped in the summary ("p. 3"), to show in the Text tab.
    @State private var pageTarget: Int?

    var body: some View {
        VStack(spacing: 0) {
            content
            if player.isAvailable {
                Divider()
                PlayerBar()
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 4, y: 2)
                    .padding(.bottom, player.isAvailable ? 64 : 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: model.notice)
        .navigationTitle(recording.title)
        .navigationSubtitle(subtitle)
        .environment(\.openURL, OpenURLAction { url in
            // [mm:ss] timestamps are rendered as seek://<seconds> links.
            if url.scheme == "seek", let s = url.host().flatMap(Double.init) {
                player.seek(to: s)
                return .handled
            }
            // "p. 3" / "slide 7" in a document's notes open that page in the Text tab.
            if let n = SourceLinker.pageNumber(url) {
                pageTarget = n
                tab = .transcript
                return .handled
            }
            return .systemAction
        })
    }

    private var subtitle: String {
        var parts = [recording.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if let d = recording.duration { parts.append(formatTimestamp(d)) }
        if let doc = recording.document { parts.append(doc.sizeDescription) }
        if let e = recording.engineName { parts.append(e) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var content: some View {
        if model.isWorking(on: recording.id) || recording.status == .queued {
            ProcessingView(recording: recording)
        } else if recording.status == .failed && recording.transcript == nil && recording.document == nil {
            FailedView(recording: recording)
        } else {
            switch tab {
            case .summary:
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if recording.status == .failed { FailedBanner(recording: recording) }
                        if let summary = recording.summary {
                            SummaryBody(recording: recording, summary: summary, textSize: textSize)
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(28)
                    .frame(maxWidth: .infinity)
                }
            case .transcript:
                if let doc = recording.document {
                    DocumentTextView(document: doc, textSize: textSize, target: $pageTarget)
                } else {
                    TranscriptView(recording: recording, textSize: textSize)
                }
            }
        }
    }
}

// MARK: - Processing / failure states

struct ProcessingView: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording

    var body: some View {
        VStack(spacing: 14) {
            if model.isWorking(on: recording.id) {
                ProgressView(value: model.progress ?? 0) {
                    Text(model.progressText)
                } currentValueLabel: {
                    Text("\(Int((model.progress ?? 0) * 100))%")
                }
                .frame(maxWidth: 360)
                Button("Cancel") { model.cancelProcessing() }
                Text("You can keep working. Drop more files and they'll be queued.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ProgressView()
                Text("Waiting for the file ahead of this one…").foregroundStyle(.secondary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FailedView: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    var body: some View {
        ContentUnavailableView {
            Label(recording.isDocument ? "Couldn't read this file" : "Couldn't transcribe this file",
                  systemImage: "exclamationmark.triangle")
        } description: {
            Text(recording.errorMessage ?? "Unknown error.")
        } actions: {
            Button("Try Again") { model.retry(recording.id) }.controlSize(.large)
        }
    }
}

struct FailedBanner: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    let recording: Recording
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(recording.isDocument ? "The text is saved, but the summary failed." : "The transcript is saved, but the summary failed.").font(.headline)
                Text(recording.errorMessage ?? "").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Retry Summary") { model.retry(recording.id) }
                    Button("Summarizer Settings…") { openSettings() }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Summary

/// Renders the summary as Markdown, with the "Action items" section as real, saved checkboxes
/// and every [mm:ss] turned into a link that plays the audio from there.
struct SummaryBody: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    let summary: String
    let textSize: Double

    /// The summary with any renamed speakers ("Speaker 2" → "Maria").
    private var text: String { Speakers.apply(recording.speakerNames, to: summary) }

    var body: some View {
        if recording.noteKind != nil { noteBody } else { summaryBody }
    }

    /// Voice note: tags on top, then the note with every "- [ ]" line as a real checkbox.
    private var noteBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if let kind = recording.noteKind {
                    Label(kind.label, systemImage: kind.symbol)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.tint.opacity(0.15), in: Capsule())
                }
                ForEach(recording.tags ?? [], id: \.self) { tag in
                    Text("#\(tag)").font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
            }
            ForEach(Array(Self.noteBlocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let t): md(t)
                case .task(let i, let t): checkbox(i, t)
                }
            }
        }
        .textSelection(.enabled)
    }

    enum NoteBlock { case text(String), task(Int, String) }

    static func noteBlocks(_ md: String) -> [NoteBlock] {
        var blocks: [NoteBlock] = []
        var buffer: [String] = []
        var taskIndex = 0
        func flush() {
            let t = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { blocks.append(.text(t)) }
            buffer.removeAll()
        }
        for line in md.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let box = ["- [ ] ", "- [x] ", "- [X] ", "* [ ] "].first(where: { t.hasPrefix($0) }) {
                flush()
                blocks.append(.task(taskIndex, String(t.dropFirst(box.count))))
                taskIndex += 1
            } else {
                buffer.append(line)
            }
        }
        flush()
        return blocks
    }

    private func checkbox(_ i: Int, _ item: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            toggle(i, item)
            Spacer(minLength: 8)
            sendMenu(i)
        }
    }

    /// Bell / calendar badges once sent, and a menu to send the item.
    private func sendMenu(_ i: Int) -> some View {
        let inReminders = recording.sentToReminders?.contains(i) == true
        let inCalendar = recording.sentToCalendar?.contains(i) == true
        return HStack(spacing: 6) {
            if inReminders {
                Image(systemName: "checklist").foregroundStyle(.secondary).help("Sent to Reminders")
                    .accessibilityLabel("Sent to Reminders")
            }
            if inCalendar {
                Image(systemName: "calendar").foregroundStyle(.secondary).help("Added to Calendar")
                    .accessibilityLabel("Added to Calendar")
            }
            Menu {
                Button { model.sendToReminders([i], in: recording.id) } label: {
                    Label(inReminders ? "Add to Reminders Again" : "Add to Reminders", systemImage: "checklist")
                }
                Button { model.addToCalendar(i, in: recording.id) } label: {
                    Label(inCalendar ? "Add to Calendar Again" : "Add to Calendar", systemImage: "calendar.badge.plus")
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Send to Reminders or Calendar")
            .accessibilityLabel("Send to Reminders or Calendar")
        }
        .font(.system(size: textSize * 0.9))
    }

    private func toggle(_ i: Int, _ item: String) -> some View {
        Toggle(isOn: Binding(
            get: { recording.checkedActions.contains(i) },
            set: { _ in model.toggleAction(i, in: recording.id) })
        ) {
            Text((try? AttributedString(markdown: SourceLinker.linkAll(item, pages: recording.isDocument))) ?? AttributedString(item))
                .font(.system(size: textSize))
                .strikethrough(recording.checkedActions.contains(i))
                .foregroundStyle(recording.checkedActions.contains(i) ? .secondary : .primary)
        }
        .toggleStyle(.checkbox)
    }

    private var summaryBody: some View {
        let parts = Self.split(text)
        return VStack(alignment: .leading, spacing: 14) {
            if !parts.before.isEmpty { md(parts.before) }
            if !parts.actions.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text("Action items").font(.system(size: textSize * 1.3, weight: .semibold))
                    Spacer()
                    let unsent = parts.actions.indices.filter { recording.sentToReminders?.contains($0) != true }
                    if !unsent.isEmpty {
                        Button {
                            model.sendToReminders(unsent, in: recording.id)
                        } label: {
                            Label(unsent.count == parts.actions.count ? "Add All to Reminders" : "Add \(unsent.count) to Reminders",
                                  systemImage: "checklist")
                        }
                        .controlSize(.small)
                        .help("Adds each action item to your default Reminders list, with its deadline when one was said")
                    }
                }
                .padding(.top, 6)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(parts.actions.enumerated()), id: \.offset) { i, item in
                        checkbox(i, item)
                    }
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
            Divider().padding(.top, 6)
            if c.unlinked == 0 {
                Label("Every point links to the \(source) it came from. Click a \(recording.isDocument ? "page number" : "time") to check it.",
                      systemImage: "checkmark.seal")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Label("\(c.unlinked) point\(c.unlinked == 1 ? "" : "s") without a link couldn't be found in \(what). Double-check \(c.unlinked == 1 ? "it" : "them") before relying on \(c.unlinked == 1 ? "it" : "them").",
                      systemImage: "exclamationmark.magnifyingglass")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func md(_ text: String) -> some View {
        Markdown(SourceLinker.linkAll(text, pages: recording.isDocument))
            .markdownTextStyle { FontSize(textSize) }
            .markdownTextStyle(\.link) { ForegroundColor(.accentColor); FontFamilyVariant(.monospaced) }
    }

    /// "[01:23]" → "[01:23](seek://83)"
    static func linkTimestamps(_ s: String) -> String {
        let pattern = #"\[((?:\d{1,2}:)?\d{1,2}:\d{2})\](?!\()"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        var out = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(m.range, in: s), let inner = Range(m.range(at: 1), in: s) else { continue }
            let parts = s[inner].split(separator: ":").compactMap { Int($0) }
            let seconds = parts.reduce(0) { $0 * 60 + $1 }
            out.replaceSubrange(whole, with: "[\(s[inner])](seek://\(seconds))")
        }
        return out
    }

    static func split(_ md: String) -> (before: String, actions: [String], after: String) {
        let lines = md.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("## action items")
        }) else { return (md, [], "") }
        let end = lines[(start + 1)...].firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.endIndex
        let items = lines[(start + 1)..<end].compactMap { line -> String? in
            var t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- ") || t.hasPrefix("* ") else { return nil }
            t = String(t.dropFirst(2))
            for box in ["[ ] ", "[x] ", "[X] "] where t.hasPrefix(box) { t = String(t.dropFirst(box.count)) }
            return t
        }
        return (lines[..<start].joined(separator: "\n"), items, lines[end...].joined(separator: "\n"))
    }
}

// MARK: - Document text

/// The text of a PDF, Word file or slide deck, page by page, with find.
struct DocumentTextView: View {
    let document: DocumentText
    let textSize: Double
    /// Page or slide to scroll to and highlight (set by tapping "p. 3" in the summary).
    @Binding var target: Int?
    @State private var highlighted: Int?
    @State private var find = ""
    @FocusState private var findFocused: Bool

    private var parts: [DocumentText.Part] {
        let q = find.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? document.parts : document.parts.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Find in text", text: $find).textFieldStyle(.plain).focused($findFocused)
                if !find.isEmpty {
                    if let unit = document.unitName {
                        Text("\(parts.count) \(unit.lowercased())\(parts.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button { find = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                }
                Button("Find") { findFocused = true }.keyboardShortcut("f")
                    .opacity(0).frame(width: 0).accessibilityHidden(true)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            if let pages = document.recognizedPages, !pages.isEmpty {
                Label(pages.count == document.parts.count
                      ? "This PDF is a scan, so its text was read from the page images on this Mac. Check names and numbers."
                      : "\(pages.count) scanned page\(pages.count == 1 ? " was" : "s were") read from the page image. Check names and numbers.",
                      systemImage: "text.viewfinder")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
            Divider()
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(parts) { part in
                        VStack(alignment: .leading, spacing: 6) {
                            if let label = document.label(part) {
                                Text(label).font(.system(size: textSize * 0.85, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            Text(part.text.isEmpty ? "(No text on this \(document.unitName?.lowercased() ?? "page"))" : part.text)
                                .font(.system(size: textSize))
                                .foregroundStyle(part.text.isEmpty ? .secondary : .primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(highlighted == part.number ? 10 : 0)
                        .background(highlighted == part.number ? Color.accentColor.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .id(part.number)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity)
            }
            .onAppear { reveal(target, proxy) }
            .onChange(of: target) { _, n in reveal(n, proxy) }
            }
        }
    }

    private func reveal(_ n: Int?, _ proxy: ScrollViewProxy) {
        guard let n else { return }
        find = ""
        highlighted = n
        target = nil
        // Let the list lay out the unfiltered pages first.
        DispatchQueue.main.async { withAnimation { proxy.scrollTo(n, anchor: .top) } }
    }
}

// MARK: - Transcript

struct TranscriptView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: AudioPlayer
    let recording: Recording
    let textSize: Double
    @State private var find = ""
    @FocusState private var findFocused: Bool
    @State private var renaming: Int?
    @State private var newName = ""

    private var transcript: Transcript? { recording.transcript }
    private func name(_ n: Int) -> String { Speakers.name(n, in: recording.speakerNames) }

    /// (index in the full transcript, segment), filtered by the find field (text or speaker name).
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
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Find in transcript", text: $find)
                    .textFieldStyle(.plain)
                    .focused($findFocused)
                if !find.isEmpty {
                    Text("\(segments.count) matches").font(.caption).foregroundStyle(.secondary)
                    Button { find = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                }
                // ⌘F focuses the find field.
                Button("Find") { findFocused = true }.keyboardShortcut("f")
                    .opacity(0).frame(width: 0).accessibilityHidden(true)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            speakerBar
            Divider()
            if let transcript, transcript.segments.isEmpty {
                ScrollView { Text(transcript.text).font(.system(size: textSize)).textSelection(.enabled).padding(28) }
            } else {
                ScrollViewReader { proxy in
                    List(Array(segments.enumerated()), id: \.element.0) { pos, entry in
                        let (index, seg) = entry
                        VStack(alignment: .leading, spacing: 4) {
                            // Name the speaker whenever it changes.
                            if let n = seg.speaker, pos == 0 || segments[pos - 1].1.speaker != n {
                                speakerLabel(n).padding(.top, pos == 0 ? 0 : 6)
                            }
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Button(formatTimestamp(seg.start)) { player.seek(to: seg.start) }
                                    .buttonStyle(.link)
                                    .font(.system(size: textSize * 0.85).monospacedDigit())
                                    .accessibilityLabel("Play from \(spokenTime(seg.start))")
                                Text(seg.text).font(.system(size: textSize)).textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 2)
                        .listRowBackground(index == activeIndex ? Color.accentColor.opacity(0.12) : Color.clear)
                        .id(index)
                    }
                    .listStyle(.inset)
                    .onChange(of: activeIndex) { _, i in
                        if let i, player.isPlaying, find.isEmpty { withAnimation { proxy.scrollTo(i, anchor: .center) } }
                    }
                }
            }
        }
        .alert("Rename \(renaming.map(name) ?? "speaker")", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } })
        ) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let n = renaming { model.renameSpeaker(n, to: newName, in: recording.id) }
                renaming = nil
            }
            .keyboardShortcut(.defaultAction)
            if let n = renaming, recording.speakerNames?[n] != nil {
                Button("Use “\(Speakers.defaultName(n))”") {
                    model.renameSpeaker(n, to: "", in: recording.id)
                    renaming = nil
                }
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("The new name is used in the transcript, the summary and exports.")
        }
    }

    /// Everyone who speaks, as chips you click to rename. For older recordings, a button to add labels.
    @ViewBuilder private var speakerBar: some View {
        let speakers = transcript?.speakers ?? []
        if !speakers.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Text("Speakers").font(.caption).foregroundStyle(.secondary)
                    ForEach(speakers, id: \.self) { n in
                        Button { startRename(n) } label: {
                            HStack(spacing: 5) {
                                Circle().fill(SpeakerColor.color(n)).frame(width: 8, height: 8)
                                Text(name(n))
                                Image(systemName: "pencil").font(.caption2).foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Rename \(name(n))")
                        .accessibilityLabel("Rename \(name(n))")
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
        } else if let t = transcript, !t.text.isEmpty, t.audioDuration >= Speakers.minimumDuration,
                  recording.noteKind == nil {
            HStack {
                Image(systemName: "person.2").foregroundStyle(.secondary)
                Text("This transcript doesn't say who's speaking.").font(.caption).foregroundStyle(.secondary)
                Button("Label Speakers") { model.labelSpeakers(recording.id) }
                    .controlSize(.small)
                    .help("Transcribes again with speaker labels, then rewrites the summary")
                Spacer()
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
    }

    private func speakerLabel(_ n: Int) -> some View {
        Button { startRename(n) } label: {
            Text(name(n))
                .font(.system(size: textSize * 0.85, weight: .semibold))
                .foregroundStyle(SpeakerColor.color(n))
        }
        .buttonStyle(.plain)
        .help("Rename \(name(n))")
    }

    private func startRename(_ n: Int) {
        newName = recording.speakerNames?[n] ?? ""
        renaming = n
    }
}

/// A steady color per speaker number, readable in light and dark mode.
enum SpeakerColor {
    static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo]
    static func color(_ n: Int) -> Color { palette[(max(n, 1) - 1) % palette.count] }
}

func spokenTime(_ t: TimeInterval) -> String {
    Duration.seconds(Int(t)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
}

// MARK: - Player

struct PlayerBar: View {
    @EnvironmentObject var player: AudioPlayer
    @State private var scrubbing: Double?

    var body: some View {
        HStack(spacing: 12) {
            Button { player.skip(-10) } label: { Image(systemName: "gobackward.10") }
                .accessibilityLabel("Back 10 seconds")
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button { player.skip(10) } label: { Image(systemName: "goforward.10") }
                .accessibilityLabel("Forward 10 seconds")
            Text(formatTimestamp(scrubbing ?? player.currentTime))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { scrubbing ?? player.currentTime },
                set: { scrubbing = $0 }),
                   in: 0...max(player.duration, 1)) { editing in
                if !editing, let s = scrubbing { player.seek(to: s, andPlay: player.isPlaying); scrubbing = nil }
            }
            .accessibilityLabel("Playback position")
            .accessibilityValue(spokenTime(player.currentTime))
            Text(formatTimestamp(player.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Picker("Speed", selection: $player.rate) {
                ForEach([0.75, 1, 1.25, 1.5, 2] as [Float], id: \.self) { Text("\($0.formatted())×").tag($0) }
            }
            .labelsHidden()
            .frame(width: 70)
            .help("Playback speed")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }
}
