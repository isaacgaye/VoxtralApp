import Foundation
import CoreGraphics

enum HotkeyEvent {
    case startRecording
    case stopRecording
}

// Hold-to-talk with an added double-tap-to-lock gesture, both on the same
// user-configured hotkey — no separate activation mode to pick.
//
//   Hold-to-talk (unchanged):  key-down -> startRecording; key-up -> stopRecording.
//   Double-tap-to-lock (new):  two quick press-release taps in succession ->
//     recording continues hands-free; the next single tap stops it.
//
// Tap runs on the main run loop — onEvent always fires on the main thread.
//
// Accessibility permission is required. tapCreate returns nil if not granted;
// caller detects this by checking eventTap == nil after start() returns.
final class HotkeyManager {
    var onEvent: ((HotkeyEvent) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hotkey: String = "rightOption"
    private var flagsKeyWasDown = false  // tracks previous state for isFlagsKey hotkeys

    // MARK: - Session state

    private var isRecording = false
    private var sessionStartedAt: Date?

    // MARK: - Double-tap-lock state
    //
    // The disambiguation problem: a single continuous physical hold can spuriously
    // report a release ~470ms in (a known Right-Option/fn hardware quirk), then
    // re-report pressed again before the user's real release. In raw terms that's
    // down -> up(spurious) -> down(phantom) -> up(real, whenever the user actually
    // lets go) — structurally identical to a deliberate double-tap-then-hold if we
    // decide "is this a double-tap?" at the second down. So we don't decide there.
    // We decide at the SECOND release: a genuine double-tap is two short pulses;
    // the hardware glitch's phantom press just turns into one long hold whose real
    // release comes much later. Only if both halves are short do we lock.
    private var isLocked = false           // recording continues without the key held
    private var swallowNextRelease = false  // true right after engaging lock, to absorb tap-2's own release
    private var pendingFirstReleaseAt: Date?    // an early release we're tentatively absorbing
    private var pendingSecondPressAt: Date?     // the press that followed it, if any

    // Tunable pending real-hardware validation; the ~470ms figure below is the
    // empirically observed glitch timing this design is built to survive.
    private let earlyReleaseGrace: TimeInterval = 0.8   // existing debounce window
    private let quickTapMax: TimeInterval = 0.3         // press-release under this = "a tap," not "a hold"
    private let doubleTapGap: TimeInterval = 0.5        // max gap between tap-1's release and tap-2's press

    func start(hotkey: String) {
        guard eventTap == nil else { return }   // idempotent
        self.hotkey = hotkey

        let mask = CGEventMask(
            (1 << CGEventType.keyDown.rawValue)     |
            (1 << CGEventType.keyUp.rawValue)       |
            (1 << CGEventType.flagsChanged.rawValue)
        )

        // CGEvent callbacks are C function pointers — no captures allowed.
        // self is threaded through userInfo via passUnretained; safe because
        // HotkeyManager is owned by the app coordinator for the app's lifetime.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                if let refcon {
                    Unmanaged<HotkeyManager>.fromOpaque(refcon)
                        .takeUnretainedValue()
                        .handleCGEvent(type: type, event: event)
                }
                return nil
            },
            userInfo: selfPtr
        ) else { return }   // Accessibility permission not granted

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CGEvent.tapEnable(tap: tap, enable: false)
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        vlog("HotkeyManager.start(): eventTap installed, hotkey=\(hotkey) tapIsEnabled=\(CGEvent.tapIsEnabled(tap: tap))")
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        resetState()
    }

    // MARK: - Private

    private func resetState() {
        isRecording = false
        sessionStartedAt = nil
        isLocked = false
        swallowNextRelease = false
        pendingFirstReleaseAt = nil
        pendingSecondPressAt = nil
        flagsKeyWasDown = false
    }

    private func handleCGEvent(type: CGEventType, event: CGEvent) {
        if isFlagsKey(hotkey) {
            // Modifier-only keys (fn, rightOption, rightCommand) generate .flagsChanged,
            // not .keyDown/.keyUp. flagsChanged fires on ANY modifier change (Shift, Cmd,
            // etc.), so track the specific key's transition and only act when its bit
            // actually flips, ignoring unrelated modifier events.
            guard type == .flagsChanged else { return }
            let isNowDown = flagsKeyIsDown(hotkey, flags: event.flags)
            guard isNowDown != flagsKeyWasDown else { return }
            flagsKeyWasDown = isNowDown
            handleActivation(isDown: isNowDown)
        } else {
            guard type == .keyDown || type == .keyUp else { return }
            // Ignore key repeat — only the initial press matters
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            handleActivation(isDown: type == .keyDown)
        }
    }

    private func handleActivation(isDown: Bool) {
        let now = Date()
        vlog("handleActivation: isDown=\(isDown) isRecording=\(isRecording) isLocked=\(isLocked)")

        if isDown {
            guard isRecording else {
                // Fresh press: start immediately, same latency as plain hold-to-talk always had.
                isRecording = true
                isLocked = false
                sessionStartedAt = now
                onEvent?(.startRecording)
                return
            }
            if isLocked {
                // Begins the "final tap to stop" gesture; nothing fires until its release.
                return
            }
            // Second press while still recording (not locked) — candidate second half
            // of a double-tap. Only meaningful if it follows an absorbed early release.
            if pendingFirstReleaseAt != nil {
                pendingSecondPressAt = now
            }
            return
        }

        // Release:
        guard isRecording else { return }

        if isLocked {
            if swallowNextRelease {
                // This release just completes the lock-engaging gesture itself — not a stop.
                swallowNextRelease = false
                return
            }
            isRecording = false
            isLocked = false
            sessionStartedAt = nil
            vlog("handleActivation: locked-mode tap-to-stop")
            onEvent?(.stopRecording)
            return
        }

        if let secondPressAt = pendingSecondPressAt, let firstReleaseAt = pendingFirstReleaseAt {
            let secondTapDuration = now.timeIntervalSince(secondPressAt)
            let gapBetweenTaps = secondPressAt.timeIntervalSince(firstReleaseAt)
            if secondTapDuration < quickTapMax && gapBetweenTaps < doubleTapGap {
                // Both halves were short pulses close together — a genuine double-tap.
                isLocked = true
                swallowNextRelease = true
                pendingFirstReleaseAt = nil
                pendingSecondPressAt = nil
                vlog("handleActivation: double-tap detected, locking")
                return
            }
            // The second press resolved into a long hold — the early "release" was the
            // hardware glitch, not a deliberate tap. Fall through to the normal stop check.
            pendingFirstReleaseAt = nil
            pendingSecondPressAt = nil
        }

        guard let start = sessionStartedAt, now.timeIntervalSince(start) >= earlyReleaseGrace else {
            // Early release — absorb as noise (covers the hardware dual-fire artifact),
            // but remember it in case a quick second press follows (start of a double-tap).
            pendingFirstReleaseAt = now
            return
        }
        isRecording = false
        sessionStartedAt = nil
        onEvent?(.stopRecording)
    }

    // Returns true for hotkeys detected via .flagsChanged rather than .keyDown/.keyUp
    // (modifier-only physical keys that have no keyCode).
    private func isFlagsKey(_ hotkey: String) -> Bool {
        switch hotkey.lowercased() {
        case "fn", "rightoption", "rightcommand": return true
        default: return false
        }
    }

    // Returns whether the given flags-key hotkey is currently pressed.
    // Uses device-specific bits in the raw CGEventFlags value (NX_DEVICE* from IOLLEvent.h):
    //   NX_DEVICERALTKEYMASK = 0x00000040  (right Option)
    //   NX_DEVICELALTKEYMASK = 0x00000020  (left Option)
    //   NX_DEVICERCMDKEYMASK = 0x00000010  (right Command)
    private func flagsKeyIsDown(_ hotkey: String, flags: CGEventFlags) -> Bool {
        switch hotkey.lowercased() {
        case "fn":
            return flags.contains(.maskSecondaryFn)
        case "rightoption":
            // Require both the device-independent Option bit and the right-side device
            // bit — prevents a left-Option press from matching.
            return flags.contains(.maskAlternate) &&
                   flags.rawValue & 0x00000040 != 0    // NX_DEVICERALTKEYMASK
        case "rightcommand":
            return flags.contains(.maskCommand) &&
                   flags.rawValue & 0x00000010 != 0    // NX_DEVICERCMDKEYMASK
        default:
            return false
        }
    }
}
