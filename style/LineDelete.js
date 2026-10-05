.pragma library

// Delete to the start of the line, as macOS does with Cmd+Backspace (Ctrl+Shift+Backspace on
// Linux and Windows, where Ctrl+Backspace already deletes a word). Cmd+Delete (Ctrl+Shift+Delete)
// deletes to the end of the line. Works on TextField and TextArea; returns true when handled.
function handle(control, event, multiline) {
    if (event.key !== Qt.Key_Backspace && event.key !== Qt.Key_Delete) return false
    const mods = event.modifiers
    const mac = Qt.platform.os === "osx"
    // On macOS, Qt reports Cmd as ControlModifier.
    const wanted = mac ? (mods & Qt.ControlModifier) && !(mods & Qt.ShiftModifier) && !(mods & Qt.AltModifier)
                       : (mods & Qt.ControlModifier) && (mods & Qt.ShiftModifier) && !(mods & Qt.AltModifier)
    if (!wanted || control.readOnly) return false
    if (control.selectedText.length) { control.remove(control.selectionStart, control.selectionEnd); return true }
    const at = control.cursorPosition
    let start = 0, end = control.length
    if (multiline) {
        // The visual line the cursor is on (wrapped text deletes only what is on that row).
        const r = control.cursorRectangle
        start = control.positionAt(control.leftPadding, r.y + r.height / 2)
        end = control.positionAt(control.width - control.rightPadding, r.y + r.height / 2)
    }
    if (event.key === Qt.Key_Backspace) {
        // Already at the line start: join with the line above, like macOS.
        if (start >= at) start = Math.max(0, at - 1)
        control.remove(start, at)
    } else {
        if (end <= at) end = Math.min(control.length, at + 1)
        control.remove(at, end)
    }
    return true
}
