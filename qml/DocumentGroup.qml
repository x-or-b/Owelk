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
    // Web tabs keep their page (scroll, forms, back history) when you switch away and back: the most
    // recent few in this strip stay alive, frozen while hidden so they use no CPU. Older ones reload.
    readonly property int keptWebPages: 3
    property var webOrder: []
    property int webRevision: 0
    ListModel { id: webPages }
    function keepWebPage(tabId) {
        webOrder = [tabId].concat(webOrder.filter(function(id) { return id !== tabId }))
        let present = false
        for (let i = 0; i < webPages.count; ++i) if (webPages.get(i).tabId === tabId) present = true
        if (!present) webPages.append({tabId: tabId})
        while (webOrder.length > keptWebPages) dropWebPage(webOrder[webOrder.length - 1])
    }
    function dropWebPage(tabId) {
        webOrder = webOrder.filter(function(id) { return id !== tabId })
        for (let i = webPages.count - 1; i >= 0; --i) if (webPages.get(i).tabId === tabId) webPages.remove(i)
    }
    // Pages of tabs that were closed or moved to another strip go.
    function pruneWebPages() {
        const ids = groupData.tabs.filter(function(t) { return t.kind === "web" }).map(function(t) { return t.id })
        webOrder.slice().forEach(function(id) { if (ids.indexOf(id) < 0) root.dropWebPage(id) })
    }
    readonly property var webPane: {
        const revision = webRevision
        for (let i = 0; i < webPanes.count; ++i) {
            const page = webPanes.itemAt(i)
            if (page && page.tabId === groupData.activeTab) return page
        }
        return null
    }
    Connections {
        target: root.controller
        function onSuspendedChanged() { if (root.controller.suspended) { webPages.clear(); root.webOrder = [] } }
    }
    // Cmd+L on a new web tab: focus the address bar once the page has loaded its pane.
    property bool focusAddressWhenReady: false
    function focusAddress() {
        if (webPane) webPane.focusAddress()
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
        pruneWebPages()
        const switched = loadedTab !== groupData.activeTab
        loadedTab = groupData.activeTab
        loadedSource = t ? t.source : ""
        if (t && t.kind === "library") return
        if (t && t.kind === "note") return
        if (t && t.kind === "web") {
            // Its own page, kept or created (the page reports its navigation itself).
            if (!controller.suspended) keepWebPage(t.id)
            return
        }
        pane.restore(t && t.kind !== "home" ? t : {})
    }
    function focusHome() { if (homeLoader.item) homeLoader.item.focusSearch() }
    // The strip: each group's label, then its tabs (a folded group shows only its label and the
    // active tab). Tabs of a group are always next to each other.
    readonly property int tabWidth: 160
    readonly property var strip: Tree.stripItems(groupData)
    // With vertical tabs the strip is hidden; tabs are listed beside the window instead.
    readonly property real stripHeight: Theme.verticalTabs ? 0 : Theme.barHeight
    function showTabMenu(tabId) { menuTab = tabId; tabMenu.popup() }
    function showGroupMenu(labelId) { menuLabel = labelId; groupMenu.popup() }
    function groupColor(label) {
        const accent = Theme.accents.find(function(a) { return a.id === label.color }) || Theme.accents[0]
        return Theme.dark ? accent.dark : accent.light
    }
    // Where a dragged tab would land, from a point over the bar: the tab index to insert at, and the
    // tab under the pointer's middle (holding there makes a group).
    function dropInfo(x, dragged) {
        const local = tabs.mapFromItem(root, x, 0).x + tabs.contentX
        const i = tabs.indexAt(local, tabs.height / 2)
        if (i < 0) return {index: local < 0 ? 0 : groupData.tabs.length, over: ""}
        const entry = strip[i], item = tabs.itemAtIndex(i)
        if (entry.type === "header") return {index: groupData.tabs.findIndex(function(t) { return t.label === entry.label.id }), over: ""}
        const at = groupData.tabs.indexOf(entry.tab), part = item ? (local - item.x) / item.width : 0
        if (entry.tab.id !== dragged && part > .3 && part < .7) return {index: at + 1, over: entry.tab.id}
        return {index: snapToGroupEdge(part < .5 ? at : at + 1, dragged), over: ""}
    }
    // A tab cannot land between two tabs of a group it is not in: it goes before or after the group,
    // whichever is nearer. (Tabs of the same group reorder freely inside it.)
    function snapToGroupEdge(index, dragged) {
        const tabs = groupData.tabs
        const own = tabs.find(function(t) { return t.id === dragged })
        let p = index - 1, n = index
        while (p >= 0 && tabs[p].id === dragged) --p
        while (n < tabs.length && tabs[n].id === dragged) ++n
        const label = p >= 0 && n < tabs.length && tabs[p].label && tabs[p].label === tabs[n].label ? tabs[p].label : ""
        if (!label || (own && own.label === label)) return index
        let first = -1, last = -1
        tabs.forEach(function(t, i) { if (t.label === label) { if (first < 0) first = i; last = i } })
        return index - first <= last + 1 - index ? first : last + 1
    }
    function visualIndex(tabIndex) {
        if (tabIndex >= groupData.tabs.length) return strip.length
        const t = groupData.tabs[tabIndex]
        const i = strip.findIndex(function(e) { return e.type === "tab" && e.tab.id === t.id })
        return i >= 0 ? i : strip.length
    }
    readonly property int draggedVisual: controller.draggedTab.length ? strip.findIndex(function(e) { return e.type === "tab" && e.tab.id === controller.draggedTab }) : -1
    readonly property int insertVisual: {
        const t = controller.dropTarget
        return t && t.group === groupId && t.index !== undefined && !t.join ? visualIndex(t.index) : -1
    }
    function shiftFor(i) {
        const w = tabWidth, d = draggedVisual, t = insertVisual
        if (d >= 0 && t >= 0) return t > d && i > d && i < t ? -w : t < d && i >= t && i < d ? w : 0
        if (d >= 0 && controller.dropTarget) return i > d ? -w : 0 // the tab is leaving this strip
        if (d < 0 && t >= 0) return i >= t ? w : 0 // a tab from another strip is coming in
        return 0
    }
    // A new group's label opens for its name.
    property string editingLabel: ""
    function finishNaming(text) {
        const label = editingLabel
        editingLabel = ""
        if (label.length && text.trim().length) root.controller.renameTabGroup(root.groupId, label, text)
    }
    Connections {
        target: root.controller
        function onTabGroupCreated(stripId, labelId) {
            if (stripId !== root.groupId) return
            root.editingLabel = labelId
            Qt.callLater(function() {
                const at = root.strip.findIndex(function(e) { return e.type === "header" && e.label.id === labelId })
                if (at >= 0) tabs.positionViewAtIndex(at, ListView.Contain)
            })
        }
    }
    onGroupDataChanged: {
        refresh()
        Qt.callLater(function() {
            const at = root.strip.findIndex(function(e) { return e.type === "tab" && e.tab.id === root.groupData.activeTab })
            if (at >= 0) tabs.positionViewAtIndex(at, ListView.Contain)
        })
    }
    Component.onCompleted: refresh()
    Connections { target: root.controller; function onSuspendedChanged() { if (!root.controller.suspended) root.refresh() } }
    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        // The tab strip, as in a browser: named groups are a colored label followed by their tabs
        // (click the label to fold the group). Dragging a tab moves it among the others; holding it
        // over another tab makes a group of the two.
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: root.stripHeight
            visible: !Theme.verticalTabs
            spacing: 0
        ListView {
            id: tabs
            objectName: "tabBar"
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.barHeight
            Layout.leftMargin: 3
            orientation: ListView.Horizontal
            clip: true
            model: root.strip
            ScrollBar.horizontal: ScrollBar { height: 4 }
            // Right-click on the bar's empty space: new tab, sorting, AI, layout.
            TapHandler { acceptedButtons: Qt.RightButton; onTapped: stripMenu.show(root.groupId) }
            delegate: Item {
                id: tabItem
                required property var modelData
                required property int index
                readonly property bool isHeader: modelData.type === "header"
                readonly property var tabData: isHeader ? ({}) : modelData.tab
                readonly property var labelData: modelData.label
                readonly property color groupColor: labelData ? root.groupColor(labelData) : "transparent"
                readonly property bool current: !isHeader && tabData.id === root.groupData.activeTab
                readonly property bool dragged: !isHeader && root.controller.draggedTab === tabData.id
                readonly property bool joinTarget: !isHeader && !!root.controller.dropTarget && root.controller.dropTarget.join === tabData.id
                readonly property string title: isHeader ? "" : (researchStore.documentsRevision, Tree.tabTitle(tabData, researchStore.displayName))
                width: isHeader ? header.width + 6 : root.tabWidth
                height: Theme.barHeight
                objectName: isHeader ? "tabGroupHeader-" + labelData.name : "tab-" + tabData.id
                // Tabs step aside to open a gap where the dragged tab would land.
                transform: Translate { x: root.shiftFor(tabItem.index); Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } } }
                opacity: dragged ? 0 : 1

                // --- A group's label ---------------------------------------------------------------
                Rectangle {
                    id: header
                    visible: tabItem.isHeader
                    objectName: tabItem.isHeader ? "tabGroupLabel" : ""
                    x: 3; anchors.verticalCenter: parent.verticalCenter
                    height: Theme.barHeight - 12
                    width: (nameField.visible ? Math.max(90, nameField.implicitWidth) : headerText.implicitWidth) + 18
                    radius: Theme.radiusSmall
                    color: tabItem.isHeader ? Theme.mix(Theme.content, tabItem.groupColor, headerHover.hovered ? .32 : .22) : "transparent"
                    Label {
                        id: headerText
                        visible: !nameField.visible
                        anchors.centerIn: parent
                        text: tabItem.isHeader ? tabItem.labelData.name + (tabItem.labelData.collapsed ? "  " + tabItem.modelData.size : "") : ""
                        font.pixelSize: Theme.fontSmall; font.weight: Font.DemiBold
                        color: tabItem.isHeader ? Theme.mix(tabItem.groupColor, Theme.text, Theme.dark ? .1 : .35) : Theme.text
                    }
                    TextField {
                        id: nameField
                        objectName: tabItem.isHeader ? "tabGroupNameField" : ""
                        visible: tabItem.isHeader && root.editingLabel === tabItem.labelData.id
                        anchors.centerIn: parent
                        width: Math.max(90, implicitWidth)
                        height: parent.height - 2
                        padding: 1; leftPadding: 6; rightPadding: 6
                        font.pixelSize: Theme.fontSmall
                        maximumLength: 120
                        placeholderText: "Name this group"
                        // The strip is rebuilt as tabs change, so a new label may already be open when made.
                        function claim() { if (visible) { text = tabItem.labelData.name; forceActiveFocus(); selectAll() } }
                        onVisibleChanged: claim()
                        Component.onCompleted: Qt.callLater(claim)
                        onAccepted: root.finishNaming(text)
                        onActiveFocusChanged: if (!activeFocus && visible) root.finishNaming(text)
                        Keys.onEscapePressed: root.editingLabel = ""
                    }
                    HoverHandler { id: headerHover }
                    TapHandler {
                        enabled: !nameField.visible
                        onTapped: { const label = tabItem.labelData.id, collapsed = !tabItem.labelData.collapsed; Qt.callLater(function() { root.controller.setTabGroupCollapsed(root.groupId, label, collapsed) }) }
                        onDoubleTapped: root.editingLabel = tabItem.labelData.id
                    }
                    TapHandler { acceptedButtons: Qt.RightButton; onTapped: { root.menuLabel = tabItem.labelData.id; groupMenu.popup() } }
                    ToolTip.visible: headerHover.hovered && !nameField.visible
                    ToolTip.delay: 500
                    ToolTip.text: tabItem.isHeader ? (tabItem.labelData.collapsed ? "Show " : "Hide ") + tabItem.modelData.size + " tabs · double-click to rename · right-click for more" : ""
                }

                // --- A tab ---------------------------------------------------------------------------
                Rectangle {
                    id: pill
                    visible: !tabItem.isHeader
                    objectName: "tabPill"
                    anchors.fill: parent
                    anchors.margins: 4
                    anchors.leftMargin: 1; anchors.rightMargin: 1
                    radius: Theme.radius
                    color: tabItem.current ? Theme.content : pointer.containsMouse || close.hovered ? Theme.hover : "transparent"
                    border.width: tabItem.joinTarget ? 2 : tabItem.current && !Theme.dark ? 1 : 0
                    border.color: tabItem.joinTarget ? Theme.accent : Theme.separator
                }
                // A grouped tab carries its group's color along the bottom.
                Rectangle {
                    visible: !tabItem.isHeader && !!tabItem.labelData
                    anchors.bottom: parent.bottom; anchors.bottomMargin: 2
                    x: 4; width: parent.width - 8; height: 2; radius: 1
                    color: tabItem.groupColor
                }
                Label {
                    visible: !tabItem.isHeader
                    anchors.left: parent.left; anchors.leftMargin: 12
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
                    enabled: !tabItem.isHeader
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
                        if (!moving && Math.abs(p.x - start.x) + Math.abs(p.y - start.y) > 8) { moving = true; root.controller.dragTitle = tabItem.title }
                        if (moving) root.controller.dragTab(tabItem.tabData.id, p.x, p.y)
                    }
                    onReleased: function(mouse) {
                        if (cancelled) return
                        if (moving) {
                            const point = mapToItem(null, mouse.x, mouse.y)
                            root.controller.dragTab(tabItem.tabData.id, point.x, point.y)
                            root.controller.finishDrag(false)
                        }
                        else if (mouse.button === Qt.RightButton) { root.menuTab = tabItem.tabData.id; tabMenu.popup() }
                        else if (mouse.button === Qt.MiddleButton) { const id = tabItem.tabData.id; Qt.callLater(function() { root.controller.closeTab(id) }) }
                        else { const id = tabItem.tabData.id; Qt.callLater(function() { root.controller.activateTab(id) }) }
                        moving = false
                    }
                    onCanceled: { cancelled = true; moving = false; root.controller.finishDrag(true) }
                }
                Keys.onEscapePressed: { pointer.cancelled = true; pointer.moving = false; root.controller.finishDrag(true) }
                IconButton {
                    id: close
                    visible: !tabItem.isHeader
                    objectName: "closeTabButton-" + (tabItem.tabData.id || "")
                    // Shown on the active tab and on hover, like Safari.
                    opacity: tabItem.current || pointer.containsMouse || hovered ? 1 : 0
                    anchors.right: parent.right
                    anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    width: Theme.controlHeightSmall - 2; height: width; glyphSize: Theme.fontBody
                    icon.name: "close"
                    description: "Close tab"
                    onClicked: { const id = tabItem.tabData.id; Qt.callLater(function() { root.controller.closeTab(id) }) }
                }
                ToolTip.visible: !tabItem.isHeader && pointer.containsMouse && !pointer.pressed
                ToolTip.delay: 500
                ToolTip.text: tabItem.isHeader ? "" : tabItem.title + (tabItem.tabData.kind === "web" ? "\n" + tabItem.tabData.source : tabItem.tabData.source && tabItem.tabData.source.length ? "\n" + researchStore.localPath(tabItem.tabData.source) : "")
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
        Repeater {
            id: webPanes
            model: webPages
            delegate: WebPane {
                id: page
                required property var model
                tabId: model.tabId
                readonly property bool shown: root.isWeb && root.groupData.activeTab === tabId && !root.controller.suspended
                visible: shown
                frozen: !shown
                Layout.fillWidth: true; Layout.fillHeight: true
                controller: root.controller
                isActive: shown && root.controller.activeGroup === root.groupId
                onActivated: root.controller.activateGroup(root.groupId)
                Component.onCompleted: {
                    const t = root.groupData.tabs.find(function(tab) { return tab.id === page.tabId })
                    if (t) open(t.source)
                    root.webRevision++
                    if (shown && root.focusAddressWhenReady) { root.focusAddressWhenReady = false; focusAddress() }
                }
                Component.onDestruction: root.webRevision++
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
                onLibraryFilterRequested: function(filter) { root.controller.activateGroup(root.groupId); root.controller.openLibrary(filter) }
                onWebRequested: function(url) { root.controller.activateGroup(root.groupId); root.controller.openWeb(url) }
                TapHandler { onPressedChanged: if (pressed) root.controller.activateGroup(root.groupId) }
            }
        }
    }
    // Tab menu: what this tab is (address, file, note) | splits | groups | close; note trash last.
    Menu {
        id: tabMenu
        objectName: "tabMenu"
        readonly property string kind: root.menuTabData ? (root.menuTabData.kind || "pdf") : ""
        readonly property string path: kind === "pdf" ? researchStore.localPath(root.menuTabData.source) : ""
        function itemIndex(item) { for (let i = 0; i < count; ++i) if (itemAt(i) === item) return i; return count }
        MenuItem { visible: tabMenu.kind === "web"; height: visible ? implicitHeight : 0; text: "Open in Browser"; onTriggered: Qt.openUrlExternally(root.menuTabData.source) }
        MenuItem { visible: tabMenu.kind === "web"; height: visible ? implicitHeight : 0; text: "Copy Address"; onTriggered: researchStore.copyText(root.menuTabData.source) }
        MenuItem { visible: tabMenu.kind === "pdf"; height: visible ? implicitHeight : 0; text: "Copy File Path"; onTriggered: researchStore.copyText(tabMenu.path) }
        MenuItem { visible: tabMenu.kind === "pdf"; height: visible ? implicitHeight : 0; text: Qt.platform.os === "osx" ? "Show in Finder" : "Show in Folder"; onTriggered: Qt.openUrlExternally(researchStore.fileUrl(tabMenu.path.substring(0, tabMenu.path.lastIndexOf("/")))) }
        MenuItem { visible: tabMenu.kind === "note"; height: visible ? implicitHeight : 0; text: "Copy Markdown"; onTriggered: researchStore.copyText(researchStore.note(root.menuTabData.noteId).body || "") }
        MenuSeparator { visible: ["web", "pdf", "note"].indexOf(tabMenu.kind) >= 0; height: visible ? implicitHeight : 0 }
        MenuItem { text: "Duplicate to Right Split"; onTriggered: { root.controller.activateTab(root.menuTab); root.controller.duplicateSplit("right") } }
        MenuItem { text: "Duplicate to Bottom Split"; onTriggered: { root.controller.activateTab(root.menuTab); root.controller.duplicateSplit("bottom") } }
        MenuSeparator {}
        MenuItem { id: newGroupItem; objectName: "newTabGroupOption"; text: "Add to New Group"; onTriggered: { const tab = root.menuTab; Qt.callLater(function() { root.controller.newTabGroup([tab]) }) } }
        Instantiator {
            model: root.labels.filter(function(l) { return !root.menuTabData || root.menuTabData.label !== l.id })
            delegate: MenuItem {
                required property var modelData
                text: "Add to \u201c" + modelData.name + "\u201d"
                onTriggered: { const tab = root.menuTab, label = modelData.id; Qt.callLater(function() { root.controller.addTabToGroup(tab, label) }) }
            }
            onObjectAdded: function(index, item) { tabMenu.insertItem(tabMenu.itemIndex(newGroupItem) + 1 + index, item) }
            onObjectRemoved: function(index, item) { tabMenu.removeItem(item) }
        }
        MenuItem { visible: !!root.menuTabData && !!root.menuTabData.label; height: visible ? implicitHeight : 0; text: "Remove from Group"; onTriggered: root.controller.removeTabFromGroup(root.menuTab) }
        MenuItem { objectName: "organizeTabsOption"; text: "Organize Tabs with AI…"; onTriggered: root.controller.organizeRequested(root.groupId) }
        MenuSeparator {}
        MenuItem { objectName: "closeOtherTabsOption"; text: "Close Other Tabs"; enabled: root.groupData.tabs.length > 1; onTriggered: { const id = root.menuTab; Qt.callLater(function() { root.controller.closeOtherTabs(id) }) } }
        MenuItem { objectName: "closeTabOption"; text: "Close Tab"; onTriggered: { const id = root.menuTab; Qt.callLater(function() { root.controller.closeTab(id) }) } }
        MenuSeparator { visible: tabMenu.kind === "note"; height: visible ? implicitHeight : 0 }
        MenuItem {
            visible: tabMenu.kind === "note"; height: visible ? implicitHeight : 0
            text: "Move Note to Trash"
            palette.windowText: Theme.danger
            onTriggered: { const id = root.menuTabData.noteId; if (researchStore.deleteNote(id)) root.controller.closeNoteTabs(id) }
        }
    }
    TabStripMenu { id: stripMenu; controller: root.controller }
    Menu {
        id: groupMenu
        objectName: "tabGroupMenu"
        MenuItem { text: "Rename"; onTriggered: root.editingLabel = root.menuLabel }
        Menu {
            id: colorMenu
            title: "Color"
            Instantiator {
                model: Theme.accents
                delegate: MenuItem {
                    required property var modelData
                    text: modelData.name
                    checkable: true
                    checked: { const l = root.controller.tabLabel(root.groupId, root.menuLabel); return !!l && (l.color || "blue") === modelData.id }
                    onTriggered: root.controller.setTabGroupColor(root.groupId, root.menuLabel, modelData.id)
                }
                onObjectAdded: function(index, item) { colorMenu.insertItem(index, item) }
                onObjectRemoved: function(index, item) { colorMenu.removeItem(item) }
            }
        }
        MenuItem { text: "Save as Workspace"; onTriggered: root.controller.saveTabGroupAsWorkspace(root.groupId, root.menuLabel) }
        MenuItem { text: "Save Papers as Collection"; onTriggered: root.controller.saveTabGroupAsCollection(root.groupId, root.menuLabel) }
        MenuSeparator {}
        MenuItem { text: "Ungroup"; onTriggered: root.controller.ungroupTabs(root.groupId, root.menuLabel) }
        MenuItem { text: "Close Group's Tabs"; onTriggered: { const label = root.menuLabel; Qt.callLater(function() { root.controller.closeTabGroup(root.groupId, label) }) } }
    }
    Rectangle {
        readonly property var target: root.controller.dropTarget
        readonly property string edge: target ? target.edge : ""
        // Only a split shows an area; moving among tabs shows the gap in the strip instead.
        visible: !!target && target.group === root.groupId && edge !== "center"
        x: edge === "right" ? parent.width / 2 : 0
        y: edge === "bottom" ? parent.height / 2 : 0
        width: edge === "left" || edge === "right" ? parent.width / 2 : parent.width
        height: edge === "top" || edge === "bottom" ? parent.height / 2 : parent.height
        color: Theme.overlay
        radius: Theme.radius
        border.color: Theme.accent
        z: 10
        Icon { anchors.centerIn: parent; name: parent.edge === "top" || parent.edge === "bottom" ? "splitDown" : "split"; size: Theme.fontTitle; color: Theme.accent }
    }
}
