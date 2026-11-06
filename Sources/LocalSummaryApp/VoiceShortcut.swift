import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// System-wide ⌥Space hotkey. Carbon hotkeys work without Accessibility permission
/// and report both press and release, which is what push-to-talk needs.
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    static let displayString = "⌥Space"

    func register(keyCode: Int = kVK_Space, modifiers: Int = optionKey) {
        unregister()
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async {
                if pressed { GlobalHotKey.shared.onPress?() } else { GlobalHotKey.shared.onRelease?() }
            }
            return noErr
        }, types.count, &types, nil, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x4C4E_5654), id: 1)  // "LNVT"
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}

/// Small floating "Listening…" panel shown while recording from the shortcut,
/// so you can talk without switching to the app.
@MainActor
final class ListeningHUD {
    static let shared = ListeningHUD()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(model: AppModel) {
        hideWork?.cancel()
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 64),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.isMovableByWindowBackground = true
            p.contentView = NSHostingView(rootView: HUDView().environmentObject(model))
            panel = p
        }
        guard let panel, let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.midX - 150, y: f.maxY - 64 - 24))
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let panel = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }) {
                panel.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

struct HUDView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            if model.isRecording {
                Image(systemName: "mic.fill").foregroundStyle(.red).font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Listening").font(.headline)
                        if let start = model.recordingStartedAt {
                            Text(timerInterval: start...Date.distantFuture, countsDown: false)
                                .font(.headline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    LevelMeter(level: model.inputLevel).frame(height: 6)
                }
                Spacer(minLength: 0)
                Text("\(GlobalHotKey.displayString) to stop").font(.caption).foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
                Text("Saved. Writing your note…").font(.headline)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .frame(width: 300, height: 64)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1)))
        .accessibilityElement(children: .combine)
    }
}
