import AppKit
import XCTest
@testable import Tops

@MainActor
final class PlaybackKeyboardShortcutTests: XCTestCase {
    func testOnlyUnmodifiedNonRepeatingSpaceCanTogglePlayback() {
        XCTAssertTrue(PlaybackShortcutPolicy.shouldHandle(
            keyCode: 49, modifiers: [], isRepeat: false, enabled: true, focusOwnsSpace: false))
        for modifiers: NSEvent.ModifierFlags in [.command, .control, .option, .shift, .function, .capsLock] {
            XCTAssertFalse(PlaybackShortcutPolicy.shouldHandle(
                keyCode: 49, modifiers: modifiers, isRepeat: false, enabled: true, focusOwnsSpace: false))
        }
        XCTAssertFalse(PlaybackShortcutPolicy.shouldHandle(
            keyCode: 49, modifiers: [], isRepeat: true, enabled: true, focusOwnsSpace: false))
        XCTAssertFalse(PlaybackShortcutPolicy.shouldHandle(
            keyCode: 0, modifiers: [], isRepeat: false, enabled: true, focusOwnsSpace: false))
        XCTAssertFalse(PlaybackShortcutPolicy.shouldHandle(
            keyCode: 49, modifiers: [], isRepeat: false, enabled: false, focusOwnsSpace: false))
        XCTAssertFalse(PlaybackShortcutPolicy.shouldHandle(
            keyCode: 49, modifiers: [], isRepeat: false, enabled: true, focusOwnsSpace: true))
    }

    func testSearchTextAndFieldEditorsKeepTheirSpaces() {
        let search = NSSearchField()
        let text = NSTextField()
        let secure = NSSecureTextField()
        let combo = NSComboBox()
        let editor = NSTextView()
        editor.isFieldEditor = true
        for responder in [search, text, secure, combo, editor] as [NSResponder] {
            XCTAssertTrue(PlaybackShortcutPolicy.focusOwnsSpace(responder))
        }
    }

    func testFocusedControlsAndTheirPrivateEditingSubviewsKeepNativeBehavior() {
        let button = NSButton()
        let slider = NSSlider()
        XCTAssertTrue(PlaybackShortcutPolicy.focusOwnsSpace(button))
        XCTAssertTrue(PlaybackShortcutPolicy.focusOwnsSpace(slider))
        let privateEditor = NSView()
        let intermediate = NSView()
        let field = NSTextField()
        field.addSubview(intermediate)
        intermediate.addSubview(privateEditor)
        XCTAssertTrue(PlaybackShortcutPolicy.focusOwnsSpace(privateEditor))
        XCTAssertFalse(PlaybackShortcutPolicy.focusOwnsSpace(NSView()))
        XCTAssertFalse(PlaybackShortcutPolicy.focusOwnsSpace(nil))
    }
}
