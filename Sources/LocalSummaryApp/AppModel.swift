import AVFoundation
import Foundation
import LocalSummaryCore
import SwiftUI

struct LibraryItem: Identifiable, Codable {
    var id = UUID()
    var result: SummaryResult
}

@MainActor
final class AppModel: ObservableObject {
    @Published var items: [LibraryItem] = []
    @Published var selection: LibraryItem.ID?
    @Published var status: String?
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var isRecording = false
    @Published var recordingStartedAt: Date?

    @AppStorage("engineSettings") private var engineSettingsData: Data = Data()
    @AppStorage("asrModel") var asrModelRaw: String = ASRModelChoice.multilingual.rawValue

    var engineSettings: EngineSettings {
        get { (try? JSONDecoder().decode(EngineSettings.self, from: engineSettingsData)) ?? EngineSettings() }
        set { engineSettingsData = (try? JSONEncoder().encode(newValue)) ?? Data(); objectWillChange.send() }
    }

    private let transcriber = Transcriber()
    private var recorder: AVAudioRecorder?

    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "LocalSummary", directoryHint: .isDirectory)
        for sub in ["Library", "Recordings"] {
            try? FileManager.default.createDirectory(at: base.appending(path: sub), withIntermediateDirectories: true)
        }
        return base
    }()
    private var libraryDir: URL { Self.supportDir.appending(path: "Library") }
    private var recordingsDir: URL { Self.supportDir.appending(path: "Recordings") }

    init() { loadLibrary() }

    // MARK: Library

    private func loadLibrary() {
        let files = (try? FileManager.default.contentsOfDirectory(at: libraryDir, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        items = files.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(LibraryItem.self, from: Data(contentsOf: $0)) }
            .sorted { $0.result.createdAt > $1.result.createdAt }
    }

    private func save(_ item: LibraryItem) {
        let url = libraryDir.appending(path: "\(item.id.uuidString).json")
        try? JSONEncoder().encode(item).write(to: url)
    }

    func delete(_ id: LibraryItem.ID) {
        items.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: libraryDir.appending(path: "\(id.uuidString).json"))
    }

    // MARK: Processing

    func process(_ url: URL) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        let scoped = url.startAccessingSecurityScopedResource()
        let pipeline = Pipeline(
            transcriber: transcriber, engine: engineSettings.makeEngine(),
            asrModel: ASRModelChoice(rawValue: asrModelRaw) ?? .multilingual)
        Task {
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                isBusy = false
                status = nil
            }
            do {
                let result = try await pipeline.run(audio: url) { stage in
                    Task { @MainActor in self.status = Self.describe(stage) }
                }
                let item = LibraryItem(result: result)
                save(item)
                items.insert(item, at: 0)
                selection = item.id
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private static func describe(_ s: PipelineStage) -> String {
        switch s {
        case .loadingSpeechModel: return "Loading speech model (first run downloads ~500 MB)…"
        case .transcribing: return "Transcribing on the Neural Engine…"
        case .summarizing(let m): return m
        case .done: return "Done"
        }
    }

    // MARK: Recording

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in
                guard granted else {
                    self.errorMessage = "Microphone access denied. Enable it in System Settings › Privacy & Security › Microphone."
                    return
                }
                let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
                    .replacingOccurrences(of: ":", with: "-")
                let url = self.recordingsDir.appending(path: "Recording \(stamp).m4a")
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                ]
                do {
                    let r = try AVAudioRecorder(url: url, settings: settings)
                    guard r.record() else { throw NSError(domain: "LocalSummary", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not start recording."]) }
                    self.recorder = r
                    self.isRecording = true
                    self.recordingStartedAt = Date()
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func stopRecording() {
        guard let r = recorder else { return }
        r.stop()
        recorder = nil
        isRecording = false
        recordingStartedAt = nil
        process(r.url)
    }
}
