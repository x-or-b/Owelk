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

// Time read, as "45 min" or "2 h 5 min".
function duration(seconds) {
    const minutes = Math.floor(seconds / 60)
    if (minutes < 60) return qsTr("%1 min").arg(minutes)
    const hours = Math.floor(minutes / 60)
    return minutes % 60 ? qsTr("%1 h %2 min").arg(hours).arg(minutes % 60) : qsTr("%1 h").arg(hours)
}
