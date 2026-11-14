import PocketScribeCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Language", selection: $settings.asrModel) {
                        Text("Multilingual (25 languages)").tag(ASRModelChoice.multilingual)
                        Text("English only").tag(ASRModelChoice.english)
                    }
                    Toggle("Label speakers", isOn: $settings.labelSpeakers)
                } header: {
                    Text("Transcription")
                } footer: {
                    Text("Speech becomes text on this iPhone. The speech model downloads once (about 500 MB), then works offline. Recordings over 30 seconds get Speaker 1, Speaker 2… labels you can rename.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Summaries by", selection: $settings.engineKind) {
                            Text("Apple Intelligence").tag(EngineKind.apple)
                            Text("A Mac on your network").tag(EngineKind.localServer)
                        }
                        // Status sits under the picker, in the same row, rather than as a row of its own.
                        if settings.engineKind == .apple {
                            if let why = AppleIntelligenceEngine.unavailableReason {
                                Text(why).font(.footnote).foregroundStyle(.orange)
                            } else {
                                Text("Ready on this iPhone").font(.footnote).foregroundStyle(.green)
                            }
                        }
                    }
                    if settings.engineKind == .localServer {
                        TextField("Server address", text: $settings.serverURL)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Model", text: $settings.serverModel)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button(testing ? "Testing…" : "Test connection") { test() }.disabled(testing)
                        if let testResult { Text(testResult).font(.footnote).foregroundStyle(.secondary) }
                    }
                    Toggle("Suggest titles", isOn: $settings.suggestTitles)
                } header: {
                    Text("Summaries")
                } footer: {
                    Text(settings.engineKind == .apple
                         ? "Runs on this iPhone (iPhone 15 Pro or newer). Quick notes become clean written notes; meetings and long recordings get a summary with action items."
                         : "Use Ollama or LM Studio running on a Mac on the same Wi‑Fi, for example http://192.168.1.10:11434/v1. Audio never leaves your iPhone; only the transcript text is sent to that Mac.")
                }

                StorageSection()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func test() {
        guard let url = URL(string: settings.serverURL) else { testResult = "That address isn't a valid URL."; return }
        testing = true
        Task {
            do {
                let models = try await LocalServerEngine.listModels(baseURL: url)
                testResult = models.contains(settings.serverModel)
                    ? "Connected. \(settings.serverModel) is available."
                    : "Connected, but \(settings.serverModel) isn't installed. Available: \(models.prefix(6).joined(separator: ", "))"
            } catch {
                testResult = "Couldn't connect: \(error.localizedDescription)"
            }
            testing = false
        }
    }
}

/// How much space the speech models and recordings take, with a way to delete the models.
private struct StorageSection: View {
    @EnvironmentObject var model: AppModel
    @State private var modelsSize: Int64?
    @State private var audioSize: Int64?
    @State private var confirmDelete = false

    private static var modelsDir: URL {
        URL.applicationSupportDirectory.appending(path: "FluidAudio")
    }
    private static var audioDir: URL { AppModel.supportDir.appending(path: "Audio") }

    var body: some View {
        Section {
            LabeledContent("Speech models", value: size(modelsSize))
            LabeledContent("Recordings and files", value: size(audioSize))
            Button("Delete Speech Models", role: .destructive) { confirmDelete = true }
                .disabled((modelsSize ?? 0) == 0 || model.isProcessing)
                .confirmationDialog("Delete the speech models?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete Speech Models", role: .destructive) { deleteModels() }
                } message: {
                    Text("Your recordings and notes stay. The models download again (about 500 MB) the next time you transcribe.")
                }
        } header: {
            Text("Storage")
        } footer: {
            Text("To free space taken by recordings, delete them in the library and empty Recently Deleted.")
        }
        .task { await measure() }
    }

    private func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "…" }
        return bytes == 0 ? "None" : bytes.formatted(.byteCount(style: .file))
    }

    private func measure() async {
        let modelsDir = Self.modelsDir, audioDir = Self.audioDir
        let (m, a) = await Task.detached(priority: .utility) {
            (Self.folderSize(modelsDir), Self.folderSize(audioDir))
        }.value
        modelsSize = m
        audioSize = a
    }

    private func deleteModels() {
        try? FileManager.default.removeItem(at: Self.modelsDir)
        modelsSize = nil
        Task { await measure() }
    }

    nonisolated static func folderSize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }
}
