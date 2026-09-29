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
    @AppStorage("interfaceStyle") private var interface = AppInterface.text

    var body: some Scene {
        Window(model.windowTitle, id: "main") {
            ContentView(model: model, interface: interface)
                .background {
                    PlaybackKeyboardShortcut(enabled: model.connected && model.nowPlaying != nil) {
                        Task { await model.togglePlayback() }
                    }
                }
                .onAppear {
                    model.startMediaControls()
                    TopsAppDelegate.shutdownHandler = { model.shutdown() }
                }
        }
        .defaultSize(width: 320, height: 640)
        .windowToolbarStyle(.unified)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .toolbar) {
                Picker("Interface", selection: $interface) {
                    Text("Text").tag(AppInterface.text)
                    Text("Artwork").tag(AppInterface.artwork)
                }
            }
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

                Button("Reconnect Spotify") {
                    Task { await model.connect() }
                }
                .disabled(!model.connected || model.busy)
            }
        }
    }
}
