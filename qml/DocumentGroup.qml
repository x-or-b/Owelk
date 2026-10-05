import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui
import "Platform.js" as Platform
import "WorkspaceTree.js" as Tree

Rectangle {
    id: root
    required property string groupId
    required property var controller
    property var groupData: ({tabs: [], activeTab: ""})
    property string loadedTab: ""
    property string loadedSource: ""
    readonly property bool isHome: groupData.tabs.some(function(t) { return t.id === groupData.activeTab && t.kind === "home" })
    readonly property bool isWeb: groupData.tabs.some(function(t) { return t.id === groupData.activeTab && t.kind === "web" })
    readonly property bool isNote: groupData.tabs.some(function(t) { return t.id === groupData.activeTab && t.kind === "note" })
    function focusNoteTitle() { if (noteLoader.item) noteLoader.item.focusTitle() }
    readonly property bool isLibrary: groupData.tabs.some(function(t) { return t.id === groupData.activeTab && t.kind === "library" })
    readonly property var activeTabData: groupData.tabs.find(function(t) { return t.id === groupData.activeTab }) || null
    readonly property var webPane: webLoader.item
    // Cmd+L on a new web tab: focus the address bar once the page has loaded its pane.
    property bool focusAddressWhenReady: false
    function focusAddress() {
        if (webLoader.item) webLoader.item.focusAddress()
        else focusAddressWhenReady = true
    }
    property alias reader: pane
    property string menuTab: ""
    // Named tab groups of this strip, and the tabs the bar shows (a collapsed group's tabs are hidden).
    readonly property var labels: groupData.labels || []
    readonly property var shownTabs: Tree.visibleTabs(groupData)
    readonly property var menuTabData: groupData.tabs.find(function(t) { return t.id === root.menuTab }) || null
    property string menuLabel: ""
    objectName: "group-" + groupId
    color: Theme.window
    radius: Theme.radius
    clip: true
    function refresh() {
        if (!pane) return
        const t = groupData.tabs.find(function(t) { return t.id === groupData.activeTab })
        if (loadedTab === groupData.activeTab && loadedSource === (t ? t.source : "")) return
        if (!loadedTab.length && controller.suspended) return
        const switched = loadedTab !== groupData.activeTab
        loadedTab = groupData.activeTab
        loadedSource = t ? t.source : ""
        if (t && t.kind === "library") return
        if (t && t.kind === "note") return
        if (t && t.kind === "web") {
            // The page itself reports navigation; only a tab switch loads a new address.
            if (switched) Qt.callLater(function() { if (webLoader.item) { webLoader.item.tabId = t.id; webLoader.item.open(t.source) } })
            return
        }
        pane.restore(t && t.kind !== "home" ? t : {})
    }
    function focusHome() { if (homeLoader.item) homeLoader.item.focusSearch() }
    // Drop position among all tabs, from a point over the bar (which may hide collapsed groups).
    function tabIndexAt(x) {
        const visual = Math.max(0, Math.floor((x + tabs.contentX + 80) / 160))
        return visual >= shownTabs.length ? groupData.tabs.length : groupData.tabs.indexOf(shownTabs[visual])
    }
    onGroupDataChanged: {
        refresh()
        Qt.callLater(function() {
            const at = root.shownTabs.findIndex(function(t) { return t.id === root.groupData.activeTab })
            if (at >= 0) tabs.positionViewAtIndex(at, ListView.Contain)
        })
    }
    Component.onCompleted: refresh()
    Connections { target: root.controller; function onSuspendedChanged() { if (!root.controller.suspended) root.refresh() } }
    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        // Group chips: name and size; click collapses, right-click for the group's actions.
        Flow {
            objectName: "tabGroupBar"
            Layout.fillWidth: true
            Layout.leftMargin: 4; Layout.topMargin: 3; Layout.bottomMargin: 1
            visible: root.labels.length > 0
            spacing: 4
            Repeater {
                model: root.labels
                delegate: Chip {
                    id: chip
                    required property var modelData
                    objectName: "tabGroup-" + modelData.name
                    readonly property int size: root.groupData.tabs.filter(function(t) { return t.label === chip.modelData.id }).length
                    text: modelData.name + "  " + size
                    trailingIcon: modelData.collapsed ? "right" : "down"
                    checked: !modelData.collapsed
                    checkable: false
                    ToolTip.text: (modelData.collapsed ? "Show" : "Hide") + " this group's tabs · right-click for more"
                    onClicked: { const label = modelData.id, collapsed = !modelData.collapsed; Qt.callLater(function() { root.controller.setTabGroupCollapsed(root.groupId, label, collapsed) }) }
                    TapHandler { acceptedButtons: Qt.RightButton; onTapped: { root.menuLabel = chip.modelData.id; groupMenu.popup() } }
                }
            }
        }
        // Tabs are rounded pills in the bar: the active one is raised, the others show on hover.
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.barHeight
            spacing: 0
        ListView {
            id: tabs
            objectName: "tabBar"
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.barHeight
            Layout.leftMargin: 3
            orientation: ListView.Horizontal
            clip: true
            model: root.shownTabs
            ScrollBar.horizontal: ScrollBar { height: 4 }
            delegate: Item {
                id: tabItem
                required property var modelData
                readonly property bool current: modelData.id === root.groupData.activeTab
                readonly property string title: modelData.kind === "home" ? "Home" : modelData.kind === "library" ? "Library" : modelData.kind === "note" ? (modelData.title || "Untitled note") : modelData.kind === "web" ? (modelData.title || modelData.source.replace(/^https?:\/\/(www\.)?/, "")) : (researchStore.documentsRevision, researchStore.displayName(modelData.source))
                width: 160
                height: Theme.barHeight
                objectName: "tab-" + modelData.id
                Rectangle {
                    id: pill
                    objectName: "tabPill"
                    anchors.fill: parent
                    anchors.margins: 4
                    anchors.leftMargin: 1; anchors.rightMargin: 1
                    radius: Theme.radius
                    color: tabItem.current ? Theme.content : pointer.containsMouse || close.hovered ? Theme.hover : "transparent"
                    border.width: tabItem.current && !Theme.dark ? 1 : 0
                    border.color: Theme.separator
                }
                // Grouped tabs carry a small accent dot.
                Rectangle {
                    visible: !!tabItem.modelData.label
                    x: 9; anchors.verticalCenter: parent.verticalCenter
                    width: 6; height: 6; radius: 3; color: Theme.accent
                }
                Label {
                    anchors.left: parent.left; anchors.leftMargin: tabItem.modelData.label ? 20 : 12
                    anchors.right: close.left; anchors.rightMargin: 2
                    anchors.verticalCenter: parent.verticalCenter
                    text: tabItem.title
                    elide: Text.ElideRight
                    font.pixelSize: Theme.fontSmall
                    font.weight: tabItem.current && root.controller.activeGroup === root.groupId ? Font.Medium : Font.Normal
                    color: tabItem.current ? Theme.text : Theme.textSecondary
                }
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
                IconButton {
                    id: close
                    objectName: "closeTabButton-" + modelData.id
                    // Shown on the active tab and on hover, like Safari.
                    opacity: tabItem.current || pointer.containsMouse || hovered ? 1 : 0
                    anchors.right: parent.right
                    anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    width: Theme.controlHeightSmall - 2; height: width; glyphSize: Theme.fontBody
                    icon.name: "close"
                    description: "Close tab"
                    onClicked: { const id = modelData.id; Qt.callLater(function() { root.controller.closeTab(id) }) }
                }
                ToolTip.visible: pointer.containsMouse && !pointer.pressed
                ToolTip.delay: 500
                ToolTip.text: tabItem.title + (modelData.kind === "web" ? "\n" + modelData.source : modelData.source && modelData.source.length ? "\n" + researchStore.localPath(modelData.source) : "")
            }
            Label { visible: !tabs.count; anchors.centerIn: parent; text: "No open tabs"; color: Theme.textTertiary }
        }
        IconButton {
            id: newTabButton
            objectName: "newTabButton"
            Layout.rightMargin: 4
            icon.name: "add"
            description: "New tab · " + Platform.keys("Ctrl+T")
            onClicked: { root.controller.activateGroup(root.groupId); root.controller.newHomeTab() }
        }
        }
        Loader {
            id: noteLoader
            Layout.fillWidth: true; Layout.fillHeight: true
            visible: root.isNote; active: root.isNote && !root.controller.suspended
            sourceComponent: NotePane {
                controller: root.controller
                noteId: root.activeTabData && root.activeTabData.kind === "note" ? root.activeTabData.noteId : ""
                isActive: root.isNote && root.controller.activeGroup === root.groupId
                onActivated: root.controller.activateGroup(root.groupId)
            }
        }
        Loader {
            id: libraryLoader
            Layout.fillWidth: true; Layout.fillHeight: true
            visible: root.isLibrary; active: root.isLibrary && !root.controller.suspended
            sourceComponent: LibraryView {
                filter: root.activeTabData && root.activeTabData.filter ? root.activeTabData.filter : ({})
                onFilterEdited: function(filter) { if (root.activeTabData) root.controller.setLibraryFilter(root.activeTabData.id, filter) }
                onDocumentChosen: function(source, position) { root.controller.activateGroup(root.groupId); root.controller.openDocument(source, position, true) }
                onNoteChosen: function(id) { root.controller.activateGroup(root.groupId); root.controller.openNote(id, true) }
                onNewNoteRequested: { root.controller.activateGroup(root.groupId); root.controller.newNote() }
                TapHandler { onPressedChanged: if (pressed) root.controller.activateGroup(root.groupId) }
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
            visible: !root.isHome && !root.isWeb && !root.isLibrary && !root.isNote
            Layout.fillWidth: true
            Layout.fillHeight: true
            managed: true
            isActive: !root.isHome && !root.isWeb && !root.isLibrary && !root.isNote && !root.controller.suspended && root.controller.activeGroup === root.groupId
            onActivated: root.controller.activateGroup(root.groupId)
            onFileChosen: function(source) { root.controller.activateGroup(root.groupId); root.controller.openDocument(source) }
            onAiRequested: function(spec) { root.controller.aiRequested(spec) }
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
                onLibraryRequested: { root.controller.activateGroup(root.groupId); root.controller.openLibrary({}) }
                onWebRequested: function(url) { root.controller.activateGroup(root.groupId); root.controller.openWeb(url) }
                TapHandler { onPressedChanged: if (pressed) root.controller.activateGroup(root.groupId) }
            }
        }
    }
    Menu {
        id: tabMenu
        MenuItem { text: "Close Tab"; onTriggered: root.controller.closeTab(root.menuTab) }
        MenuItem { text: "Duplicate to Right Split"; onTriggered: { root.controller.activateTab(root.menuTab); root.controller.duplicateSplit("right") } }
        MenuItem { text: "Duplicate to Bottom Split"; onTriggered: { root.controller.activateTab(root.menuTab); root.controller.duplicateSplit("bottom") } }
        MenuSeparator {}
        MenuItem { objectName: "newTabGroupOption"; text: "Add to New Group…"; onTriggered: { groupName.mode = "new"; groupName.text = ""; groupNameDialog.open() } }
        Instantiator {
            model: root.labels.filter(function(l) { return !root.menuTabData || root.menuTabData.label !== l.id })
            delegate: MenuItem {
                required property var modelData
                text: "Add to \u201c" + modelData.name + "\u201d"
                onTriggered: { const tab = root.menuTab, label = modelData.id; Qt.callLater(function() { root.controller.addTabToGroup(tab, label) }) }
            }
            onObjectAdded: function(index, item) { tabMenu.insertItem(5 + index, item) }
            onObjectRemoved: function(index, item) { tabMenu.removeItem(item) }
        }
        MenuItem { visible: !!root.menuTabData && !!root.menuTabData.label; height: visible ? implicitHeight : 0; text: "Remove from Group"; onTriggered: root.controller.removeTabFromGroup(root.menuTab) }
        MenuItem { objectName: "organizeTabsOption"; text: "Organize Tabs with AI…"; onTriggered: root.controller.organizeRequested(root.groupId) }
    }
    Menu {
        id: groupMenu
        objectName: "tabGroupMenu"
        MenuItem { text: "Rename…"; onTriggered: { const label = root.controller.tabLabel(root.groupId, root.menuLabel); groupName.mode = "rename"; groupName.text = label ? label.name : ""; groupNameDialog.open() } }
        MenuItem { text: "Save as Workspace"; onTriggered: root.controller.saveTabGroupAsWorkspace(root.groupId, root.menuLabel) }
        MenuItem { text: "Save Papers as Collection"; onTriggered: root.controller.saveTabGroupAsCollection(root.groupId, root.menuLabel) }
        MenuSeparator {}
        MenuItem { text: "Ungroup"; onTriggered: root.controller.ungroupTabs(root.groupId, root.menuLabel) }
        MenuItem { text: "Close Group's Tabs"; onTriggered: { const label = root.menuLabel; Qt.callLater(function() { root.controller.closeTabGroup(root.groupId, label) }) } }
    }
    Dialog {
        id: groupNameDialog
        objectName: "tabGroupNameDialog"
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: 340
        modal: true
        title: groupName.mode === "rename" ? "Rename Group" : "New Tab Group"
        standardButtons: Dialog.Ok | Dialog.Cancel
        onOpened: groupName.forceActiveFocus()
        TextField {
            id: groupName
            objectName: "tabGroupName"
            property string mode: "new"
            width: parent.width
            placeholderText: "Group name"
            maximumLength: 120
            onAccepted: groupNameDialog.accept()
        }
        onAccepted: {
            if (!groupName.text.trim().length) return
            if (groupName.mode === "rename") root.controller.renameTabGroup(root.groupId, root.menuLabel, groupName.text)
            else root.controller.groupTabs([root.menuTab], groupName.text)
        }
    }
    Rectangle {
        readonly property var target: root.controller.dropTarget
        readonly property string edge: target ? target.edge : ""
        visible: !!target && target.group === root.groupId
        x: edge === "right" ? parent.width / 2 : 0
        y: edge === "bottom" ? parent.height / 2 : 0
        width: edge === "left" || edge === "right" ? parent.width / 2 : parent.width
        height: edge === "top" || edge === "bottom" ? parent.height / 2 : target && target.index !== undefined ? 32 : parent.height
        color: Theme.overlay
        radius: Theme.radius
        border.color: Theme.accent
        z: 10
        Label { anchors.centerIn: parent; text: parent.edge === "center" ? "Move tab here" : "Split " + parent.edge; color: Theme.text }
    }
}
