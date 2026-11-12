import AVFoundation
import Foundation
import PocketPadCore

typealias Recording = LibraryItem

/// Persisted preferences. Plain UserDefaults with @Published so SwiftUI refreshes immediately.
@MainActor
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var engineKind: EngineKind { didSet { d.set(engineKind.rawValue, forKey: "engineKind") } }
    @Published var serverURL: String { didSet { d.set(serverURL, forKey: "serverURL") } }
    @Published var serverModel: String { didSet { d.set(serverModel, forKey: "serverModel") } }
    @Published var asrModel: ASRModelChoice { didSet { d.set(asrModel.rawValue, forKey: "asrModel") } }
    @Published var suggestTitles: Bool { didSet { d.set(suggestTitles, forKey: "suggestTitles") } }
    @Published var labelSpeakers: Bool { didSet { d.set(labelSpeakers, forKey: "labelSpeakers") } }

    init() {
        engineKind = EngineKind(rawValue: d.string(forKey: "engineKind") ?? "") ?? .apple
        serverURL = d.string(forKey: "serverURL") ?? "http://192.168.1.10:11434/v1"
        serverModel = d.string(forKey: "serverModel") ?? "qwen3:8b"
        asrModel = ASRModelChoice(rawValue: d.string(forKey: "asrModel") ?? "") ?? .multilingual
        suggestTitles = d.object(forKey: "suggestTitles") as? Bool ?? true
        labelSpeakers = d.object(forKey: "labelSpeakers") as? Bool ?? true
    }

    var engineSettings: EngineSettings {
        var s = EngineSettings()
        s.kind = engineKind
        s.serverURL = serverURL
        s.serverModel = serverModel
        return s
    }
}

/// Plays the open recording; timestamps in the UI seek it.
@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var loadedURL: URL?
    @Published var rate: Float = 1 { didSet { player?.rate = rate } }

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ url: URL?) {
        guard url != loadedURL else { return }
        stop()
        loadedURL = url
        player = nil
        currentTime = 0
        duration = 0
        guard let url, let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.enableRate = true
        p.rate = rate
        p.prepareToPlay()
        player = p
        duration = p.duration
    }

    var isAvailable: Bool { player != nil }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard let p = player else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        p.play()
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
    }

    func stop() {
        pause()
        player?.currentTime = 0
        currentTime = 0
    }

    func seek(to t: TimeInterval, andPlay: Bool = true) {
        guard let p = player else { return }
        p.currentTime = max(0, min(t, p.duration))
        currentTime = p.currentTime
        if andPlay { play() }
    }

    func skip(_ delta: TimeInterval) { seek(to: currentTime + delta, andPlay: isPlaying) }

    private func tick() {
        guard let p = player else { return }
        currentTime = p.currentTime
        if !p.isPlaying { isPlaying = false; timer?.invalidate() }
    }
}
