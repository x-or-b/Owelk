import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui
import "Shortcuts.js" as Shortcuts
import "Platform.js" as Platform

// Click a shortcut, then press the new keys (Esc cancels, Backspace turns it off).
ColumnLayout {
    id: root
    objectName: "shortcutSettings"
    spacing: 22
    property var overrides: Shortcuts.parse(researchStore.setting("shortcuts"))
    property string recording: ""
    readonly property var clashes: Shortcuts.conflicts(overrides, Qt.platform.os)
    function store(id, keys) {
        const next = Object.assign({}, overrides)
        if (keys === Shortcuts.defaultKeys(id, Qt.platform.os)) delete next[id]; else next[id] = keys
        overrides = next
        researchStore.setSetting("shortcuts", JSON.stringify(next))
    }
    function resetAll() { overrides = ({}); researchStore.setSetting("shortcuts", "{}") }
    SettingsGroup {
        title: "Keyboard shortcuts"
        note: Object.keys(root.clashes).length ? "Some shortcuts are used twice (in red); only one of them will work."
            : "Click a shortcut and press the new keys. Esc cancels, Backspace turns it off."
        noteColor: Object.keys(root.clashes).length ? Theme.danger : Theme.textTertiary
        Repeater {
            model: Shortcuts.actions
            delegate: SettingsRow {
                id: shortcutRow
                required property var modelData
                readonly property string current: Shortcuts.keys(modelData.id, root.overrides, Qt.platform.os)
                readonly property bool clash: current.length > 0 && !!root.clashes[current]
                implicitHeight: Theme.controlHeight + 8
                label: modelData.name
                Button {
                    id: keyButton
                    objectName: "shortcut-" + shortcutRow.modelData.id
                    Layout.preferredWidth: 140
                    text: root.recording === shortcutRow.modelData.id ? "Press keys…"
                        : shortcutRow.current.length ? Platform.keys(shortcutRow.current) : "None"
                    primary: root.recording === shortcutRow.modelData.id
                    palette.buttonText: shortcutRow.clash ? Theme.danger : Theme.text
                    ToolTip.visible: hovered && shortcutRow.clash; ToolTip.delay: 300
                    ToolTip.text: shortcutRow.clash ? "Also used by " + root.clashes[shortcutRow.current].filter(function(n) { return n !== shortcutRow.modelData.name }).join(", ") : ""
                    onClicked: { root.recording = shortcutRow.modelData.id; keyButton.forceActiveFocus() }
                    Keys.onPressed: function(event) {
                        if (root.recording !== shortcutRow.modelData.id) return
                        event.accepted = true
                        if (event.key === Qt.Key_Escape) { root.recording = ""; return }
                        if (event.key === Qt.Key_Backspace) { root.store(shortcutRow.modelData.id, ""); root.recording = ""; return }
                        const keys = Shortcuts.fromEvent(event.key, event.modifiers, event.text)
                        if (!keys.length) return
                        root.store(shortcutRow.modelData.id, keys)
                        root.recording = ""
                    }
                    onActiveFocusChanged: if (!activeFocus && root.recording === shortcutRow.modelData.id) root.recording = ""
                }
                IconButton {
                    icon.name: "reset"; description: "Default: " + Platform.keys(Shortcuts.defaultKeys(shortcutRow.modelData.id, Qt.platform.os))
                    opacity: shortcutRow.current !== Shortcuts.defaultKeys(shortcutRow.modelData.id, Qt.platform.os) ? 1 : 0
                    enabled: opacity > 0
                    onClicked: root.store(shortcutRow.modelData.id, Shortcuts.defaultKeys(shortcutRow.modelData.id, Qt.platform.os))
                }
            }
        }
    }
    Button { objectName: "resetShortcuts"; Layout.alignment: Qt.AlignRight; text: "Reset All"; onClicked: root.resetAll() }
}
