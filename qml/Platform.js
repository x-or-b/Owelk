.pragma library

// Shortcut hints as each platform writes them: "Ctrl+Shift+L" reads "⇧⌘L" on macOS.
function isMac() { return Qt.platform.os === "osx" }
function keys(sequence) {
    if (!isMac()) return sequence
    const parts = sequence.split("+")
    const key = parts.pop()
    const symbols = {Ctrl: "⌘", Meta: "⌃", Alt: "⌥", Shift: "⇧"}
    // macOS order: Control, Option, Shift, Command.
    const order = ["Meta", "Alt", "Shift", "Ctrl"]
    return order.filter(function(m) { return parts.indexOf(m) >= 0 }).map(function(m) { return symbols[m] }).join("") + key
}
