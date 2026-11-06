import LocalSummaryCore
import MarkdownUI
import SwiftUI

struct DetailView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: AudioPlayer
    let id: Recording.ID

    enum Tab: String, CaseIterable { case summary = "Summary", transcript = "Transcript" }
    @State private var tab: Tab = .summary
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var confirmDelete = false

    var body: some View {
        if let r = model.recording(id) {
            content(r)
                .onAppear { player.load(model.audioURL(for: r)) }
                .onChange(of: r.audioFileName) { player.load(model.audioURL(for: r)) }
                .onDisappear { player.pause() }
        } else {
            ContentUnavailableView("Recording deleted", systemImage: "trash")
        }
    }

    private func content(_ r: Recording) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(r)
                if player.isAvailable { PlayerControls().padding(.vertical, 4) }
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                switch tab {
                case .summary: summarySection(r)
                case .transcript: TranscriptSection(transcript: r.transcript)
                }
            }
            .padding()
        }
        // The big title is in the header, so the bar stays clean.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.openURL, OpenURLAction { url in
            if let s = SummaryLayout.seekSeconds(url) { player.seek(to: s); return .handled }
            return .systemAction
        })
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: model.exportFile(for: r), preview: SharePreview(r.title)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(r.summary == nil && r.transcript == nil)
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
            Text("The audio, transcript and summary are removed from this iPhone.")
        }
    }

    private func menu(_ r: Recording) -> some View {
        Menu {
            Button { newTitle = r.title; renaming = true } label: { Label("Rename", systemImage: "pencil") }
            if let s = r.summary {
                Button { UIPasteboard.general.string = s } label: { Label("Copy summary", systemImage: "doc.on.doc") }
            }
            if let t = r.transcript {
                Button { UIPasteboard.general.string = t.text } label: { Label("Copy transcript", systemImage: "text.quote") }
            }
            if r.status == .ready || r.status == .failed {
                Button { model.retry(r.id) } label: {
                    Label(r.transcript == nil ? "Transcribe again" : "Summarize again", systemImage: "arrow.clockwise")
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
                }
                Button { model.retry(r.id) } label: {
                    Label(r.transcript == nil ? "Try again" : "Try the summary again", systemImage: "arrow.clockwise")
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

// MARK: - Summary

/// Renders the summary as Markdown, with the action items (or a note's tasks) as real, saved
/// checkboxes, and every [mm:ss] turned into a link that plays the audio from there.
struct SummaryBody: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    let summary: String

    var body: some View {
        if recording.noteKind != nil { noteBody } else { summaryBody }
    }

    private var noteBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(SummaryLayout.noteBlocks(summary).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let t): md(t)
                case .task(let i, let t): checkbox(i, t)
                }
            }
        }
        .textSelection(.enabled)
    }

    private var summaryBody: some View {
        let parts = SummaryLayout.splitActions(summary)
        return VStack(alignment: .leading, spacing: 14) {
            if !parts.before.isEmpty { md(parts.before) }
            if !parts.actions.isEmpty {
                Text("Action items").font(.title3.weight(.semibold)).padding(.top, 6)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(parts.actions.enumerated()), id: \.offset) { i, item in checkbox(i, item) }
                }
            }
            if !parts.after.isEmpty { md(parts.after) }
        }
        .textSelection(.enabled)
    }

    private func checkbox(_ i: Int, _ item: String) -> some View {
        let done = recording.checkedActions.contains(i)
        return Button { model.toggleAction(i, in: recording.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? Color.accentColor : .secondary)
                    .font(.title3)
                Text((try? AttributedString(markdown: SummaryLayout.linkTimestamps(item))) ?? AttributedString(item))
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
                    .multilineTextAlignment(.leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(done ? .isSelected : [])
    }

    private func md(_ text: String) -> some View {
        Markdown(SummaryLayout.linkTimestamps(text))
            .markdownTextStyle(\.link) { ForegroundColor(.accentColor); FontFamilyVariant(.monospaced) }
    }
}

// MARK: - Transcript

struct TranscriptSection: View {
    @EnvironmentObject var player: AudioPlayer
    let transcript: Transcript?
    @State private var find = ""

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

                if transcript.segments.isEmpty {
                    Text(transcript.text.isEmpty ? "No speech detected." : transcript.text).textSelection(.enabled)
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(segments, id: \.0) { i, seg in
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
        } else {
            Text("The transcript will appear here when it's ready.").foregroundStyle(.secondary)
        }
    }
}
