import LocalSummaryCore
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
                    Text("Speech is turned into text on this iPhone with Parakeet. The model (about 500 MB) downloads once, the first time you transcribe, and then works offline. Recordings over 3 minutes also get Speaker 1, Speaker 2… labels, worked out on this iPhone; tap a name in the transcript to rename it.")
                }

                Section {
                    Picker("Summaries by", selection: $settings.engineKind) {
                        Text("Apple Intelligence").tag(EngineKind.apple)
                        Text("A Mac on your network").tag(EngineKind.localServer)
                    }
                    if settings.engineKind == .apple {
                        if let why = AppleIntelligenceEngine.unavailableReason {
                            Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.footnote)
                        } else {
                            Label("Ready on this iPhone", systemImage: "checkmark.circle").foregroundStyle(.green).font(.footnote)
                        }
                    } else {
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
                         ? "Apple Intelligence runs on this iPhone (iPhone 15 Pro or newer). Recordings under 3 minutes become clean written notes; longer ones get a summary with action items."
                         : "Use Ollama or LM Studio running on a Mac on the same Wi‑Fi, for example http://192.168.1.10:11434/v1. Audio never leaves your iPhone; only the transcript text is sent to that Mac.")
                }
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
