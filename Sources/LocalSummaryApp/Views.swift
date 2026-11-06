import AppKit
import LocalSummaryCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct LocalSummaryApp: App {
    @StateObject private var model = AppModel()

    init() {
        // When launched via `swift run`, make sure we get a Dock icon and focus.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("LocalSummary") {
            ContentView().environmentObject(model).frame(minWidth: 820, minHeight: 520)
        }
        Settings { SettingsView().environmentObject(model) }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var importing = false
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(model.items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.result.sourceName).lineLimit(1)
                        Text(item.result.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(item.id)
                    .contextMenu { Button("Delete", role: .destructive) { model.delete(item.id) } }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let id = model.selection, let item = model.items.first(where: { $0.id == id }) {
                SummaryDetail(result: item.result)
            } else {
                EmptyState(importing: $importing).environmentObject(model)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if let status = model.status {
                    ProgressView().controlSize(.small)
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
                Button { importing = true } label: { Label("Upload audio", systemImage: "square.and.arrow.down") }
                    .disabled(model.isBusy || model.isRecording)
                RecordButton()
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .movie, .mpeg4Movie]) { result in
            if case .success(let url) = result { model.process(url) }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.process(url) } }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(8).allowsHitTesting(false)
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) { Button("OK") {} } message: { Text(model.errorMessage ?? "") }
    }
}

struct RecordButton: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Button { model.toggleRecording() } label: {
            if model.isRecording, let start = model.recordingStartedAt {
                Label {
                    Text(timerInterval: start...Date.distantFuture, countsDown: false).monospacedDigit()
                } icon: { Image(systemName: "stop.circle.fill").foregroundStyle(.red) }
            } else {
                Label("Record", systemImage: "record.circle")
            }
        }
        .labelStyle(.titleAndIcon)
        .disabled(model.isBusy && !model.isRecording)
        .keyboardShortcut("r", modifiers: [.command, .shift])
    }
}

struct EmptyState: View {
    @EnvironmentObject var model: AppModel
    @Binding var importing: Bool
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.badge.mic").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Record or drop an audio file").font(.title2)
            Text("Transcription (FluidAudio / Parakeet) and summarization both run on this Mac. Nothing is uploaded.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack {
                Button("Choose file…") { importing = true }
                RecordButton()
            }
            .controlSize(.large)
            .disabled(model.isBusy)
            if let s = model.status { ProgressView(s).padding(.top) }
        }
        .padding(40)
    }
}

struct SummaryDetail: View {
    let result: SummaryResult
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Summary").tag(0)
                Text("Transcript").tag(1)
            }
            .pickerStyle(.segmented).frame(maxWidth: 260).padding(10)
            Divider()
            ScrollView {
                Group {
                    if tab == 0 {
                        MarkdownText(result.summary)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(result.transcript.segments.enumerated()), id: \.offset) { _, seg in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(formatTimestamp(seg.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Text(seg.text)
                                }
                            }
                            if result.transcript.segments.isEmpty { Text(result.transcript.text) }
                        }
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: 760, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(result.sourceName)
        .navigationSubtitle("\(formatTimestamp(result.transcript.audioDuration)) · \(result.engineName)")
        .toolbar {
            ToolbarItemGroup(placement: .secondaryAction) {
                Button("Copy summary", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.summary, forType: .string)
                }
                Button("Export Markdown…", systemImage: "square.and.arrow.up") { export() }
            }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(result.sourceName).md"
        if panel.runModal() == .OK, let url = panel.url {
            try? result.markdown.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// Minimal block-level Markdown renderer (headings, bullets, checkboxes, paragraphs).
struct MarkdownText: View {
    let lines: [String]
    init(_ md: String) { lines = md.components(separatedBy: "\n") }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("## ") || line.hasPrefix("# ") {
                    Text(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))
                        .font(.title3.bold()).padding(.top, 10)
                } else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: line.hasPrefix("- [x]") ? "checkmark.square" : "square")
                        inline(String(line.dropFirst(6)))
                    }
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline) { Text("•"); inline(String(line.dropFirst(2))) }
                } else if !line.isEmpty {
                    inline(line)
                }
            }
        }
    }

    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s) { return Text(a) }
        return Text(s)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let settings = Binding(get: { model.engineSettings }, set: { model.engineSettings = $0 })
        Form {
            Section("Speech-to-text (FluidAudio)") {
                Picker("Model", selection: $model.asrModelRaw) {
                    Text("Parakeet v3 · multilingual").tag(ASRModelChoice.multilingual.rawValue)
                    Text("Parakeet v2 · English only").tag(ASRModelChoice.english.rawValue)
                }
            }
            Section("Summarizer") {
                Picker("Engine", selection: settings.kind) {
                    ForEach(EngineKind.allCases) { Text($0.label).tag($0) }
                }
                if settings.wrappedValue.kind == .apple {
                    if let why = AppleIntelligenceEngine.unavailableReason {
                        Text(why).foregroundStyle(.orange).font(.callout)
                    } else {
                        Text("Ready. Uses the built-in on-device model; nothing to download.").font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    TextField("Server URL", text: settings.serverURL)
                    TextField("Model", text: settings.serverModel)
                    Text("Ollama: http://localhost:11434/v1 · LM Studio: http://localhost:1234/v1")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
    }
}
