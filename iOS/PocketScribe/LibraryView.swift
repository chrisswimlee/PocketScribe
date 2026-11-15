import PocketScribeCore
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack(path: $model.path) {
            Group {
                if model.recordings.isEmpty {
                    EmptyLibrary()
                } else {
                    List {
                        ForEach(LibrarySections.group(model.recordings), id: \.title) { group in
                            Section {
                                ForEach(group.items) { r in
                                    NavigationLink(value: r.id) { RecordingRow(recording: r) }
                                        .swipeActions {
                                            Button(role: .destructive) { model.delete(r.id) } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                }
                            } header: {
                                Text(group.title)
                            }
                        }
                        if !model.trash.isEmpty {
                            Button { model.showTrash = true } label: {
                                Label("Recently Deleted (\(model.trash.count))", systemImage: "trash")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Notes")
            .navigationDestination(for: Recording.ID.self) { id in DetailView(id: id) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                }
            }
            .safeAreaInset(edge: .bottom) { CaptureDock(tab: .notes) }
        }
    }
}

private struct EmptyLibrary: View {
    var body: some View {
        ContentUnavailableView {
            Label("No recordings yet", systemImage: "waveform")
        } description: {
            Text("Tap **+** to record a meeting or lecture, take a voice note, write, or import a PDF, Word file or slide deck.\nOr **hold +** and talk for a quick note in your own words. Everything stays on this iPhone.")
        }
    }
}

struct RecordingRow: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                let kind = recording.itemKind
                Image(systemName: kind.symbol).foregroundStyle(.tint).font(.subheadline)
                    .frame(width: 20)
                    .accessibilityLabel(kind.label)
                Text(recording.title).font(.headline).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(Self.when(recording.createdAt))
                if let d = recording.duration { Text("·"); Text(formatTimestamp(d)).monospacedDigit() }
                if let doc = recording.document { Text("·"); Text(doc.sizeDescription) }
                ForEach(recording.tags ?? [], id: \.self) { Text("#\($0)") }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            status
        }
        .padding(.vertical, 2)
    }

    /// "10:42" today, "Tue 10:42" this week, "Nov 3" before that: the section header says the rest.
    static func when(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if let weekAgo = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: Date())), d >= weekAgo {
            return d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return d.formatted(.dateTime.month(.abbreviated).day())
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

// MARK: - Voice note bar

/// Shown next to the + button while a quick voice note is recording.
struct QuickNoteBanner: View {
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

// MARK: - Recently Deleted

/// "Moved to Recently Deleted" with Undo, for a few seconds after a delete.
struct UndoDeleteToast: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if let id = model.undoDeleteID, let r = model.trash.first(where: { $0.id == id }) {
                HStack(spacing: 12) {
                    Label("Deleted “\(r.title)”", systemImage: "trash").lineLimit(1)
                    Button("Undo") { model.restore(id) }.fontWeight(.semibold)
                }
                .font(.subheadline)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 4, y: 2)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: model.undoDeleteID)
    }
}

/// Items deleted in the last 30 days. Swipe to put back or delete now.
struct TrashView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete: Recording.ID?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.trash) { r in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(r.title).font(.headline).lineLimit(1)
                            Text(daysLeft(r)).font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions(edge: .leading) {
                            Button { model.restore(r.id) } label: { Label("Put Back", systemImage: "arrow.uturn.backward") }
                                .tint(.blue)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { confirmDelete = r.id } label: { Label("Delete Now", systemImage: "trash") }
                        }
                        .contextMenu {
                            Button { model.restore(r.id) } label: { Label("Put Back", systemImage: "arrow.uturn.backward") }
                            Button(role: .destructive) { confirmDelete = r.id } label: { Label("Delete Now", systemImage: "trash") }
                        }
                    }
                } footer: {
                    Text("Items are removed for good \(LibraryFiles.trashDays) days after you delete them. Swipe right to put one back.")
                }
            }
            .overlay {
                if model.trash.isEmpty {
                    ContentUnavailableView("Nothing in Recently Deleted", systemImage: "trash")
                }
            }
            .navigationTitle("Recently Deleted")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Empty", role: .destructive) { model.confirmEmptyTrash = true }
                        .disabled(model.trash.isEmpty)
                }
            }
            .confirmationDialog("Delete this now?", isPresented: Binding(
                get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible
            ) {
                Button("Delete Now", role: .destructive) { if let id = confirmDelete { model.deleteForever(id) } }
            } message: {
                Text("It is removed from this iPhone right away. This can't be undone.")
            }
            .confirmationDialog("Empty Recently Deleted?", isPresented: $model.confirmEmptyTrash, titleVisibility: .visible) {
                Button("Delete \(model.trash.count == 1 ? "1 item" : "\(model.trash.count) items")", role: .destructive) { model.emptyTrash() }
            } message: {
                Text("Everything here is removed from this iPhone right away. This can't be undone.")
            }
        }
    }

    private func daysLeft(_ r: Recording) -> String {
        guard let d = r.deletedAt else { return "" }
        let left = max(0, LibraryFiles.trashDays - (Calendar.current.dateComponents([.day], from: d, to: Date()).day ?? 0))
        return "\(left) day\(left == 1 ? "" : "s") left"
    }
}
