import PocketPadCore
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""

    private var filtered: [Recording] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.recordings }
        return model.recordings.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || ($0.summary ?? "").localizedCaseInsensitiveContains(q)
                || ($0.transcript?.text ?? "").localizedCaseInsensitiveContains(q)
                || ($0.document?.text ?? "").localizedCaseInsensitiveContains(q)
                || ($0.tags ?? []).contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    var body: some View {
        NavigationStack(path: $model.path) {
            Group {
                if model.recordings.isEmpty {
                    EmptyLibrary()
                } else {
                    List {
                        ForEach(filtered) { r in
                            NavigationLink(value: r.id) { RecordingRow(recording: r) }
                                .swipeActions {
                                    Button(role: .destructive) { model.delete(r.id) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                    .searchable(text: $search, prompt: "Search notes and transcripts")
                    .overlay {
                        if filtered.isEmpty { ContentUnavailableView.search(text: search) }
                    }
                }
            }
            .navigationTitle("PocketPad")
            .navigationDestination(for: Recording.ID.self) { id in DetailView(id: id) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { model.showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.showImporter = true } label: { Label("Import audio or documents", systemImage: "square.and.arrow.down") }
                }
            }
            .safeAreaInset(edge: .bottom) { RecordBar() }
        }
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: AppModel.importTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importFiles(urls) }
        }
        .sheet(isPresented: $model.showSettings) { SettingsView() }
        .fullScreenCover(isPresented: Binding(
            get: { model.isRecording && !model.isQuickNote }, set: { _ in })
        ) { RecordingScreen() }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct EmptyLibrary: View {
    var body: some View {
        ContentUnavailableView {
            Label("No recordings yet", systemImage: "waveform")
        } description: {
            Text("Record a meeting or lecture to get a transcript and summary, hold the mic button to talk a quick note, or import a PDF, Word file or slide deck for notes. Everything stays on this iPhone.")
        }
    }
}

struct RecordingRow: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let kind = recording.noteKind {
                    Image(systemName: kind.symbol).foregroundStyle(.tint).font(.subheadline)
                } else if let doc = recording.document {
                    Image(systemName: doc.kind.symbol).foregroundStyle(.tint).font(.subheadline)
                        .accessibilityLabel(doc.kind.label)
                }
                Text(recording.title).font(.headline).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(recording.createdAt.formatted(.relative(presentation: .named)))
                if let d = recording.duration { Text("·"); Text(formatTimestamp(d)).monospacedDigit() }
                if let doc = recording.document { Text("·"); Text(doc.sizeDescription) }
                ForEach(recording.tags ?? [], id: \.self) { Text("#\($0)") }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            status
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var status: some View {
        switch recording.status {
        case .ready:
            if let t = recording.tldr {
                Text(t.replacingOccurrences(of: "**", with: "")).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        case .queued:
            Label("Waiting…", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
        case .processing:
            if model.isWorking(on: recording.id) {
                VStack(alignment: .leading, spacing: 2) {
                    ProgressView(value: model.progress ?? 0)
                    Text(model.progressText).font(.caption).foregroundStyle(.secondary)
                }
            }
        case .failed:
            Label(recording.errorMessage ?? "Failed", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange).lineLimit(2)
        }
    }
}

// MARK: - Record bar

/// Bottom bar: a big record button for long recordings, and a mic for quick notes
/// (tap to start and stop, or hold to talk and let go to finish).
struct RecordBar: View {
    @EnvironmentObject var model: AppModel
    @State private var pressedAt: Date?
    @State private var holding = false

    var body: some View {
        VStack(spacing: 10) {
            if model.isRecording && model.isQuickNote { QuickNoteBanner() }
            HStack(spacing: 28) {
                Spacer()
                Button { model.toggleRecording(quick: false) } label: {
                    Label("Record", systemImage: "record.circle")
                        .font(.headline)
                        .padding(.horizontal, 22).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .buttonBorderShape(.capsule)
                .disabled(model.isRecording)
                .accessibilityHint("Starts a long recording, such as a meeting or lecture")

                quickNoteButton
                Spacer()
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.bar)
    }

    private var quickNoteButton: some View {
        let active = model.isRecording && model.isQuickNote
        return Image(systemName: active ? "stop.fill" : "mic.fill")
            .font(.title2.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 56, height: 56)
            .background(Circle().fill(active ? Color.red : Color.accentColor))
            .scaleEffect(pressedAt != nil ? 1.15 : 1)
            .animation(.spring(duration: 0.25), value: pressedAt != nil)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard pressedAt == nil else { return }
                        let down = Date()
                        pressedAt = down
                        // Still held after a moment: push-to-talk.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            if pressedAt == down, !model.isRecording { holding = true; model.holdBegan() }
                        }
                    }
                    .onEnded { _ in
                        pressedAt = nil
                        if holding { holding = false; model.holdEnded() } else { model.toggleRecording(quick: true) }
                    }
            )
            .disabled(model.isRecording && !model.isQuickNote)
            .accessibilityLabel(active ? "Stop voice note" : "Voice note")
            .accessibilityHint("Tap to start and stop, or hold to talk")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.toggleRecording(quick: true) }
    }
}

/// Shown above the record bar while a quick note is recording.
private struct QuickNoteBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(.red).frame(width: 10, height: 10)
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                Text(elapsed).monospacedDigit().font(.subheadline.weight(.medium))
            }
            LevelBars(levels: Array(model.levelHistory.suffix(24))).frame(height: 24)
            Button("Cancel", role: .cancel) { model.discardRecording() }.font(.subheadline)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .padding(.horizontal)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var elapsed: String { formatTimestamp(Date().timeIntervalSince(model.recordingStartedAt ?? Date())) }
}

struct LevelBars: View {
    let levels: [Float]
    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, l in
                    Capsule().fill(.tint)
                        .frame(height: max(3, geo.size.height * CGFloat(l)))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Full-screen recorder for long recordings

struct RecordingScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmDiscard = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            Text("Recording").font(.title2.weight(.semibold))
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                Text(formatTimestamp(Date().timeIntervalSince(model.recordingStartedAt ?? Date())))
                    .font(.system(size: 64, weight: .light, design: .rounded)).monospacedDigit()
            }
            LevelBars(levels: model.levelHistory).frame(height: 80).padding(.horizontal)
            Text("You can lock your iPhone. Recording keeps going, and nothing leaves this device.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 40)
            Spacer()
            Button { model.stopRecording() } label: {
                Image(systemName: "stop.fill").font(.largeTitle).foregroundStyle(.white)
                    .frame(width: 84, height: 84).background(Circle().fill(.red))
            }
            .accessibilityLabel("Stop and transcribe")
            Button("Discard", role: .destructive) { confirmDiscard = true }
                .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                    Button("Discard", role: .destructive) { model.discardRecording() }
                }
            Spacer().frame(height: 20)
        }
        .frame(maxWidth: .infinity)
        .tint(.red)
    }
}
