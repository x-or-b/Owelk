import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    required property string groupId
    required property var controller
    property var groupData: ({tabs: [], activeTab: ""})
    property string loadedTab: ""
    property alias reader: pane
    property string menuTab: ""
    objectName: "group-" + groupId
    color: "#eeeeee"
    clip: true
    function refresh() {
        if (!pane || loadedTab === groupData.activeTab) return
        if (!loadedTab.length && controller.suspended) return
        loadedTab = groupData.activeTab
        const t = groupData.tabs.find(function(t) { return t.id === loadedTab })
        pane.restore(t || {})
    }
    function tabIndexAt(x) { return Math.max(0, Math.min(groupData.tabs.length, Math.floor((x + tabs.contentX + 80) / 160))) }
    onGroupDataChanged: {
        refresh()
        Qt.callLater(function() {
            const at = root.groupData.tabs.findIndex(function(t) { return t.id === root.groupData.activeTab })
            if (at >= 0) tabs.positionViewAtIndex(at, ListView.Contain)
        })
    }
    Component.onCompleted: refresh()
    Connections { target: root.controller; function onSuspendedChanged() { if (!root.controller.suspended) root.refresh() } }
    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        ListView {
            id: tabs
            objectName: "tabBar"
            Layout.fillWidth: true
            Layout.preferredHeight: 32
            orientation: ListView.Horizontal
            clip: true
            model: root.groupData.tabs
            ScrollBar.horizontal: ScrollBar { height: 3 }
            delegate: Rectangle {
                id: tabItem
                required property var modelData
                width: 160
                height: 32
                objectName: "tab-" + modelData.id
                color: modelData.id === root.groupData.activeTab ? "#ffffff" : "#e9e9e9"
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.controller.activeGroup === root.groupId && modelData.id === root.loadedTab ? "#777777" : "#d5d5d5" }
                Label { anchors.left: parent.left; anchors.leftMargin: 10; anchors.right: close.left; anchors.verticalCenter: parent.verticalCenter; text: researchStore.fileName(modelData.source); elide: Text.ElideMiddle; font.pixelSize: 12 }
                MouseArea {
                    id: pointer
                    anchors.fill: parent
                    anchors.rightMargin: 25
                    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                    hoverEnabled: true
                    preventStealing: true
                    property point start
                    property bool moving: false
                    property bool cancelled: false
                    onPressed: function(mouse) {
                        start = mapToItem(null, mouse.x, mouse.y); moving = false; cancelled = false
                        tabItem.forceActiveFocus()
                    }
                    onPositionChanged: function(mouse) {
                        if (!pressed || cancelled || pressedButtons !== Qt.LeftButton) return
                        const p = mapToItem(null, mouse.x, mouse.y)
                        if (Math.abs(p.x - start.x) + Math.abs(p.y - start.y) > 8) moving = true
                        if (moving) root.controller.dragTab(modelData.id, p.x, p.y)
                    }
                    onReleased: function(mouse) {
                        if (cancelled) return
                        if (moving) {
                            const point = mapToItem(null, mouse.x, mouse.y)
                            root.controller.dragTab(modelData.id, point.x, point.y)
                            root.controller.finishDrag(false)
                        }
                        else if (mouse.button === Qt.RightButton) { root.menuTab = modelData.id; tabMenu.popup() }
                        else if (mouse.button === Qt.MiddleButton) Qt.callLater(function() { root.controller.closeTab(modelData.id) })
                        else Qt.callLater(function() { root.controller.activateTab(modelData.id) })
                        moving = false
                    }
                    onCanceled: { cancelled = true; moving = false; root.controller.finishDrag(true) }
                }
                Keys.onEscapePressed: { pointer.cancelled = true; pointer.moving = false; root.controller.finishDrag(true) }
                ToolButton {
                    id: close
                    anchors.right: parent.right
                    width: 25; height: 32
                    text: "×"
                    Accessible.name: "Close tab"
                    onClicked: { const id = modelData.id; Qt.callLater(function() { root.controller.closeTab(id) }) }
                }
                ToolTip.visible: pointer.containsMouse && !pointer.pressed
                ToolTip.delay: 450
                ToolTip.text: modelData.source
            }
            Label { visible: !tabs.count; anchors.centerIn: parent; text: "No open tabs"; color: "#777777" }
        }
        ReaderPane {
            id: pane
            Layout.fillWidth: true
            Layout.fillHeight: true
            managed: true
            isActive: !root.controller.suspended && root.controller.activeGroup === root.groupId
            onActivated: root.controller.activateGroup(root.groupId)
            onFileChosen: function(source) { root.controller.activateGroup(root.groupId); root.controller.openDocument(source) }
            onChanged: if (!root.controller.syncing) root.controller.changed()
        }
    }
    Menu {
        id: tabMenu
        MenuItem { text: "Close Tab"; onTriggered: root.controller.closeTab(root.menuTab) }
        MenuItem { text: "Duplicate to Right Split"; onTriggered: { root.controller.activateTab(root.menuTab); root.controller.duplicateSplit("right") } }
        MenuItem { text: "Duplicate to Bottom Split"; onTriggered: { root.controller.activateTab(root.menuTab); root.controller.duplicateSplit("bottom") } }
    }
    Rectangle {
        readonly property var target: root.controller.dropTarget
        readonly property string edge: target ? target.edge : ""
        visible: !!target && target.group === root.groupId
        x: edge === "right" ? parent.width / 2 : 0
        y: edge === "bottom" ? parent.height / 2 : 0
        width: edge === "left" || edge === "right" ? parent.width / 2 : parent.width
        height: edge === "top" || edge === "bottom" ? parent.height / 2 : target && target.index !== undefined ? 32 : parent.height
        color: "#33555555"
        border.color: "#777777"
        z: 10
        Label { anchors.centerIn: parent; text: parent.edge === "center" ? "Move tab here" : "Split " + parent.edge; color: "#333333" }
    }
}
