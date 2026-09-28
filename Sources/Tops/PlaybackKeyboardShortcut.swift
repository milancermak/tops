import AppKit
import SwiftUI

/// A window-local plain-Space shortcut that leaves text entry and focused controls alone.
struct PlaybackKeyboardShortcut: NSViewRepresentable {
    var enabled: Bool
    var action: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        MonitorView()
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.enabled = enabled
        view.action = action
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
        view.action = {}
    }

    final class MonitorView: NSView {
        var enabled = false
        var action: () -> Void = {}
        private var monitor: Any?

        override var acceptsFirstResponder: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window,
                      event.window === window, window.isKeyWindow,
                      window.attachedSheet == nil,
                      PlaybackShortcutPolicy.shouldHandle(
                          keyCode: event.keyCode,
                          modifiers: event.modifierFlags,
                          isRepeat: event.isARepeat,
                          enabled: self.enabled,
                          focusOwnsSpace: PlaybackShortcutPolicy.focusOwnsSpace(window.firstResponder)
                      ) else { return event }
                self.action()
                return nil
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

enum PlaybackShortcutPolicy {
    static func shouldHandle(keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                             isRepeat: Bool, enabled: Bool, focusOwnsSpace: Bool) -> Bool {
        enabled && keyCode == 49 && !isRepeat && !focusOwnsSpace
            && modifiers.intersection(.deviceIndependentFlagsMask).isEmpty
    }

    @MainActor
    static func focusOwnsSpace(_ responder: NSResponder?) -> Bool {
        // Field editors, TextEditor, search/secure/combo fields and custom text
        // inputs must receive their spaces, including marked-text composition.
        if responder is NSTextInputClient || responder is NSControl { return true }
        // A control can hand focus to a private editing subview. Preserve native
        // Space behavior for those descendants and keyboard-focused controls too.
        var ancestor = (responder as? NSView)?.superview
        while let view = ancestor {
            if view is NSTextInputClient || view is NSControl { return true }
            ancestor = view.superview
        }
        return false
    }
}
