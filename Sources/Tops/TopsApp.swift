import AppKit
import SwiftUI

extension Notification.Name {
    static let topsFocusSearch = Notification.Name("tops.focusSearch")
}

@MainActor
final class TopsAppDelegate: NSObject, NSApplicationDelegate {
    static var shutdownHandler: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Refresh the running icon even when LaunchServices has cached an older build.
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.shutdownHandler?()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
@MainActor
struct TopsApp: App {
    @NSApplicationDelegateAdaptor(TopsAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Tops", id: "main") {
            ContentView(model: model)
                .background {
                    PlaybackKeyboardShortcut(enabled: model.connected && model.nowPlaying != nil) {
                        Task { await model.togglePlayback() }
                    }
                }
                .onAppear {
                    TopsAppDelegate.shutdownHandler = { model.shutdown() }
                }
        }
        .defaultSize(width: 1_080, height: 760)
        .windowToolbarStyle(.unified)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Search") {
                    NotificationCenter.default.post(name: .topsFocusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!model.connected)

                Button("Refresh") {
                    Task { await model.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.connected || model.busy)
            }
        }
    }
}
