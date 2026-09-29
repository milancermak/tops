import AppKit
import SwiftUI

enum AppInterface: String {
    case text
    case artwork
}

extension AppModel {
    var windowTitle: String {
        guard connected, let track = nowPlaying, track.kind == "track" else { return "Tops" }
        let artist = track.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Tops - \(track.title)" + (artist.isEmpty ? "" : " by \(artist)")
    }
}

/// Resize the existing window so switching presentation never replaces the session.
struct InterfaceWindow: NSViewRepresentable {
    var interface: AppInterface
    var collectionOpen: Bool
    var reduceMotion: Bool
    var title: String

    func makeNSView(context: Context) -> WindowView { WindowView() }

    func updateNSView(_ view: WindowView, context: Context) {
        view.configure(interface: interface, collectionOpen: collectionOpen, reduceMotion: reduceMotion, title: title)
    }

    final class WindowView: NSView {
        private var interface = AppInterface.text
        private var collectionOpen = false
        private var reduceMotion = false
        private var title = "Tops"
        private var appliedInterface: AppInterface?
        private var appliedCollectionOpen = false
        private var artworkFrameSize = NSSize(width: 1_080, height: 788)
        private var updateScheduled = false
        private var fullscreenObserver: NSObjectProtocol?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let fullscreenObserver { NotificationCenter.default.removeObserver(fullscreenObserver) }
            fullscreenObserver = nil
            if let window {
                fullscreenObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
                ) { [weak self] _ in self?.scheduleUpdate() }
                scheduleUpdate()
            }
        }

        deinit {
            if let fullscreenObserver { NotificationCenter.default.removeObserver(fullscreenObserver) }
        }

        func configure(interface: AppInterface, collectionOpen: Bool, reduceMotion: Bool, title: String) {
            self.interface = interface
            self.collectionOpen = collectionOpen
            self.reduceMotion = reduceMotion
            self.title = title
            scheduleUpdate()
        }

        private func scheduleUpdate() {
            guard !updateScheduled else { return }
            updateScheduled = true
            // Let SwiftUI remove the previous presentation's size constraints first.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateScheduled = false
                self.updateWindow()
            }
        }

        private func updateWindow() {
            guard let window else { return }
            window.title = title
            window.toolbarStyle = interface == .text ? .expanded : .unified
            window.toolbar?.isVisible = interface == .artwork
            window.titleVisibility = interface == .text ? .visible : .hidden
            window.titlebarAppearsTransparent = interface == .artwork
            let modeChanged = appliedInterface != interface
            let selectionChanged = appliedCollectionOpen != collectionOpen
            guard modeChanged || selectionChanged else { return }
            guard !window.styleMask.contains(.fullScreen) else { return }
            let firstUpdate = appliedInterface == nil
            let previousFrame = window.frame
            if appliedInterface == .artwork, modeChanged { artworkFrameSize = previousFrame.size }
            appliedInterface = interface
            appliedCollectionOpen = collectionOpen
            // Browsing another collection, title updates and playback ticks do not resize.
            guard interface == .text || modeChanged else { return }

            // Opening a column changes width only. Mixing contentLayoutRect with
            // frameRect would accumulate toolbar/titlebar height across switches.
            var frame = previousFrame
            if interface == .text { frame.size.width = collectionOpen ? 850 : 320 }
            else { frame.size = artworkFrameSize }
            frame.origin.y = previousFrame.maxY - frame.height
            if let screen = window.screen?.visibleFrame {
                frame.size.width = min(frame.width, screen.width)
                frame.size.height = min(frame.height, screen.height)
                frame.origin.x = max(screen.minX, min(frame.minX, screen.maxX - frame.width))
                frame.origin.y = max(screen.minY, min(frame.minY, screen.maxY - frame.height))
            }
            if firstUpdate || reduceMotion {
                window.setFrame(frame, display: true)
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.24
                    window.animator().setFrame(frame, display: true)
                }
            }
        }
    }
}
