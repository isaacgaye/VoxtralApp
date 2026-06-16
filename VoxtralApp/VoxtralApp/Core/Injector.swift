import Foundation
import AppKit
import Carbon

// Clipboard + ⌘V injection: cursor-aware, works in all apps including Electron.
// kAXValueAttribute (the prior AX path) replaced the entire field and caused double-text;
// paste is the correct approach for dictation.
final class Injector {
    func inject(_ text: String) {
        writeToClipboardAndPaste(text)
    }

    // MARK: - Private

    private func writeToClipboardAndPaste(_ text: String) {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        vlog("Injector.inject: textLength=\(text.count) frontmostApp=\(frontmost)")

        NSPasteboard.general.clearContents()
        let wroteToClipboard = NSPasteboard.general.setString(text, forType: .string)
        vlog("Injector.inject: clipboard write success=\(wroteToClipboard)")

        let src = CGEventSource(stateID: .hidSystemState)
        let vKey = CGKeyCode(kVK_ANSI_V)

        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
        vlog("Injector.inject: ⌘V posted")
    }
}
