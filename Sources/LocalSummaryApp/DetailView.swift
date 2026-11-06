import LocalSummaryCore
import MarkdownUI
import SwiftUI

struct DetailView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: AudioPlayer
    let recording: Recording
    @Binding var tab: DetailTab
    @AppStorage("textSize") private var textSize: Double = 14

    var body: some View {
        VStack(spacing: 0) {
            content
            if player.isAvailable {
                Divider()
                PlayerBar()
            }
        }
        .navigationTitle(recording.title)
        .navigationSubtitle(subtitle)
        .environment(\.openURL, OpenURLAction { url in
            // [mm:ss] timestamps are rendered as seek://<seconds> links.
            if url.scheme == "seek", let s = url.host().flatMap(Double.init) {
                player.seek(to: s)
                return .handled
            }
            return .systemAction
        })
    }

    private var subtitle: String {
        var parts = [recording.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if let d = recording.duration { parts.append(formatTimestamp(d)) }
        if let e = recording.engineName { parts.append(e) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var content: some View {
        if model.isWorking(on: recording.id) || recording.status == .queued {
            ProcessingView(recording: recording)
        } else if recording.status == .failed && recording.transcript == nil {
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
                TranscriptView(transcript: recording.transcript, textSize: textSize)
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
            Label("Couldn't transcribe this file", systemImage: "exclamationmark.triangle")
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
                Text("The transcript is saved, but the summary failed.").font(.headline)
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
            ForEach(Array(Self.noteBlocks(summary).enumerated()), id: \.offset) { _, block in
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
        Toggle(isOn: Binding(
            get: { recording.checkedActions.contains(i) },
            set: { _ in model.toggleAction(i, in: recording.id) })
        ) {
            Text((try? AttributedString(markdown: Self.linkTimestamps(item))) ?? AttributedString(item))
                .font(.system(size: textSize))
                .strikethrough(recording.checkedActions.contains(i))
                .foregroundStyle(recording.checkedActions.contains(i) ? .secondary : .primary)
        }
        .toggleStyle(.checkbox)
    }

    private var summaryBody: some View {
        let parts = Self.split(summary)
        return VStack(alignment: .leading, spacing: 14) {
            if !parts.before.isEmpty { md(parts.before) }
            if !parts.actions.isEmpty {
                Text("Action items").font(.system(size: textSize * 1.3, weight: .semibold)).padding(.top, 6)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(parts.actions.enumerated()), id: \.offset) { i, item in
                        checkbox(i, item)
                    }
                }
            }
            if !parts.after.isEmpty { md(parts.after) }
        }
        .textSelection(.enabled)
    }

    private func md(_ text: String) -> some View {
        Markdown(Self.linkTimestamps(text))
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

// MARK: - Transcript

struct TranscriptView: View {
    @EnvironmentObject var player: AudioPlayer
    let transcript: Transcript?
    let textSize: Double
    @State private var find = ""
    @FocusState private var findFocused: Bool

    /// (index in the full transcript, segment), filtered by the find field.
    private var segments: [(Int, TranscriptSegment)] {
        let all = Array((transcript?.segments ?? []).enumerated())
        let q = find.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter { $0.1.text.localizedCaseInsensitiveContains(q) }
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
            Divider()
            if let transcript, transcript.segments.isEmpty {
                ScrollView { Text(transcript.text).font(.system(size: textSize)).textSelection(.enabled).padding(28) }
            } else {
                ScrollViewReader { proxy in
                    List(segments, id: \.0) { index, seg in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Button(formatTimestamp(seg.start)) { player.seek(to: seg.start) }
                                .buttonStyle(.link)
                                .font(.system(size: textSize * 0.85).monospacedDigit())
                                .accessibilityLabel("Play from \(spokenTime(seg.start))")
                            Text(seg.text).font(.system(size: textSize)).textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                        .listRowBackground(index == activeIndex ? Color.accentColor.opacity(0.12) : Color.clear)
                    }
                    .listStyle(.inset)
                    .onChange(of: activeIndex) { _, i in
                        if let i, player.isPlaying, find.isEmpty { withAnimation { proxy.scrollTo(i, anchor: .center) } }
                    }
                }
            }
        }
    }
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
