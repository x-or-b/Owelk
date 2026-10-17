.pragma library

// Customizable shortcuts: one list feeds the menus and Settings → Shortcuts. "Ctrl" is Command on macOS.
// Linux and Windows defaults avoid Ctrl+Alt+arrows (desktops use them to switch workspaces) and
// Ctrl+Alt+\ (AltGr on many keyboards).
// Names are shown through qsTranslate("Shortcuts", …) (QT_TR_NOOP marks them for tools/hangul.py).
const groups = [QT_TR_NOOP("Search and places"), QT_TR_NOOP("Tabs"), QT_TR_NOOP("Splits"), QT_TR_NOOP("Panels"), QT_TR_NOOP("Reading"), QT_TR_NOOP("Notes and AI")]
const actions = [
    {id: "search", group: "Search and places", name: QT_TR_NOOP("Search"), mac: "Ctrl+K", other: "Ctrl+K"},
    {id: "commands", group: "Search and places", name: QT_TR_NOOP("Command Palette"), mac: "Ctrl+Shift+P", other: "Ctrl+Shift+P"},
    {id: "home", group: "Search and places", name: QT_TR_NOOP("Home"), mac: "Ctrl+Shift+H", other: "Ctrl+Shift+H"},
    {id: "library", group: "Search and places", name: QT_TR_NOOP("Library"), mac: "Ctrl+Shift+L", other: "Ctrl+Shift+L"},
    {id: "jumpBack", group: "Search and places", name: QT_TR_NOOP("Back"), mac: "Ctrl+[", other: "Alt+Left"},
    {id: "jumpForward", group: "Search and places", name: QT_TR_NOOP("Forward"), mac: "Ctrl+]", other: "Alt+Right"},
    {id: "openWeb", group: "Search and places", name: QT_TR_NOOP("Open Web Page"), mac: "Ctrl+L", other: "Ctrl+L"},
    {id: "newTab", group: "Tabs", name: QT_TR_NOOP("New Tab"), mac: "Ctrl+T", other: "Ctrl+T"},
    {id: "closeTab", group: "Tabs", name: QT_TR_NOOP("Close Tab"), mac: "Ctrl+W", other: "Ctrl+W"},
    {id: "reopenTab", group: "Tabs", name: QT_TR_NOOP("Reopen Closed Tab"), mac: "Ctrl+Shift+T", other: "Ctrl+Shift+T"},
    {id: "nextTab", group: "Tabs", name: QT_TR_NOOP("Next Tab"), mac: "Ctrl+Alt+Right", other: "Ctrl+PgDown"},
    {id: "previousTab", group: "Tabs", name: QT_TR_NOOP("Previous Tab"), mac: "Ctrl+Alt+Left", other: "Ctrl+PgUp"},
    {id: "splitRight", group: "Splits", name: QT_TR_NOOP("Duplicate to Right Split"), mac: "Ctrl+\\", other: "Ctrl+\\"},
    {id: "splitDown", group: "Splits", name: QT_TR_NOOP("Duplicate to Bottom Split"), mac: "Ctrl+Alt+\\", other: "Ctrl+Shift+\\"},
    {id: "moveRight", group: "Splits", name: QT_TR_NOOP("Move Tab to Right Split"), mac: "Ctrl+Shift+Alt+Right", other: "Ctrl+Shift+Alt+."},
    {id: "moveDown", group: "Splits", name: QT_TR_NOOP("Move Tab to Bottom Split"), mac: "Ctrl+Shift+Alt+Down", other: "Ctrl+Shift+Alt+,"},
    {id: "nextSplit", group: "Splits", name: QT_TR_NOOP("Focus Next Split"), mac: "Ctrl+Alt+Down", other: "Ctrl+Alt+."},
    {id: "previousSplit", group: "Splits", name: QT_TR_NOOP("Focus Previous Split"), mac: "Ctrl+Alt+Up", other: "Ctrl+Alt+,"},
    {id: "tabsPanel", group: "Panels", name: QT_TR_NOOP("Vertical Tabs"), mac: "Ctrl+Shift+B", other: "Ctrl+Shift+B"},
    {id: "filesPanel", group: "Panels", name: QT_TR_NOOP("Library Panel"), mac: "Ctrl+Shift+E", other: "Ctrl+Shift+E"},
    {id: "documentPanel", group: "Panels", name: QT_TR_NOOP("Document Panel"), mac: "Ctrl+Shift+O", other: "Ctrl+Shift+O"},
    {id: "annotations", group: "Panels", name: QT_TR_NOOP("Annotations"), mac: "Ctrl+Shift+M", other: "Ctrl+Shift+M"},
    {id: "aiPanel", group: "Panels", name: QT_TR_NOOP("AI Chat"), mac: "Ctrl+Shift+I", other: "Ctrl+Shift+I"},
    {id: "threadsPanel", group: "Panels", name: QT_TR_NOOP("Threads"), mac: "Ctrl+Shift+J", other: "Ctrl+Shift+J"},
    {id: "previousPage", group: "Reading", name: QT_TR_NOOP("Previous Page"), mac: "Left", other: "Left"},
    {id: "nextPage", group: "Reading", name: QT_TR_NOOP("Next Page"), mac: "Right", other: "Right"},
    {id: "fitWidth", group: "Reading", name: QT_TR_NOOP("Fit Width"), mac: "Ctrl+0", other: "Ctrl+0"},
    {id: "fitPage", group: "Reading", name: QT_TR_NOOP("Fit Page"), mac: "Ctrl+Alt+0", other: "Ctrl+Alt+0"},
    {id: "highlight", group: "Reading", name: QT_TR_NOOP("Highlight Selection"), mac: "Ctrl+Meta+H", other: "Ctrl+Alt+H"},
    {id: "comment", group: "Reading", name: QT_TR_NOOP("Comment"), mac: "Ctrl+Meta+M", other: "Ctrl+Alt+M"},
    {id: "markRegion", group: "Reading", name: QT_TR_NOOP("Mark Region"), mac: "Ctrl+Shift+C", other: "Ctrl+Shift+C"},
    {id: "darkPages", group: "Reading", name: QT_TR_NOOP("Dark Pages"), mac: "Ctrl+Shift+D", other: "Ctrl+Shift+D"},
    {id: "newNote", group: "Notes and AI", name: QT_TR_NOOP("New Note"), mac: "Ctrl+Shift+N", other: "Ctrl+Shift+N"},
    {id: "askAi", group: "Notes and AI", name: QT_TR_NOOP("Ask AI (the selection, or the paper)"), mac: "Ctrl+Shift+A", other: "Ctrl+Shift+A"}
]

