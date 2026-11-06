import LocalSummaryCore
import SwiftUI
import UniformTypeIdentifiers

enum DetailTab: String, CaseIterable { case summary = "Summary", transcript = "Transcript" }

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var dropTargeted = false
    @State private var tab: DetailTab = .summary
    @State private var renameText = ""

    var body: some View {
        NavigationSplitView {
            Sidebar(search: search)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
                .searchable(text: $search, placement: .sidebar, prompt: "Search recordings")
        } detail: {
            VStack(spacing: 0) {
                if model.isRecording { RecordingBanner() }
                if let r = model.selected {
                    DetailView(recording: r, tab: $tab)
                } else {
                    EmptyDetail()
                }
            }
        }
        .toolbar { toolbar }
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: AppModel.audioTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importFiles(urls) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.importFiles(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .overlay(Text("Drop audio or video to transcribe").font(.title3).padding(10)
                        .background(.regularMaterial, in: Capsule()))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) { Button("OK") {} } message: { Text(model.errorMessage ?? "") }
        .confirmationDialog(
            "Delete “\(model.recordings.first { $0.id == model.pendingDelete }?.title ?? "")”?",
            isPresented: Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let id = model.pendingDelete { model.delete(id) }
            }
        } message: {
            Text("The audio, transcript and summary will be removed from this Mac. This can't be undone.")
        }
        .alert("Rename Recording", isPresented: Binding(
            get: { model.pendingRename != nil }, set: { if !$0 { model.pendingRename = nil } })
        ) {
            TextField("Title", text: $renameText)
            Button("Rename") { if let id = model.pendingRename { model.rename(id, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: model.pendingRename) { _, id in
            renameText = model.recordings.first { $0.id == id }?.title ?? ""
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if let r = model.selected, r.transcript != nil {
                Picker("View", selection: $tab) {
                    ForEach(DetailTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .help("Switch between the summary and the full transcript")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let r = model.selected, r.summary != nil {
                ShareLink(item: r.markdown, subject: Text(r.title), preview: SharePreview(r.title)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .help("Share the summary and transcript")
            }
            Button { model.showImporter = true } label: {
                Label("Upload Audio", systemImage: "plus")
            }
            .help("Upload audio or video files (⌘O)")
            RecordButton()
        }
    }
}

struct RecordButton: View {
    @EnvironmentObject var model: AppModel
    var prominent = false

    var body: some View {
        Button { model.toggleRecording() } label: {
            Label(model.isRecording ? "Stop" : "Record",
                  systemImage: model.isRecording ? "stop.fill" : "record.circle")
        }
        .tint(.red)
        .buttonStyle(.borderedProminent)
        .controlSize(prominent ? .large : .regular)
        .help(model.isRecording ? "Stop and transcribe (⇧⌘R)" : "Start a new recording (⇧⌘R)")
    }
}

struct RecordingBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Circle().fill(.red).frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text("Recording").font(.headline)
            if let start = model.recordingStartedAt {
                Text(timerInterval: start...Date.distantFuture, countsDown: false)
                    .font(.headline.monospacedDigit())
            }
            LevelMeter(level: model.inputLevel).frame(width: 140, height: 8)
            Spacer()
            Button("Stop and Transcribe") { model.toggleRecording() }
                .buttonStyle(.borderedProminent).tint(.red)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.red.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }
}

struct LevelMeter: View {
    var level: Float
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(level > 0.85 ? Color.orange : Color.green)
                    .frame(width: g.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}

struct EmptyDetail: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label(model.recordings.isEmpty ? "Record or drop in audio" : "Nothing selected",
                  systemImage: "waveform.badge.mic")
        } description: {
            Text("Transcription and summaries run on this Mac. Nothing is uploaded.")
        } actions: {
            HStack {
                Button("Upload Audio…") { model.showImporter = true }.controlSize(.large)
                RecordButton(prominent: true)
            }
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    let search: String

    private var filtered: [Recording] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.recordings }
        return model.recordings.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || ($0.summary?.localizedCaseInsensitiveContains(q) ?? false)
                || ($0.transcript?.text.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private var groups: [(String, [Recording])] {
        let cal = Calendar.current
        let now = Date()
        var buckets: [String: [Recording]] = [:]
        let order = ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "Older"]
        for r in filtered {
            let key: String
            if cal.isDateInToday(r.createdAt) { key = "Today" }
            else if cal.isDateInYesterday(r.createdAt) { key = "Yesterday" }
            else if r.createdAt > now.addingTimeInterval(-7 * 86_400) { key = "Previous 7 Days" }
            else if r.createdAt > now.addingTimeInterval(-30 * 86_400) { key = "Previous 30 Days" }
            else { key = "Older" }
            buckets[key, default: []].append(r)
        }
        return order.compactMap { k in buckets[k].map { (k, $0) } }
    }

    var body: some View {
        List(selection: $model.selection) {
            ForEach(groups, id: \.0) { name, items in
                Section(name) {
                    ForEach(items) { r in
                        SidebarRow(recording: r)
                            .tag(r.id)
                            .contextMenu {
                                Button("Rename…") { model.pendingRename = r.id }
                                if r.summary != nil { Button("Copy Summary") { model.copySummary(r.id) } }
                                if r.status == .ready || r.status == .failed {
                                    Button(r.transcript == nil ? "Transcribe Again" : "Summarize Again") { model.retry(r.id) }
                                }
                                Button("Show Audio in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([model.audioURL(for: r)])
                                }
                                Divider()
                                Button("Delete…", role: .destructive) { model.pendingDelete = r.id }
                            }
                    }
                }
            }
        }
        .onDeleteCommand { model.pendingDelete = model.selection }
        .overlay {
            if model.recordings.isEmpty {
                ContentUnavailableView("No recordings yet", systemImage: "tray",
                                       description: Text("Your recordings and uploads will appear here."))
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
    }
}

struct SidebarRow: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(recording.title).font(.headline).lineLimit(1)
                Spacer(minLength: 0)
                statusIcon
            }
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            if model.isWorking(on: recording.id) {
                ProgressView(value: model.progress ?? 0).controlSize(.small)
                Text(model.progressText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else if recording.status == .queued {
                Text("Waiting…").font(.caption2).foregroundStyle(.secondary)
            } else if recording.status == .failed {
                Text(recording.errorMessage ?? "Failed").font(.caption2).foregroundStyle(.red).lineLimit(2)
            } else if let tldr = recording.tldr {
                Text(tldr).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var s = recording.createdAt.formatted(date: .omitted, time: .shortened)
        if !Calendar.current.isDateInToday(recording.createdAt), !Calendar.current.isDateInYesterday(recording.createdAt) {
            s = recording.createdAt.formatted(.dateTime.month(.abbreviated).day()) + ", " + s
        }
        if let d = recording.duration { s += " · " + formatTimestamp(d) }
        return s
    }

    @ViewBuilder private var statusIcon: some View {
        switch recording.status {
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .accessibilityLabel("Failed")
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary).accessibilityLabel("Waiting")
        default: EmptyView()
        }
    }
}
