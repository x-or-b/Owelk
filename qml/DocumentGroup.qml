import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "UiTheme.js" as Theme

Rectangle {
    id: root
    required property string groupId
    required property var controller
    property var groupData: ({tabs: [], activeTab: ""})
    property string loadedTab: ""
    property string loadedSource: ""
    readonly property bool isHome: groupData.tabs.some(function(t) { return t.id === groupData.activeTab && t.kind === "home" })
    readonly property bool isWeb: groupData.tabs.some(function(t) { return t.id === groupData.activeTab && t.kind === "web" })
    readonly property var webPane: webLoader.item
    // Cmd+L on a new web tab: focus the address bar once the page has loaded its pane.
    property bool focusAddressWhenReady: false
    function focusAddress() {
        if (webLoader.item) webLoader.item.focusAddress()
        else focusAddressWhenReady = true
    }
    property alias reader: pane
    property string menuTab: ""
    objectName: "group-" + groupId
    color: Theme.surfaceChrome
    radius: Theme.cornerRadius
    clip: true
    function refresh() {
        if (!pane) return
        const t = groupData.tabs.find(function(t) { return t.id === groupData.activeTab })
        if (loadedTab === groupData.activeTab && loadedSource === (t ? t.source : "")) return
        if (!loadedTab.length && controller.suspended) return
        const switched = loadedTab !== groupData.activeTab
        loadedTab = groupData.activeTab
        loadedSource = t ? t.source : ""
        if (t && t.kind === "web") {
            // The page itself reports navigation; only a tab switch loads a new address.
            if (switched) Qt.callLater(function() { if (webLoader.item) { webLoader.item.tabId = t.id; webLoader.item.open(t.source) } })
            return
        }
        pane.restore(t && t.kind !== "home" ? t : {})
    }
    function focusHome() { if (homeLoader.item) homeLoader.item.focusSearch() }
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
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 32
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
                radius: Theme.cornerRadius
                color: modelData.id === root.groupData.activeTab ? Theme.surface : Theme.surfaceSelected
                Rectangle { anchors.bottom: parent.bottom; x: Theme.cornerRadius; width: parent.width - 2 * x; height: 1; color: root.controller.activeGroup === root.groupId && modelData.id === root.loadedTab ? Theme.tabUnderlineActive : Theme.tabUnderline }
                Label { anchors.left: parent.left; anchors.leftMargin: 10; anchors.right: close.left; anchors.verticalCenter: parent.verticalCenter; text: modelData.kind === "home" ? "Home" : modelData.kind === "web" ? (modelData.title || modelData.source.replace(/^https?:\/\/(www\.)?/, "")) : (researchStore.documentsRevision, researchStore.displayName(modelData.source)); elide: Text.ElideRight; font.pixelSize: 12 }
                MouseArea {
                    id: pointer
                    anchors.fill: parent
                    anchors.rightMargin: close.width + close.anchors.rightMargin
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
                UiControls.ToolButton {
                    id: close
                    objectName: "closeTabButton-" + modelData.id
                    hoverEnabled: true
                    anchors.right: parent.right
                    anchors.rightMargin: 4
                    anchors.verticalCenter: parent.verticalCenter
                    width: 24; height: 24
                    text: "×"
                    Accessible.name: "Close tab"
                    background: Rectangle {
                        color: close.down ? Theme.accentSurface : tabItem.color
                        border.width: 1
                        border.color: close.hovered || close.visualFocus ? Theme.accent : "transparent"
                    }
                    contentItem: Text { text: "×"; color: close.hovered ? Theme.textStrong : Theme.textTertiary; font: close.font; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    onClicked: { const id = modelData.id; Qt.callLater(function() { root.controller.closeTab(id) }) }
                }
                ToolTip.visible: pointer.containsMouse && !pointer.pressed
                ToolTip.delay: 450
                ToolTip.text: modelData.kind === "home" ? "Home" : modelData.source
            }
            Label { visible: !tabs.count; anchors.centerIn: parent; text: "No open tabs"; color: Theme.textMuted }
        }
        UiControls.ToolButton {
            id: newTabButton
            objectName: "newTabButton"
            Layout.preferredWidth: 32; Layout.preferredHeight: 32
            text: "+"; font.pixelSize: 20
            Accessible.name: "New Home tab"
            ToolTip.visible: hovered; ToolTip.delay: 450
            ToolTip.text: "New Home tab (" + (Qt.platform.os === "osx" ? "⌘T" : "Ctrl+T") + ")"
            background: Rectangle { color: newTabButton.down ? Theme.tabPressed : newTabButton.hovered ? Theme.tabHover : Theme.surfaceSelected }
            onClicked: { root.controller.activateGroup(root.groupId); root.controller.newHomeTab() }
        }
        }
        Loader {
            id: webLoader
            Layout.fillWidth: true; Layout.fillHeight: true
            visible: root.isWeb; active: root.isWeb && !root.controller.suspended
            sourceComponent: WebPane {
                controller: root.controller
                isActive: root.isWeb && !root.controller.suspended && root.controller.activeGroup === root.groupId
                onActivated: root.controller.activateGroup(root.groupId)
            }
            onLoaded: {
                const t = root.groupData.tabs.find(function(tab) { return tab.id === root.groupData.activeTab })
                if (t && t.kind === "web") { item.tabId = t.id; item.open(t.source) }
                if (root.focusAddressWhenReady) { root.focusAddressWhenReady = false; item.focusAddress() }
            }
        }
        ReaderPane {
            id: pane
            visible: !root.isHome && !root.isWeb
            Layout.fillWidth: true
            Layout.fillHeight: true
            managed: true
            isActive: !root.isHome && !root.isWeb && !root.controller.suspended && root.controller.activeGroup === root.groupId
            onActivated: root.controller.activateGroup(root.groupId)
            onFileChosen: function(source) { root.controller.activateGroup(root.groupId); root.controller.openDocument(source) }
            onLinkRequested: function(url) { root.controller.activateGroup(root.groupId); root.controller.openWeb(url.toString(), true) }
            onChanged: if (!root.controller.syncing) root.controller.changed()
        }
        Loader {
            id: homeLoader
            Layout.fillWidth: true; Layout.fillHeight: true
            visible: root.isHome; active: root.isHome && !root.controller.suspended
            sourceComponent: HomeView {
                onOpenRequested: { root.controller.activateGroup(root.groupId); root.controller.homeOpenRequested() }
                onDocumentChosen: function(source, position) { root.controller.activateGroup(root.groupId); root.controller.openDocument(source, position) }
                onResultChosen: function(result) { root.controller.activateGroup(root.groupId); root.controller.homeResultChosen(result) }
                onWorkspaceChosen: function(id) { root.controller.homeWorkspaceChosen(id) }
                onWorkspaceManageRequested: function(id) { root.controller.homeWorkspaceManageRequested(id) }
                onWorkspaceCreated: function(name) { root.controller.homeWorkspaceCreated(name) }
                TapHandler { onPressedChanged: if (pressed) root.controller.activateGroup(root.groupId) }
            }
        }
    }
    UiControls.Menu {
        id: tabMenu
        UiControls.MenuItem { text: "Close Tab"; onTriggered: root.controller.closeTab(root.menuTab) }
        UiControls.MenuItem { text: "Duplicate to Right Split"; onTriggered: { root.controller.activateTab(root.menuTab); root.controller.duplicateSplit("right") } }
        UiControls.MenuItem { text: "Duplicate to Bottom Split"; onTriggered: { root.controller.activateTab(root.menuTab); root.controller.duplicateSplit("bottom") } }
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
        radius: Theme.cornerRadius
        border.color: Theme.borderSelected
        z: 10
        Label { anchors.centerIn: parent; text: parent.edge === "center" ? "Move tab here" : "Split " + parent.edge; color: Theme.textBody }
    }
}
