import PocketScribeCore
import SwiftUI

enum AppTab: Hashable { case notes, todos, search }

/// The app's frame: Notes, To-dos and Search tabs. Sheets that any tab can open live here.
struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView(selection: $model.tab) {
            Tab("Notes", systemImage: "note.text", value: AppTab.notes) { LibraryView() }
            Tab("To-dos", systemImage: "checklist", value: AppTab.todos) { TodosView() }
                .badge(LibraryTasks.openCount(in: model.recordings))
            Tab(value: AppTab.search, role: .search) { SearchTab() }
        }
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: AppModel.importTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importFiles(urls); model.tab = .notes }
        }
        .sheet(isPresented: $model.showSettings) { SettingsView() }
        .sheet(isPresented: $model.composingNote) { NoteEditorSheet(recording: nil) }
        .sheet(isPresented: $model.showTrash) { TrashView() }
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

// MARK: - One capture button

/// Bottom of the Notes and To-dos tabs: the undo toast, the voice note bar while one is recording,
/// and the + button.
struct CaptureDock: View {
    @EnvironmentObject var model: AppModel
    let tab: AppTab

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(spacing: 8) {
                UndoDeleteToast()
                if model.isRecording && model.isQuickNote { QuickNoteBanner() }
            }
            .frame(maxWidth: .infinity)
            CaptureButton(tab: tab)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .animation(.default, value: model.isRecording)
    }
}

/// Tap for Voice note / Record / Write / Import. Hold to talk straight away; let go to finish.
/// While a voice note records, it turns into Stop.
struct CaptureButton: View {
    @EnvironmentObject var model: AppModel
    let tab: AppTab
    @State private var menuOpen = false
    @State private var pressedAt: Date?
    @State private var holding = false

    var body: some View {
        let active = model.isRecording && model.isQuickNote
        Image(systemName: active ? "stop.fill" : "plus")
            .font(.title2.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 60, height: 60)
            .background(Circle().fill(active ? Color.red : Color.accentColor))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
            .scaleEffect(pressedAt != nil ? 1.12 : 1)
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
                        if holding { holding = false; model.holdEnded() }
                        else if active { model.toggleRecording(quick: true) }
                        else if !model.isRecording { menuOpen = true }
                    }
            )
            .popover(isPresented: $menuOpen, attachmentAnchor: .point(.top), arrowEdge: .bottom) {
                CaptureMenu { action in
                    menuOpen = false
                    // Let the popover close before a sheet or the recorder opens.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { action() }
                }
                .presentationCompactAdaptation(.popover)
            }
            .accessibilityLabel(active ? "Stop voice note" : "New")
            .accessibilityHint(active ? "" : "Record, voice note, write or import. Hold to talk for a quick voice note.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if active { model.toggleRecording(quick: true) } else { menuOpen = true } }
            .accessibilityAction(named: "Quick voice note") { model.toggleRecording(quick: true) }
            #if DEBUG
            // Test hook: -showCapture YES opens the menu on the tab that's showing.
            .onAppear {
                if UserDefaults.standard.bool(forKey: "showCapture"), model.tab == tab {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { menuOpen = true }
                }
            }
            #endif
    }
}

private struct CaptureMenu: View {
    @EnvironmentObject var model: AppModel
    let run: (@escaping () -> Void) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Voice note", "Talk, get a clean note. Or hold +", "mic.fill", .accentColor) {
                model.toggleRecording(quick: true)
            }
            Divider()
            row("Record meeting or lecture", "Transcript, summary and to-dos", "record.circle", .red) {
                model.toggleRecording(quick: false)
            }
            Divider()
            row("Write a note", nil, "square.and.pencil", .accentColor) { model.composingNote = true }
            Divider()
            row("Import a file", "Audio, video, PDF, Word or slides", "square.and.arrow.down", .accentColor) {
                model.showImporter = true
            }
        }
        .frame(width: 300)
    }

    private func row(_ title: String, _ subtitle: String?, _ icon: String, _ tint: Color,
                     _ action: @escaping () -> Void) -> some View {
        Button { run(action) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title3).foregroundStyle(tint).frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.medium))
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - To-dos

/// Every open action item and task from every note, grouped by note.
struct TodosView: View {
    @EnvironmentObject var model: AppModel
    @State private var path: [Recording.ID] = []
    @State private var showDone = false
    /// Ticked while this list was open: they stay (struck through) until you leave it.
    @State private var justDone: Set<String> = []

