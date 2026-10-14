import AppKit

@MainActor
func browserClipboardInteractionChecks() -> [(String, Bool)] {
    var checks: [(String, Bool)] = []
    let inputs: [(String, NSEvent.ModifierFlags, String, Bool)] = [
        ("command_v", .command, "v", true),
        ("caps_lock", [.command, .capsLock], "V", true),
        ("guest_control_v", .control, "v", false),
        ("plain_v", [], "v", false),
        ("shift_command_v", [.command, .shift], "v", false),
        ("option_command_v", [.command, .option], "v", false),
        ("control_command_v", [.command, .control], "v", false),
        ("command_c", .command, "c", false)
    ]
    for (name, modifiers, character, expected) in inputs {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                          timestamp: 0, windowNumber: 0, context: nil,
                                          characters: character, charactersIgnoringModifiers: character,
                                          isARepeat: false, keyCode: 9) else {
            checks.append(("browser_clipboard_event_fixture", false)); continue
        }
        checks.append(("browser_clipboard_shortcut_" + name, BrowserVirtualMachineView.isHostPaste(event) == expected))
    }
    let view = BrowserVirtualMachineView()
    var pasteRequests = 0
    view.onPasteFromMac = { pasteRequests += 1 }
    for repeating in [false, true, true] {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                          timestamp: 0, windowNumber: 0, context: nil,
                                          characters: "v", charactersIgnoringModifiers: "v",
                                          isARepeat: repeating, keyCode: 9) else {
            checks.append(("browser_clipboard_repeat_fixture", false)); continue
        }
        view.keyDown(with: event)
    }
    checks.append(("browser_clipboard_key_repeat_does_not_paste_again", pasteRequests == 1))
    view.paste(nil)
    checks.append(("browser_clipboard_explicit_menu_paste", pasteRequests == 2))
    return checks
}
