import AppIntents
import SwiftUI

@main
struct LocalNotesApp: App {
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(model)
                .environmentObject(model.player)
                .environmentObject(model.settings)
                // "Open in LocalNotes" / share sheet from Files, Voice Memos, Mail…
                .onOpenURL { url in
                    if url.isFileURL { model.importFiles([url]) }
                    else if url.host() == "voice-note" { model.startRecording(quick: true) }
                }
                .task { model.applyLaunchArguments() }
        }
    }
}

// MARK: - Siri, Shortcuts, Spotlight and the Action button

struct NewVoiceNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "New Voice Note"
    static let description = IntentDescription("Starts recording a quick voice note. Tap stop when you're done and it becomes a clean written note.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.startRecording(quick: true)
        return .result()
    }
}

struct NewRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "New Recording"
    static let description = IntentDescription("Starts recording a meeting, lecture or conversation to transcribe and summarize.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.startRecording(quick: false)
        return .result()
    }
}

struct LocalNotesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewVoiceNoteIntent(),
            phrases: ["New voice note in \(.applicationName)", "Take a note with \(.applicationName)"],
            shortTitle: "Voice Note", systemImageName: "mic.badge.plus")
        AppShortcut(
            intent: NewRecordingIntent(),
            phrases: ["Start recording in \(.applicationName)", "Record a meeting with \(.applicationName)"],
            shortTitle: "Record Meeting", systemImageName: "waveform")
    }
}
