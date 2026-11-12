import AppKit
import PocketScribeCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched with `swift run` (no bundle): get a Dock icon and focus.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    /// "Open With › Pocket Scribe" in Finder, or files dropped on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppModel.shared.importFiles(urls) }
    }

    /// Finish and save an in-progress recording instead of leaving an orphaned file.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            if AppModel.shared.isRecording { AppModel.shared.toggleRecording() }
        }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct PocketScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        Window("Pocket Scribe", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .environmentObject(model.player)
                .frame(minWidth: 860, minHeight: 540)
        }
        .commands { AppCommands(model: model, player: model.player) }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.settings)
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            Image(systemName: model.isRecording ? "record.circle.fill" : "waveform")
                .accessibilityLabel(model.isRecording ? "Pocket Scribe, recording" : "Pocket Scribe")
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(model.isRecording ? "Stop Recording" : "New Recording") { model.toggleRecording() }
        if model.settings.voiceShortcutEnabled {
            Text("Dictate anywhere: \(GlobalHotKey.displayString)")
        }
        if model.isProcessing {
            Text(model.progressText)
        }
        Divider()
        Button("Open Pocket Scribe") {
            openWindow(id: "main")
            NSApplication.shared.activate()
        }
        Divider()
        Button("Quit Pocket Scribe") { NSApplication.shared.terminate(nil) }
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject var player: AudioPlayer
    @AppStorage("textSize") private var textSize: Double = 14

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(model.isRecording ? "Stop Recording" : "New Recording") { model.toggleRecording() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Add Files…") { model.showImporter = true }
                .keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Export as Markdown…") { model.exportSelected() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.selected?.summary == nil)
            Button("Rename…") { model.pendingRename = model.selection }
                .disabled(model.selection == nil)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Summary") { model.copySummary() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(model.selected?.summary == nil)
            Button("Delete Recording…") { model.pendingDelete = model.selection }
                .disabled(model.selection == nil)
        }
        CommandMenu("Playback") {
            Button(player.isPlaying ? "Pause" : "Play") { player.toggle() }
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(!player.isAvailable)
            Button("Back 10 Seconds") { player.skip(-10) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!player.isAvailable)
            Button("Forward 10 Seconds") { player.skip(10) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!player.isAvailable)
        }
        CommandGroup(after: .toolbar) {
            Button("Make Text Bigger") { textSize = min(textSize + 1, 28) }
                .keyboardShortcut("+")
            Button("Make Text Smaller") { textSize = max(textSize - 1, 10) }
                .keyboardShortcut("-")
            Button("Actual Size") { textSize = 14 }
                .keyboardShortcut("0")
            Divider()
        }
    }
}
