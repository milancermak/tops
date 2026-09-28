import AppKit
import SwiftUI

/// A toolbar search field with explicit, one-shot native focus requests.
struct NativeSearchField: NSViewRepresentable {
    struct FocusRequest: Equatable {
        let id = UUID()
        let focused: Bool
    }

    @Binding var text: String
    var focusRequest: FocusRequest?
    var enabled: Bool
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> SearchField {
        let view = SearchField()
        view.placeholderString = "Search Spotify"
        view.setAccessibilityLabel("Search Spotify")
        view.font = .systemFont(ofSize: 12)
        view.controlSize = .regular
        view.maximumRecents = 0
        // Publish every edit; AppModel owns the debounce so native search timing
        // cannot delay or duplicate requests.
        view.sendsWholeSearchString = false
        view.sendsSearchStringImmediately = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        view.target = context.coordinator
        view.action = #selector(Coordinator.search(_:))
        return view
    }

    func updateNSView(_ view: SearchField, context: Context) {
        context.coordinator.parent = self
        view.isEnabled = enabled
        if view.stringValue != text { view.stringValue = text }
        view.apply(focusRequest)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func dismantleNSView(_ view: SearchField, coordinator: Coordinator) {
        view.cancelFocusRequest()
        view.delegate = nil
        view.target = nil
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeSearchField
        init(_ parent: NativeSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            if parent.text != field.stringValue { parent.text = field.stringValue }
        }

        @objc func search(_ field: NSSearchField) {
            if parent.text != field.stringValue { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)),
                  let field = control as? NSSearchField else { return false }
            search(field)
            if !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parent.onSubmit()
            }
            return true
        }
    }

    final class SearchField: NSSearchField {
        private var pendingFocus: FocusRequest?
        private var handledFocusID: UUID?
        private var focusScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { scheduleFocus() }
        }

        func apply(_ request: FocusRequest?) {
            guard let request, request.id != handledFocusID else { return }
            pendingFocus = request
            scheduleFocus()
        }

        func cancelFocusRequest() { pendingFocus = nil }

        private func scheduleFocus() {
            guard pendingFocus != nil, !focusScheduled else { return }
            focusScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.focusScheduled = false
                self.fulfillFocusRequest()
            }
        }

        private func fulfillFocusRequest() {
            guard let request = pendingFocus, let window else { return }
            if request.focused {
                guard isEnabled, window.makeFirstResponder(self) else { return }
                selectText(nil)
            } else if window.firstResponder === self || window.firstResponder === currentEditor() {
                window.makeFirstResponder(nil)
            }
            handledFocusID = request.id
            pendingFocus = nil
        }
    }
}
