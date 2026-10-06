import Owelk.Ui
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Suggested groups, editable before anything is applied (AI tab and paper organizing). Each group can
// be renamed or left out; each member can be unchecked or moved to another group; items in no group
// are listed under "Not grouped" and can be added to one. Edits change `groups` in place and bump
// `revision`; Apply takes kept groups with their remaining ids.
ColumnLayout {
    id: root
    // [{name, keep, ids}]
    property var groups: []
    // [{id, title}]
    property var items: []
    // Optional: a short note for a group name (e.g. "Existing" / "New"), and whether to emphasise it.
    property var badge: null
    property int revision: 0
    // Kept by hand (a binding would break when a group is added in place).
    property int groupCount: 0
    onGroupsChanged: groupCount = groups.length
    readonly property var ungrouped: (revision, items.filter(function(item) {
        return !groups.some(function(g) { return g.ids.indexOf(item.id) >= 0 })
    }))
    spacing: 8
    function title(id) { return (items.find(function(i) { return i.id === id }) || {title: id}).title }
    // Moves an item into group `to` (-1 leaves it out of every group).
    function move(id, to) {
        groups.forEach(function(g) { const at = g.ids.indexOf(id); if (at >= 0) g.ids.splice(at, 1) })
        if (to >= 0 && to < groups.length) groups[to].ids.push(id)
        revision++
    }
    function addGroup(firstId) {
        groups.push({name: "New Group", keep: true, ids: []})
        const at = groups.length - 1
        groupCount = groups.length
        if (firstId !== undefined) move(firstId, at)
        else revision++
        // Name it right away; from the menu, once the menu has given focus back.
        focusGroup = at
        if (!moveMenu.visible) Qt.callLater(focusPending)
        return at
    }
    property int focusGroup: -1
    function focusPending() {
        const at = focusGroup
        focusGroup = -1
        if (at < 0) return
        list.positionViewAtIndex(at, ListView.Contain)
        const group = list.itemAtIndex(at)
        if (group) { group.nameField.selectAll(); group.nameField.forceActiveFocus() }
    }
    // One menu for every item: where it should go.
    Menu {
        id: moveMenu
        objectName: "groupMoveMenu"
        property string itemId: ""
        property int from: -1
        Instantiator {
            model: root.groups.length
            delegate: MenuItem {
                required property int index
                objectName: "groupMoveTo-" + index
                visible: index !== moveMenu.from
                height: visible ? implicitHeight : 0
                text: (root.revision, root.groups[index] ? root.groups[index].name : "")
                onTriggered: root.move(moveMenu.itemId, index)
            }
            onObjectAdded: function(index, object) { moveMenu.insertItem(index, object) }
            onObjectRemoved: function(index, object) { moveMenu.removeItem(object) }
        }
        MenuSeparator {}
        MenuItem { objectName: "groupMoveNew"; text: "New Group"; onTriggered: root.addGroup(moveMenu.itemId) }
        onClosed: Qt.callLater(root.focusPending)
        MenuItem { objectName: "groupMoveOut"; text: "Leave Out"; visible: moveMenu.from >= 0; height: visible ? implicitHeight : 0; onTriggered: root.move(moveMenu.itemId, -1) }
    }
    function showMoveMenu(id, from, anchor) {
        moveMenu.itemId = id
        moveMenu.from = from
        moveMenu.popup(anchor, 0, anchor.height)
    }
    ListView {
        id: list
        objectName: "groupEditorList"
        Layout.fillWidth: true; Layout.fillHeight: true
        clip: true
        spacing: 12
        // Only the number of groups: edits inside a group update its rows without rebuilding the list.
        model: root.groupCount
        ScrollBar.vertical: ScrollBar {}
        delegate: ColumnLayout {
            id: group
            required property int index
            readonly property var entry: (root.revision, root.groups[index])
            property alias nameField: name
            width: ListView.view.width - 10
            spacing: 2
            RowLayout {
                Layout.fillWidth: true
                CheckBox {
                    objectName: "groupKeep-" + group.index
                    checked: group.entry.keep
                    onToggled: { root.groups[group.index].keep = checked; root.revision++ }
                    ToolTip.visible: hovered; ToolTip.delay: 500; ToolTip.text: checked ? "Apply this group" : "Skip this group"
                }
                TextField {
                    id: name
                    objectName: "groupName-" + group.index
                    Layout.fillWidth: true
                    text: group.entry.name
                    maximumLength: 120
                    enabled: group.entry.keep
                    onTextEdited: { root.groups[group.index].name = text; root.revision++ }
                }
                Label {
                    objectName: "groupKind-" + group.index
                    readonly property var note: root.badge ? (root.revision, root.badge(group.entry.name)) : null
                    visible: !!note
                    text: note ? note.text : ""
                    font.pixelSize: Theme.fontCaption
                    color: note && note.emphasis ? Theme.accent : Theme.textTertiary
                }
                Label { text: group.entry.ids.length; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary }
            }
            Repeater {
                model: (root.revision, group.entry.ids.slice())
                delegate: RowLayout {
                    id: member
                    required property string modelData
                    required property int index
                    Layout.fillWidth: true; Layout.leftMargin: 28
                    spacing: 4
                    opacity: group.entry.keep ? 1 : .5
                    // Unchecking leaves it out of this group; it then waits under Not grouped.
                    CheckBox {
                        objectName: "groupMemberCheck-" + group.index + "-" + member.index
                        checked: true
                        onToggled: if (!checked) root.move(member.modelData, -1)
                    }
                    Label {
                        Layout.fillWidth: true
                        elide: Text.ElideRight; font.pixelSize: Theme.fontSmall; color: Theme.textSecondary
                        text: root.title(member.modelData)
                        TapHandler { acceptedButtons: Qt.RightButton; onTapped: root.showMoveMenu(member.modelData, group.index, moveButton) }
                    }
                    IconButton {
                        id: moveButton
                        objectName: "groupMemberMove-" + group.index + "-" + member.index
                        icon.name: "down"; implicitWidth: 22; implicitHeight: 20
                        description: "Move to another group"
                        onClicked: root.showMoveMenu(member.modelData, group.index, moveButton)
                    }
                }
            }
        }
        footer: ColumnLayout {
            width: list.width - 10
            spacing: 2
            Item { implicitHeight: 6 }
            RowLayout {
                Layout.fillWidth: true
                visible: root.ungrouped.length > 0
                Label { Layout.fillWidth: true; text: "Not grouped  " + root.ungrouped.length; font.pixelSize: Theme.fontSmall; font.weight: Font.DemiBold; color: Theme.textSecondary }
            }
            Repeater {
                model: root.ungrouped
                delegate: RowLayout {
                    id: loose
                    required property var modelData
                    required property int index
                    Layout.fillWidth: true; Layout.leftMargin: 28
                    spacing: 4
                    Label { Layout.fillWidth: true; elide: Text.ElideRight; font.pixelSize: Theme.fontSmall; color: Theme.textTertiary; text: loose.modelData.title }
                    IconButton {
                        id: addButton
                        objectName: "ungroupedAdd-" + loose.index
                        icon.name: "add"; implicitWidth: 22; implicitHeight: 20
                        description: "Add to a group"
                        onClicked: root.showMoveMenu(loose.modelData.id, -1, addButton)
                    }
                }
            }
            Button {
                objectName: "newGroupButton"
                Layout.topMargin: 6
                text: "New Group"
                onClicked: root.addGroup()
            }
        }
    }
}
