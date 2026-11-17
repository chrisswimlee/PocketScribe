import PocketScribeCore
import SwiftUI

enum SidebarPage: Hashable { case notes, todos }

/// Every open action item and task from every note, grouped by note.
struct TodosView: View {
    @EnvironmentObject var model: AppModel
    @State private var showDone = false
    /// Ticked while this list was open: they stay (struck through) until you leave it.
    @State private var justDone: Set<String> = []

    var body: some View {
        let groups = LibraryTasks.groups(in: model.recordings, includeDone: showDone, keeping: justDone)
        List {
            ForEach(groups) { g in
                Section {
                    ForEach(g.tasks) { t in row(t) }
                } header: {
                    Button { model.selection = g.item.id } label: {
                        Label(g.item.title, systemImage: g.item.itemKind.symbol)
                    }
                    .buttonStyle(.link)
                    .help("Open the note")
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
        .toolbar {
            ToolbarItem {
                Toggle("Show Done", isOn: $showDone).toggleStyle(.button)
                    .help("Show to-dos you've ticked off")
            }
        }
        .onDisappear { justDone = [] }
    }

    private func row(_ t: LibraryTask) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                if !t.done { justDone.insert(t.id) }
                model.toggleAction(t.index, in: t.itemID)
            } label: {
                Image(systemName: t.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(t.done ? Color.secondary : Color.accentColor)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(t.done ? "Mark as not done" : "Mark as done")
            Text(t.title)
                .strikethrough(t.done)
                .foregroundStyle(t.done ? .secondary : .primary)
            Spacer(minLength: 8)
            if let due = t.due {
                Text("Due " + due.formatted(t.dueHasTime ? .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()
                                            : .dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.caption)
                    .foregroundStyle(!t.done && due < Calendar.current.startOfDay(for: Date()) ? Color.red : Color.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.selection = t.itemID }
        .contextMenu {
            Button("Open Note") { model.selection = t.itemID }
            Button("Add to Reminders") { model.sendToReminders([t.index], in: t.itemID) }
        }
    }
}

/// End of a note: the people in it, its tags, and other notes about the same things.
struct ConnectedSection: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    @State private var related: [RelatedNote] = []

    var body: some View {
        let people = Connections.people(of: recording)
        let tags = recording.tags ?? []
        let notes = related.compactMap { rel in model.recordings.first { $0.id == rel.id }.map { (rel, $0) } }
        Group {
            if !people.isEmpty || !tags.isEmpty || !notes.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Divider().padding(.bottom, 4)
                    Text("Connected").font(.title3.weight(.semibold))
                    if !people.isEmpty || !tags.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(people, id: \.self) { p in
                                chip(p, systemImage: "person.fill", tint: .pink) { model.search = p }
                                    .help("Show every note with \(p)")
                            }
                            ForEach(tags, id: \.self) { t in
                                chip("#" + t, systemImage: nil, tint: .accentColor) { model.search = "#" + t }
                            }
                        }
                    }
                    ForEach(notes, id: \.0.id) { rel, other in
                        Button { model.selection = other.id } label: {
                            HStack(spacing: 10) {
                                Image(systemName: other.itemKind.symbol).foregroundStyle(.tint).frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(other.title).fontWeight(.semibold).lineLimit(1)
                                    Text(rel.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
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

    private func chip(_ text: String, systemImage: String?, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let systemImage { Label(text, systemImage: systemImage) } else { Text(text) }
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// ⇧⌘O: type a few letters of a note's title, words in it, or a person's name, then Return.
struct QuickOpenSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    enum Hit: Identifiable {
        case note(Recording), person(String)
        var id: String {
            switch self {
            case .note(let r): return r.id.uuidString
            case .person(let p): return "person-" + p
            }
        }
    }

    private var hits: [Hit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.recordings.prefix(8).map { .note($0) } }
        let people = Connections.allPeople(in: model.recordings)
            .filter { $0.localizedCaseInsensitiveContains(q) }.prefix(3).map { Hit.person($0) }
        let notes = model.recordings.filter { LibrarySearch.matches($0, q) }
        // Title matches before matches deeper in the text.
        let ordered = notes.filter { $0.title.localizedCaseInsensitiveContains(q) }
            + notes.filter { !$0.title.localizedCaseInsensitiveContains(q) }
        return people + ordered.prefix(12).map { .note($0) }
    }

    var body: some View {
        let hits = hits
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Open a note or a person…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { if hits.indices.contains(highlighted) { open(hits[highlighted]) } }
                    .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(hits.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(hits.enumerated()), id: \.element.id) { i, hit in
                            row(hit, selected: i == highlighted)
                                .id(i)
                                .onTapGesture { open(hit) }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: highlighted) { _, i in proxy.scrollTo(i) }
            }
            .overlay {
                if hits.isEmpty { Text("Nothing matches “\(query)”").foregroundStyle(.secondary) }
            }
        }
        .frame(width: 540, height: 400)
        .onAppear { focused = true }
        .onChange(of: query) { highlighted = 0 }
    }

    @ViewBuilder private func row(_ hit: Hit, selected: Bool) -> some View {
        HStack(spacing: 10) {
            switch hit {
            case .note(let r):
                Image(systemName: r.itemKind.symbol).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.title).lineLimit(1)
                    Text(r.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption).foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                }
            case .person(let p):
                Image(systemName: "person.fill").frame(width: 20)
                Text(p)
                Text("Every note with \(p)").font(.caption).foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private func open(_ hit: Hit) {
        switch hit {
        case .note(let r): model.selection = r.id
        case .person(let p): model.search = p
        }
        dismiss()
    }
}
