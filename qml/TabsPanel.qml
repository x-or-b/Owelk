import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui
import "WorkspaceTree.js" as Tree
import "Platform.js" as Platform

// Vertical tabs: every split's tabs beside the window, with full titles and Edge-style groups.
// Closed, it is a thin rail of tab icons. Dragging works as in the horizontal bar (move, split,
// hold over a tab to group); this list is one more place a tab can be dropped.
Rectangle {
    id: root
    objectName: "tabsPanel"
    required property var controller
    property bool open: true
    signal toggleRequested()
    // A tab chosen here (Home steps aside for it).
    signal tabChosen()
    readonly property real rowHeight: Theme.rowHeight + 2
    readonly property var strips: (controller.revision, controller.activeGroup, Tree.leaves(controller.tree))
    // One list: a heading per split (when there are several), then its group labels and tabs.
    readonly property var rows: {
        const list = []
        strips.forEach(function(g, i) {
            if (strips.length > 1) list.push({type: "split", strip: g, number: i + 1})
            Tree.stripItems(g).forEach(function(e) { list.push(Object.assign({strip: g}, e)) })
        })
        return list
    }
    // The open width is set by dragging the right edge (180–420 px, remembered).
    property real openWidth: 240
    signal widthChosen(real width)
    implicitWidth: open ? openWidth : Theme.iconButton + 12
    color: Theme.sidebar
    Component.onCompleted: controller.addDropHandler(root)
    Component.onDestruction: controller.removeDropHandler(root)

    function iconFor(t) { return t.kind === "web" ? "globe" : t.kind === "note" ? "note" : t.kind === "library" ? "library" : t.kind === "home" ? "home" : "document" }
    function view(stripId) { return controller.groupView(stripId) }

    // --- Dropping a dragged tab on this list -------------------------------------------------
    function claimDrop(id, x, y) {
        if (!visible || !open) return null
        const p = list.mapFromItem(null, x, y)
        if (p.x < 0 || p.x > list.width || p.y < 0 || p.y > list.height + 40) return null
        const i = list.indexAt(10, p.y + list.contentY)
        if (i < 0) {
            const last = strips[strips.length - 1]
            return last ? {group: last.id, edge: "center", index: last.tabs.length, over: ""} : null
        }
        const row = rows[i], item = list.itemAtIndex(i)
        const strip = row.strip
        if (row.type === "split") return {group: strip.id, edge: "center", index: 0, over: ""}
        if (row.type === "header")
            return {group: strip.id, edge: "center", index: strip.tabs.findIndex(function(t) { return t.label === row.label.id }), over: ""}
        const at = strip.tabs.indexOf(row.tab), part = item ? (p.y + list.contentY - item.y) / item.height : 0
        if (row.tab.id !== id && part > .3 && part < .7) return {group: strip.id, edge: "center", index: at + 1, over: row.tab.id}
        const index = part < .5 ? at : at + 1
        const v = view(strip.id)
        return {group: strip.id, edge: "center", index: v ? v.snapToGroupEdge(index, id) : index, over: ""}
    }
    // Rows step aside like the horizontal bar: the dragged row's place closes, a gap opens at the target.
    readonly property int draggedRow: controller.draggedTab.length ? rows.findIndex(function(r) { return r.type === "tab" && r.tab.id === controller.draggedTab }) : -1
    readonly property int insertRow: {
        const t = controller.dropTarget
        if (!t || t.handler || t.join || t.index === undefined || t.edge !== "center") return -1
        const strip = strips.find(function(g) { return g.id === t.group })
        if (!strip) return -1
        if (t.index >= strip.tabs.length) {
            let last = -1
            rows.forEach(function(r, i) { if (r.strip.id === strip.id) last = i })
            return last + 1
        }
        const tab = strip.tabs[t.index]
        return rows.findIndex(function(r) { return r.type === "tab" && r.tab.id === tab.id })
    }
    function shiftFor(i) {
        const h = rowHeight, d = draggedRow, t = insertRow
        if (d >= 0 && t >= 0) return t > d && i > d && i < t ? -h : t < d && i >= t && i < d ? h : 0
        if (d >= 0 && controller.dropTarget) return i > d ? -h : 0
        if (d < 0 && t >= 0) return i >= t ? h : 0
        return 0
    }

    // A new group made from this list opens its name here.
    property string editingLabel: ""
    Connections {
        target: root.controller
        enabled: root.visible && root.open
        function onTabGroupCreated(stripId, labelId) { root.editingLabel = labelId }
    }

    TabStripMenu { id: stripMenu; controller: root.controller }
    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.barHeight
            Layout.leftMargin: 6; Layout.rightMargin: 6
            spacing: 2
            IconButton {
                objectName: "tabsPanelToggle"
                icon.name: "sidebar"
                checked: root.open
                description: (root.open ? "Hide tabs · " : "Show tabs · ") + Platform.keys("Ctrl+Shift+B")
                onClicked: root.toggleRequested()
            }
            Label {
                visible: root.open
                Layout.fillWidth: true
                leftPadding: 4
                text: "Tabs"
                font.pixelSize: Theme.fontSmall; font.weight: Font.DemiBold; color: Theme.textSecondary
            }
            IconButton {
                visible: root.open
                objectName: "tabsPanelNewTab"
                icon.name: "add"
                description: "New tab · " + Platform.keys("Ctrl+T")
                onClicked: root.controller.newHomeTab()
            }
        }
        ListView {
            id: list
            objectName: "tabsPanelList"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: root.rows
            ScrollBar.vertical: ScrollBar {}
            // Right-click on the list's empty space: the same menu as the tab bar, for the active split.
            TapHandler { acceptedButtons: Qt.RightButton; onTapped: stripMenu.show(root.controller.activeGroup) }
            delegate: Item {
                id: row
                required property var modelData
                required property int index
                readonly property string type: modelData.type
                readonly property var tab: type === "tab" ? modelData.tab : null
                readonly property var label: modelData.label || null
                readonly property color groupColor: label ? root.view(modelData.strip.id) ? root.view(modelData.strip.id).groupColor(label) : Theme.accent : "transparent"
                readonly property bool activeStrip: modelData.strip.id === root.controller.activeGroup
                readonly property bool current: !!tab && tab.id === modelData.strip.activeTab
                readonly property string title: tab ? (researchStore.documentsRevision, Tree.tabTitle(tab, researchStore.displayName)) : ""
                objectName: type === "tab" ? "verticalTab-" + tab.id : type === "header" ? "verticalGroup-" + label.name : "verticalSplit-" + modelData.number
                width: list.width
                height: type === "split" ? (root.open ? Theme.rowHeight : 8) : root.rowHeight
                transform: Translate { y: root.shiftFor(row.index); Behavior on y { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } } }
                opacity: !!row.tab && root.controller.draggedTab === row.tab.id ? 0 : 1

                // A split's heading.
                Label {
                    visible: row.type === "split" && root.open
                    x: 14; anchors.verticalCenter: parent.verticalCenter
                    text: "Split " + row.modelData.number
                    font.pixelSize: Theme.fontCaption; font.weight: Font.DemiBold
                    color: row.activeStrip ? Theme.text : Theme.textTertiary
                }
                Rectangle {
                    visible: row.type === "split" && !root.open
                    anchors.centerIn: parent; width: parent.width - 16; height: 1; color: Theme.separator
                }

                // A group: colored label; click folds it, double-click renames, right-click for more.
                Rectangle {
                    id: groupRow
                    visible: row.type === "header"
                    objectName: row.type === "header" ? "verticalGroupLabel" : ""
                    anchors.fill: parent; anchors.margins: 2; anchors.leftMargin: 6; anchors.rightMargin: 6
                    radius: Theme.radiusSmall
                    color: row.type === "header" ? Theme.mix(Theme.sidebar, row.groupColor, groupHover.hovered ? .30 : .20) : "transparent"
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 6
                        spacing: 6
                        visible: root.open
                        Icon { name: row.label && row.label.collapsed ? "right" : "down"; size: Theme.fontSmall; color: row.groupColor }
                        Label {
                            visible: !nameField.visible
                            Layout.fillWidth: true
                            text: row.label ? row.label.name : ""
                            elide: Text.ElideRight
                            font.pixelSize: Theme.fontSmall; font.weight: Font.DemiBold
                            color: Theme.mix(row.groupColor, Theme.text, Theme.dark ? .1 : .35)
                        }
                        TextField {
                            id: nameField
                            objectName: row.type === "header" ? "verticalGroupNameField" : ""
                            visible: row.type === "header" && !!row.label && root.editingLabel === row.label.id
                            Layout.fillWidth: true
                            implicitHeight: parent.height - 4
                            padding: 1; leftPadding: 6
                            font.pixelSize: Theme.fontSmall
                            maximumLength: 120
                            function claim() { if (visible) { text = row.label.name; forceActiveFocus(); selectAll() } }
                            onVisibleChanged: claim()
                            Component.onCompleted: Qt.callLater(claim)
                            function finish() {
                                const label = root.editingLabel
                                root.editingLabel = ""
                                if (label.length && text.trim().length) root.controller.renameTabGroup(row.modelData.strip.id, label, text)
                            }
                            onAccepted: finish()
                            onActiveFocusChanged: if (!activeFocus && visible) finish()
                            Keys.onEscapePressed: root.editingLabel = ""
                        }
                        Label {
                            visible: !!row.label && row.label.collapsed
                            text: row.modelData.size || ""
                            font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
                        }
                    }
                    // Closed panel: the group's first letter in its color.
                    Label {
                        visible: !root.open && row.type === "header"
                        anchors.centerIn: parent
                        text: row.label ? row.label.name.charAt(0).toUpperCase() : ""
                        font.pixelSize: Theme.fontSmall; font.weight: Font.DemiBold
                        color: Theme.mix(row.groupColor, Theme.text, Theme.dark ? .1 : .35)
                    }
                    HoverHandler { id: groupHover }
                    TapHandler {
                        enabled: row.type === "header" && !nameField.visible
                        onTapped: { const strip = row.modelData.strip.id, label = row.label.id, folded = !row.label.collapsed; Qt.callLater(function() { root.controller.setTabGroupCollapsed(strip, label, folded) }) }
                        onDoubleTapped: root.editingLabel = row.label.id
                    }
                    TapHandler { acceptedButtons: Qt.RightButton; enabled: row.type === "header"; onTapped: root.view(row.modelData.strip.id).showGroupMenu(row.label.id) }
                    ToolTip.visible: groupHover.hovered && !root.open
                    ToolTip.text: row.label ? row.label.name : ""
                }

                // A tab: icon, full title, close on hover; a group's tabs carry its color on the left.
                Rectangle {
                    visible: row.type === "tab"
                    anchors.fill: parent; anchors.margins: 1; anchors.leftMargin: 6; anchors.rightMargin: 6
                    radius: Theme.radiusSmall
                    color: row.current ? (row.activeStrip ? Theme.selected : Theme.hover) : pointer.containsMouse || closeButton.hovered ? Theme.hover : "transparent"
                    border.width: !!root.controller.dropTarget && root.controller.dropTarget.join === (row.tab ? row.tab.id : "") ? 2 : 0
                    border.color: Theme.accent
                    Rectangle {
                        visible: !!row.label
                        x: 2; anchors.verticalCenter: parent.verticalCenter
                        width: 3; height: parent.height - 10; radius: 1.5
                        color: row.groupColor
                    }
                    Icon {
                        id: kindIcon
                        x: root.open ? (row.label ? 12 : 8) : (parent.width - width) / 2
                        anchors.verticalCenter: parent.verticalCenter
                        name: row.tab ? root.iconFor(row.tab) : ""
                        size: Theme.fontBody + 1
                        color: row.current && row.activeStrip ? Theme.selectedText : Theme.icon
                    }
                    Label {
                        visible: root.open
                        anchors.left: kindIcon.right; anchors.leftMargin: 8
                        anchors.right: closeButton.left; anchors.rightMargin: 2
                        anchors.verticalCenter: parent.verticalCenter
                        text: row.title
                        elide: Text.ElideRight
                        font.pixelSize: Theme.fontSmall
                        font.weight: row.current && row.activeStrip ? Font.Medium : Font.Normal
                        color: row.current ? (row.activeStrip ? Theme.selectedText : Theme.text) : Theme.textSecondary
                    }
                    MouseArea {
                        id: pointer
                        enabled: row.type === "tab"
                        anchors.fill: parent
                        anchors.rightMargin: root.open ? closeButton.width + 4 : 0
                        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                        hoverEnabled: true
                        preventStealing: true
                        property point start
                        property bool moving: false
                        property bool cancelled: false
                        onPressed: function(mouse) { start = mapToItem(null, mouse.x, mouse.y); moving = false; cancelled = false }
                        onPositionChanged: function(mouse) {
                            if (!pressed || cancelled || pressedButtons !== Qt.LeftButton) return
                            const p = mapToItem(null, mouse.x, mouse.y)
                            if (!moving && Math.abs(p.x - start.x) + Math.abs(p.y - start.y) > 8) { moving = true; root.controller.dragTitle = row.title }
                            if (moving) root.controller.dragTab(row.tab.id, p.x, p.y)
                        }
                        onReleased: function(mouse) {
                            if (cancelled) return
                            const id = row.tab.id
                            if (moving) {
                                const p = mapToItem(null, mouse.x, mouse.y)
                                root.controller.dragTab(id, p.x, p.y)
                                root.controller.finishDrag(false)
                            }
                            else if (mouse.button === Qt.RightButton) root.view(row.modelData.strip.id).showTabMenu(id)
                            else if (mouse.button === Qt.MiddleButton) Qt.callLater(function() { root.controller.closeTab(id) })
                            else { root.tabChosen(); Qt.callLater(function() { root.controller.activateTab(id) }) }
                            moving = false
                        }
                        onCanceled: { cancelled = true; moving = false; root.controller.finishDrag(true) }
                    }
                    IconButton {
                        id: closeButton
                        visible: root.open
                        objectName: row.tab ? "verticalTabClose-" + row.tab.id : ""
                        opacity: row.current || pointer.containsMouse || hovered ? 1 : 0
                        anchors.right: parent.right; anchors.rightMargin: 3
                        anchors.verticalCenter: parent.verticalCenter
                        width: Theme.controlHeightSmall - 2; height: width; glyphSize: Theme.fontBody
                        icon.name: "close"
                        description: "Close tab"
                        onClicked: { const id = row.tab.id; Qt.callLater(function() { root.controller.closeTab(id) }) }
                    }
                    ToolTip.visible: pointer.containsMouse && !pointer.pressed && !root.open
                    ToolTip.delay: 400
                    ToolTip.text: row.title
                }
            }
        }
    }
    Rectangle {
        anchors.right: parent.right; width: 1; height: parent.height
        color: resize.containsMouse || resize.pressed ? Theme.border : Theme.separator
    }
    MouseArea {
        id: resize
        objectName: "tabsPanelResize"
        visible: root.open
        anchors.right: parent.right; anchors.rightMargin: -3
        width: 6; height: parent.height
        hoverEnabled: true; cursorShape: Qt.SplitHCursor
        preventStealing: true
        property real origin
        property real initial
        onPressed: function(mouse) { origin = mapToItem(null, mouse.x, mouse.y).x; initial = root.openWidth }
        onPositionChanged: function(mouse) { if (pressed) root.openWidth = Math.max(180, Math.min(420, initial + mapToItem(null, mouse.x, mouse.y).x - origin)) }
        onReleased: root.widthChosen(root.openWidth)
    }
}