    var body: some View {
        let groups = LibraryTasks.groups(in: model.recordings, includeDone: showDone, keeping: justDone)
        NavigationStack(path: $path) {
            List {
                ForEach(groups) { g in
                    Section {
                        ForEach(g.tasks) { t in row(t) }
                    } header: {
                        Button { path.append(g.item.id) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: g.item.itemKind.symbol)
                                Text(g.item.title).lineLimit(1)
                                Image(systemName: "chevron.right").font(.caption2)
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                        .textCase(nil)
                        .accessibilityHint("Opens the note")
                    }
                }
            }
            .overlay {
                if groups.isEmpty {
                    ContentUnavailableView {
                        Label(showDone ? "No to-dos yet" : "All done", systemImage: "checklist")
                    } description: {
                        Text("Action items from meetings and tasks from voice notes show up here, with the note they came from.")
                    }
                }
            }
            .navigationTitle("To-dos")
            .navigationDestination(for: Recording.ID.self) { id in DetailView(id: id) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(showDone ? "Hide Done" : "Show Done") { showDone.toggle() }
                }
            }
            .safeAreaInset(edge: .bottom) { CaptureDock(tab: .todos) }
            .onDisappear { justDone = [] }
        }
    }

    private func row(_ t: LibraryTask) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button {
                withAnimation {
                    if !t.done { justDone.insert(t.id) }
                    model.toggleAction(t.index, in: t.itemID)
                }
            } label: {
                Image(systemName: t.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(t.done ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(t.done ? "Mark as not done" : "Mark as done")
            VStack(alignment: .leading, spacing: 3) {
                Text(t.title)
                    .strikethrough(t.done)
                    .foregroundStyle(t.done ? .secondary : .primary)
                if t.due != nil || t.seconds != nil {
                    HStack(spacing: 8) {
                        if let due = t.due {
                            Label(due.formatted(t.dueHasTime ? .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()
                                                : .dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                                  systemImage: "calendar")
                                .foregroundStyle(!t.done && due < Calendar.current.startOfDay(for: Date()) ? Color.red : Color.secondary)
                        }
                        if let s = t.seconds {
                            Text(formatTimestamp(s)).monospacedDigit().foregroundStyle(.tint)
                        }
                    }
                    .font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { path.append(t.itemID) }
        .swipeActions {
            Button { model.sendToReminders([t.index], in: t.itemID) } label: {
                Label("Reminders", systemImage: "checklist")
            }
            .tint(.orange)
        }
    }
}

// MARK: - Search

/// Search across titles, summaries, transcripts, documents, tags and people.
struct SearchTab: View {
    @EnvironmentObject var model: AppModel
    @State private var path: [Recording.ID] = []

    private var query: String { model.searchText.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        let results = query.isEmpty ? [] : model.recordings.filter { LibrarySearch.matches($0, query) }
        let people = Connections.allPeople(in: model.recordings)
        NavigationStack(path: $path) {
            List {
                if query.isEmpty {
                    if !people.isEmpty {
                        Section("People") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(people, id: \.self) { p in
                                        Button { model.searchText = p } label: { PersonChip(name: p) }
                                            .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    Section("Recent") {
                        ForEach(model.recordings.prefix(5)) { r in
                            NavigationLink(value: r.id) { RecordingRow(recording: r) }
                        }
                    }
                } else {
                    ForEach(results) { r in
                        NavigationLink(value: r.id) { RecordingRow(recording: r) }
                    }
                }
            }
            .overlay {
                if !query.isEmpty && results.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .navigationTitle("Search")
            .navigationDestination(for: Recording.ID.self) { id in DetailView(id: id) }
            .searchable(text: $model.searchText, prompt: "Notes, transcripts and people")
        }
    }
}

struct PersonChip: View {
    let name: String
    var body: some View {
        Label(name, systemImage: "person.fill")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.pink)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.pink.opacity(0.12), in: Capsule())
    }
}

// MARK: - Connected

/// End of a note: the people in it, its tags, and other notes about the same things.
struct ConnectedSection: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    @State private var related: [RelatedNote] = []

    var body: some View {
        let people = Connections.people(of: recording)
        let tags = recording.tags ?? []
        let notes = related.compactMap { rel in model.recording(rel.id).map { (rel, $0) } }
        Group {
            if !people.isEmpty || !tags.isEmpty || !notes.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Divider().padding(.bottom, 4)
                    Text("Connected").font(.title3.weight(.semibold))
                    if !people.isEmpty || !tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(people, id: \.self) { p in
                                    Button { search(p) } label: { PersonChip(name: p) }
                                        .buttonStyle(.plain)
                                        .accessibilityHint("Shows every note with \(p)")
                                }
                                ForEach(tags, id: \.self) { t in
                                    Button { search("#" + t) } label: {
                                        Text("#" + t)
                                            .font(.subheadline.weight(.medium))
                                            .padding(.horizontal, 12).padding(.vertical, 6)
                                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    ForEach(notes, id: \.0.id) { rel, other in
                        NavigationLink(value: other.id) {
                            HStack(spacing: 10) {
                                Image(systemName: other.itemKind.symbol).foregroundStyle(.tint).frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(other.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text(rel.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(10)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 8)
            }
        }
        .task(id: stamp) {
            let item = recording
            let all = model.recordings
            related = await Task.detached(priority: .utility) { Connections.related(to: item, in: all) }.value
        }
    }

    /// Recompute when this note's text or the library changes.
    private var stamp: String {
        "\(recording.id)-\(recording.summary?.hashValue ?? 0)-\(model.recordings.count)"
    }

    private func search(_ text: String) {
        model.searchText = text
        model.tab = .search
    }
}
