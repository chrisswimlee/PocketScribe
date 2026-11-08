import LocalSummaryCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var models: [String] = []
    @State private var testState: TestState = .idle

    enum TestState: Equatable { case idle, testing, ok(Int), failed(String) }

    var body: some View {
        Form {
            Section("Voice notes") {
                Toggle("Dictate from anywhere with \(GlobalHotKey.displayString)", isOn: $settings.voiceShortcutEnabled)
                Text("Tap to start and tap again to stop, or hold while you talk. Recordings under 3 minutes become a cleaned-up note; longer ones get a meeting summary.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Speech to text") {
                Picker("Model", selection: $settings.asrModel) {
                    Text("Parakeet v3 · 25 languages").tag(ASRModelChoice.multilingual)
                    Text("Parakeet v2 · English only").tag(ASRModelChoice.english)
                }
                Text("Runs on the Neural Engine with FluidAudio, the engine behind FluidVoice.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Label speakers in meetings", isOn: $settings.labelSpeakers)
                Text("Recordings over 3 minutes get Speaker 1, Speaker 2… labels, worked out on this Mac. Click a name in the transcript to rename it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Summarizer") {
                Picker("Engine", selection: $settings.engineKind) {
                    ForEach(EngineKind.allCases) { Text($0.label).tag($0) }
                }
                if settings.engineKind == .apple {
                    if let why = AppleIntelligenceEngine.unavailableReason {
                        Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else {
                        Label("Ready. Uses the model built into macOS; nothing to download.", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    TextField("Server URL", text: $settings.serverURL)
                    HStack {
                        Button("Use Ollama") { settings.serverURL = LocalServerEngine.ollamaDefault.absoluteString }
                        Button("Use LM Studio") { settings.serverURL = LocalServerEngine.lmStudioDefault.absoluteString }
                        Spacer()
                        Button("Test Connection") { Task { await test() } }
                            .disabled(testState == .testing)
                    }
                    switch testState {
                    case .idle: EmptyView()
                    case .testing: ProgressView().controlSize(.small)
                    case .ok(let n): Label("Connected. \(n) model\(n == 1 ? "" : "s") available.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed(let why): Label(why, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                    if models.isEmpty {
                        TextField("Model", text: $settings.serverModel)
                    } else {
                        Picker("Model", selection: $settings.serverModel) {
                            ForEach(models.contains(settings.serverModel) ? models : [settings.serverModel] + models, id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                    }
                }
                Toggle("Suggest a title for each recording", isOn: $settings.suggestTitles)
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                Text("Speech recognition by FluidAudio (Apache 2.0) using NVIDIA Parakeet models (CC BY 4.0). Markdown rendering by MarkdownUI (MIT). Audio, transcripts and notes stay on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("FluidAudio on GitHub", destination: URL(string: "https://github.com/FluidInference/FluidAudio")!)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: settings.serverURL) { models = []; testState = .idle }
        .task(id: settings.engineKind) { if settings.engineKind == .localServer { await test() } }
    }

    private func test() async {
        guard let url = URL(string: settings.serverURL) else { testState = .failed("That isn't a valid URL."); return }
        testState = .testing
        do {
            models = try await LocalServerEngine.listModels(baseURL: url)
            testState = .ok(models.count)
        } catch {
            models = []
            testState = .failed("Couldn't reach the server. Is Ollama or LM Studio running?")
        }
    }
}
