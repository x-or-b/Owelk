.pragma library

// Shortcut hints as each platform writes them: "Ctrl+Shift+L" reads "⇧⌘L" on macOS.
function isMac() { return Qt.platform.os === "osx" }
function keys(sequence) {
    const parts = sequence.split("+")
    let key = parts.pop()
    if (key === "Plus") key = "+"
    if (!isMac()) return parts.concat([key]).join("+")
    key = ({Left: "←", Right: "→", Up: "↑", Down: "↓", Return: "↩"})[key] || key
    const symbols = {Ctrl: "⌘", Meta: "⌃", Alt: "⌥", Shift: "⇧"}
    // macOS order: Control, Option, Shift, Command.
    const order = ["Meta", "Alt", "Shift", "Ctrl"]
    return order.filter(function(m) { return parts.indexOf(m) >= 0 }).map(function(m) { return symbols[m] }).join("") + key
}
