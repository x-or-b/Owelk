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
    Label {
        Layout.fillWidth: true
        text: Object.keys(root.clashes).length ? qsTr("Some shortcuts are used twice (in red); only one of them will work.")
            : qsTr("Click a shortcut and press the new keys. Esc cancels, Backspace turns it off.")
        wrapMode: Text.Wrap
        font.pixelSize: Theme.fontSmall
        color: Object.keys(root.clashes).length ? Theme.danger : Theme.textTertiary
    }
    // One section per kind of action.
    Repeater {
        model: Shortcuts.groups
        delegate: SettingsGroup {
            id: section
            required property string modelData
            title: qsTranslate("Shortcuts", section.modelData)
            Repeater {
                model: Shortcuts.actions.filter(function(a) { return a.group === section.modelData })
                delegate: SettingsRow {
                    id: shortcutRow
                    required property var modelData
                    readonly property string current: Shortcuts.keys(modelData.id, root.overrides, Qt.platform.os)
                    readonly property bool clash: current.length > 0 && !!root.clashes[current]
                    implicitHeight: Theme.controlHeight + 8
                    label: qsTranslate("Shortcuts", modelData.name)
                    Button {
                        id: keyButton
                        objectName: "shortcut-" + shortcutRow.modelData.id
                        Layout.preferredWidth: 140
                        text: root.recording === shortcutRow.modelData.id ? qsTr("Press keys…")
                            : shortcutRow.current.length ? Platform.keys(shortcutRow.current) : qsTr("None")
                        primary: root.recording === shortcutRow.modelData.id
                        palette.buttonText: shortcutRow.clash ? Theme.danger : Theme.text
                        ToolTip.visible: hovered && shortcutRow.clash; ToolTip.delay: 300
                        ToolTip.text: shortcutRow.clash ? qsTr("Also used by ") + root.clashes[shortcutRow.current].filter(function(n) { return n !== shortcutRow.modelData.name }).join(", ") : ""
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
                        icon.name: "reset"; description: qsTr("Default: ") + Platform.keys(Shortcuts.defaultKeys(shortcutRow.modelData.id, Qt.platform.os))
                        opacity: shortcutRow.current !== Shortcuts.defaultKeys(shortcutRow.modelData.id, Qt.platform.os) ? 1 : 0
                        enabled: opacity > 0
                        onClicked: root.store(shortcutRow.modelData.id, Shortcuts.defaultKeys(shortcutRow.modelData.id, Qt.platform.os))
                    }
                }
            }
        }
    }
    Button { objectName: "resetShortcuts"; Layout.alignment: Qt.AlignRight; text: qsTr("Reset All"); onClicked: root.resetAll() }
}