function defaultKeys(id, os) {
    const action = actions.find(function(a) { return a.id === id })
    return action ? (os === "osx" ? action.mac : action.other) : ""
}
// The shortcut in effect: the reader's choice ("" disables it), or the default.
function keys(id, overrides, os) {
    return overrides && Object.prototype.hasOwnProperty.call(overrides, id) ? overrides[id] : defaultKeys(id, os)
}
function parse(json) {
    try { const value = JSON.parse(json || "{}"); return value && typeof value === "object" ? value : {} }
    catch (e) { return {} }
}
// Shortcuts that cannot be changed (the system's own, and browser conventions), so nothing else may take them.
// Ctrl+1…8 select a tab and Ctrl+9 the last one, as in browsers.
const fixed = [
    {keys: "Ctrl+O", name: QT_TR_NOOP("Open PDF")}, {keys: "Ctrl+,", name: QT_TR_NOOP("Settings")},
    {keys: "Ctrl+Q", name: QT_TR_NOOP("Quit")}, {keys: "Ctrl+F", name: QT_TR_NOOP("Find")},
    {keys: "Ctrl+=", name: QT_TR_NOOP("Zoom In")}, {keys: "Ctrl+-", name: QT_TR_NOOP("Zoom Out")},
    {keys: "Ctrl+C", name: QT_TR_NOOP("Copy")}, {keys: "Ctrl+X", name: QT_TR_NOOP("Cut")},
    {keys: "Ctrl+V", name: QT_TR_NOOP("Paste")}, {keys: "Ctrl+A", name: QT_TR_NOOP("Select All")},
    {keys: "Ctrl+Z", name: QT_TR_NOOP("Undo")}, {keys: "Ctrl+Shift+Z", name: QT_TR_NOOP("Redo")},
    {keys: "Ctrl+Shift+]", name: QT_TR_NOOP("Next Tab")}, {keys: "Ctrl+Shift+[", name: QT_TR_NOOP("Previous Tab")}
]
// Actions that share a shortcut, as {keys: [names]} (only for keys used more than once).
function conflicts(overrides, os) {
    const used = {}
    for (let n = 1; n <= 9; ++n) used["Ctrl+" + n] = [n === 9 ? QT_TR_NOOP("Last Tab") : "Tab " + n]
    fixed.forEach(function(f) { used[f.keys] = [f.name] })
    if (os !== "osx") used["Ctrl+Y"] = [QT_TR_NOOP("Redo")]
    actions.forEach(function(a) {
        const k = keys(a.id, overrides, os)
        if (k.length) used[k] = (used[k] || []).concat([a.name])
    })
    const result = {}
    Object.keys(used).forEach(function(k) { if (used[k].length > 1) result[k] = used[k] })
    return result
}
// A key press as a shortcut text ("Ctrl+Shift+K"); empty for modifier-only presses.
function fromEvent(key, modifiers, text) {
    const names = {}
    names[Qt.Key_Left] = "Left"; names[Qt.Key_Right] = "Right"; names[Qt.Key_Up] = "Up"; names[Qt.Key_Down] = "Down"
    names[Qt.Key_PageUp] = "PgUp"; names[Qt.Key_PageDown] = "PgDown"; names[Qt.Key_Home] = "Home"; names[Qt.Key_End] = "End"
    names[Qt.Key_Tab] = "Tab"; names[Qt.Key_Space] = "Space"; names[Qt.Key_Return] = "Return"; names[Qt.Key_Enter] = "Enter"
    names[Qt.Key_Delete] = "Del"; names[Qt.Key_Backslash] = "\\"; names[Qt.Key_BracketLeft] = "["; names[Qt.Key_BracketRight] = "]"
    names[Qt.Key_Comma] = ","; names[Qt.Key_Period] = "."; names[Qt.Key_Slash] = "/"; names[Qt.Key_Semicolon] = ";"
    names[Qt.Key_Minus] = "-"; names[Qt.Key_Equal] = "="; names[Qt.Key_Apostrophe] = "'"
    if ([Qt.Key_Control, Qt.Key_Shift, Qt.Key_Alt, Qt.Key_Meta, Qt.Key_AltGr].indexOf(key) >= 0) return ""
    let name = names[key]
    if (!name && key >= Qt.Key_F1 && key <= Qt.Key_F12) name = "F" + (key - Qt.Key_F1 + 1)
    if (!name && ((key >= Qt.Key_A && key <= Qt.Key_Z) || (key >= Qt.Key_0 && key <= Qt.Key_9))) name = String.fromCharCode(key)
    if (!name) return ""
    const parts = []
    if (modifiers & Qt.ControlModifier) parts.push("Ctrl")
    if (modifiers & Qt.MetaModifier) parts.push("Meta")
    if (modifiers & Qt.ShiftModifier) parts.push("Shift")
    if (modifiers & Qt.AltModifier) parts.push("Alt")
    // A shortcut needs a modifier, except function keys.
    if (!parts.length && !/^F\d+$/.test(name)) return ""
    return parts.concat([name]).join("+")
}
