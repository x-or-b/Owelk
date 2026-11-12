import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui

// Threads: folders of AI chats, in a panel of their own beside the AI panel (Main.qml keeps it on the
// outer side). A chat about a paper starts in its paper's Thread; others start in the Thread they were
// begun in, or unfiled. Threads can be made, renamed and deleted (their chats stay, unfiled); chats move
// by dragging or from their menu. Sorted latest first, or by hand (Manual).
Rectangle {
    id: root
    objectName: "threadsPanel"
    property var controller: null
    signal chatChosen(string id)
    // In a tab of its own (it stays in sync with the AI panel when that has it open too).
    signal chatInTabRequested(string id)
    // The document area: a chat dragged out of the list opens there (see DocumentWorkspace.dragChat).
    property var workspace: null
    property bool draggingOut: false
    // {folder}: a new chat in that Thread ("" or none: as a chat from the AI panel would start).
    signal newChatRequested(var spec)
    signal trashRequested()
    color: Theme.sidebar

    // Latest first, or Manual: in the order the chats and Threads were dragged to. Each keeps its place in the
    // library (`position`), so the order syncs with the rest; the sort itself is this computer's. One not placed
    // yet (a new one) goes first, latest first, and is placed there.
    property string sort: researchStore.setting("threads.sort", "recent")
    readonly property bool manual: sort === "manual"
    function setSort(value) { sort = value; researchStore.setSetting("threads.sort", value); placeNew() }
    // Threads unfolded (by folder ID; "unfiled" for the chats in none), remembered between sessions.
    property var openGroups: {
        try { return JSON.parse(researchStore.setting("threads.open", "{}")) || ({}) } catch (e) { return ({}) }
    }
    function setGroupOpen(key, open) {
        if (!!openGroups[key] === open) return
        const next = Object.assign({}, openGroups)
        if (open) next[key] = true
        else delete next[key]
        openGroups = next
        researchStore.setSetting("threads.open", JSON.stringify(next))
    }
    function groupKey(folder) { return folder.length ? folder : "unfiled" }
    property var chats: []
    property var folders: []
    // Chats whose words match the search (by id); null while there is no search.
    property var matched: null
    readonly property string needle: search.text.trim()
    function refresh() {
        chats = researchStore.aiThreads()
        folders = researchStore.aiFolders()
        placeNew()
        if (!needle.length) { matched = null; return }
        const found = {}
        researchStore.aiThreads(needle).forEach(function(chat) { found[chat.id] = true })
        matched = found
    }
    Timer { id: refreshTimer; interval: 150; onTriggered: root.refresh() }
    onNeedleChanged: refreshTimer.restart()
    Connections {
        target: researchStore
        function onAiThreadsChanged() { refreshTimer.restart() }
        function onDocumentsChanged() { refreshTimer.restart() }
    }
    // The open chat's Thread unfolds, so the chat shows where it is.
    function revealCurrent() {
        const id = controller ? controller.threadId : ""
        const chat = id.length ? chats.find(function(c) { return c.id === id }) : null
        if (chat) setGroupOpen(groupKey(chat.folder), true)
    }
    Connections { target: root.controller; function onThreadIdChanged() { root.revealCurrent() } }
    onChatsChanged: {
        const ids = chats.map(function(c) { return c.id })
        selectedChats = selectedChats.filter(function(id) { return ids.indexOf(id) >= 0 })
        revealCurrent()
    }
    Component.onCompleted: refresh()

    function placed(item) { return typeof item.position === "number" }
    // Sorted in place: latest first, or in Manual by place, those not placed yet first (latest first).
    function ordered(list, latestOf) {
        return list.sort(function(a, b) {
            const x = manual && placed(a), y = manual && placed(b)
            if (x && y) return a.position - b.position
            if (x) return 1
            if (y) return -1
            const p = latestOf(a), q = latestOf(b)
            return p < q ? 1 : p > q ? -1 : 0
        })
    }
    function chatsIn(folder) {
        return ordered(chats.filter(function(c) { return c.folder === folder }), function(c) { return c.openedAt })
    }
    // Every Thread (not Unfiled) as shown; a Thread is as recent as its latest chat.
    function threadsInOrder() {
        const latest = {}
        chats.forEach(function(c) { if (!latest[c.folder] || c.openedAt > latest[c.folder]) latest[c.folder] = c.openedAt })
        const list = folders.map(function(f) { const own = f.updatedAt || ""; return {id: f.id, position: f.position, latest: latest[f.id] > own ? latest[f.id] : own} })
        return ordered(list, function(g) { return g.latest })
    }
    // Places for `ids` put at `at` in `list` (as shown): between their neighbours; at an end, past it; with no room
    // left between them, or none placed, the whole list is numbered again.
    function between(list, at, ids) {
        const before = at > 0 ? list[at - 1].position : undefined, next = at < list.length ? list[at].position : undefined
        const places = {}
        const number = function(value) { return typeof value === "number" }
        if (number(before) && number(next) && next - before > 1e-9 * (ids.length + 1))
            ids.forEach(function(id, i) { places[id] = before + (next - before) * (i + 1) / (ids.length + 1) })
        else if (number(before) && at === list.length) ids.forEach(function(id, i) { places[id] = before + i + 1 })
        else if (at === 0 && number(next)) ids.forEach(function(id, i) { places[id] = next - ids.length + i })
        else {
            const all = list.map(function(item) { return item.id })
            all.splice(at, 0, ...ids)
            all.forEach(function(id, i) { places[id] = i + 1 })
        }
        return places
    }
    // In Manual, chats and Threads not placed yet (new ones, or all of them the first time) are placed where they
    // show: above the placed ones, latest first. The order this computer kept before places synced is taken once.
    function placeNew() {
        if (!manual || adoptKept()) return
        const ahead = function(list, places) {
            const fresh = list.filter(function(item) { return !placed(item) })
            if (!fresh.length) return
            const first = list.find(placed)
            const top = first ? first.position : 0
            fresh.forEach(function(item, i) { places[item.id] = top - fresh.length + i })
        }
        const threads = {}, chatPlaces = {}, seen = {}
        ahead(threadsInOrder(), threads)
        chats.forEach(function(c) {
            if (seen[c.folder]) return
            seen[c.folder] = true
            ahead(chatsIn(c.folder), chatPlaces)
        })
        if (Object.keys(threads).length) researchStore.placeAiFolders(threads)
        if (Object.keys(chatPlaces).length) researchStore.placeAiThreads(chatPlaces)
    }
    // The order kept in this computer's settings before it moved into the library: {threads: [ID], chats: {key: [ID]}}.
    // True when it placed something (the rest is placed once the lists are read again).
    function adoptKept() {
        const text = researchStore.setting("threads.order")
        if (!text.length) return false
        researchStore.setSetting("threads.order", "")
        let kept = null
        try { kept = JSON.parse(text) } catch (e) { return false }
        const threads = {}, chatPlaces = {}
        ;(kept.threads || []).forEach(function(id, i) { if (folders.some(function(f) { return f.id === id && !placed(f) })) threads[id] = i + 1 })
        Object.keys(kept.chats || {}).forEach(function(key) {
            ;(kept.chats[key] || []).forEach(function(id, i) { if (chats.some(function(c) { return c.id === id && !placed(c) })) chatPlaces[id] = i + 1 })
        })
        if (!Object.keys(threads).length && !Object.keys(chatPlaces).length) return false
        researchStore.placeAiFolders(threads)
        researchStore.placeAiThreads(chatPlaces)
        return true
    }
    // Manual: chats dropped before or after another chat, in its Thread (they move there if they were elsewhere).
    function placeChats(ids, target, after) {
        const goal = chats.find(function(c) { return c.id === target })
        if (!goal) return
        const moving = ids.filter(function(id) { return id !== target })
        if (!moving.length) return
        const shown = rows.filter(function(r) { return r.type === "chat" }).map(function(r) { return r.chat.id })
        moving.sort(function(a, b) { return shown.indexOf(a) - shown.indexOf(b) })
        const elsewhere = moving.filter(function(id) { const c = chats.find(function(x) { return x.id === id }); return c && c.folder !== goal.folder })
        if (elsewhere.length) researchStore.moveAiThreads(elsewhere, goal.folder)
        const list = chatsIn(goal.folder).filter(function(c) { return moving.indexOf(c.id) < 0 })
        researchStore.placeAiThreads(between(list, list.findIndex(function(c) { return c.id === target }) + (after ? 1 : 0), moving))
    }
    // Manual: a Thread dropped before or after another (Unfiled stays last; dropped on it, the Thread goes last).
    function placeThread(id, target, after) {
        if (id === target) return
        const list = threadsInOrder().filter(function(g) { return g.id !== id })
        const at = target.length ? list.findIndex(function(g) { return g.id === target }) : -1
        researchStore.placeAiFolders(between(list, at < 0 ? list.length : at + (after ? 1 : 0), [id]))
    }
    // Threads by name, for the Move To menu.
    readonly property var foldersByName: folders.slice().sort(function(a, b) { return a.name.localeCompare(b.name) })
    // The list as rows: each Thread (folded or not) with its chats, then the unfiled chats.
    readonly property var rows: {
        const words = needle.toLowerCase(), found = matched
        const hit = function(chat) { return !found || !!found[chat.id] }
        const members = {}
        chats.forEach(function(chat) { (members[chat.folder] = members[chat.folder] || []).push(chat) })
        const group = function(id, name, updatedAt, position) {
            const all = members[id] || []
            const named = words.length > 0 && name.toLowerCase().indexOf(words) >= 0
            const list = ordered(named ? all.slice() : all.filter(hit), function(c) { return c.openedAt })
            const latest = list.reduce(function(m, c) { return c.openedAt > m ? c.openedAt : m }, updatedAt || "")
            return {type: "group", id: id, key: groupKey(id), name: name, chats: list, latest: latest, count: all.length, named: named, position: position}
        }
        const groups = folders.map(function(f) { return group(f.id, f.name, f.updatedAt, f.position) })
            .filter(function(g) { return !words.length || g.named || g.chats.length })
        ordered(groups, function(g) { return g.latest })
        const unfiled = group("", qsTr("Unfiled"), "")
        if ((!words.length && (groups.length || unfiled.count)) || unfiled.chats.length) groups.push(unfiled)
        const list = []
        groups.forEach(function(g) {
            const open = (words.length > 0 && g.chats.length > 0) || !!openGroups[g.key]
            list.push(Object.assign({}, g, {open: open}))
            if (open) g.chats.forEach(function(chat) { list.push({type: "chat", key: chat.id, chat: chat, folder: g.id}) })
        })
        return list
    }

    // Chats chosen in the list (Cmd/Ctrl-click, Shift-click), and the row a Shift range starts from.
    property var selectedChats: []
    property int selectionAnchor: -1
    function toggleChat(id, index) {
        selectedChats = selectedChats.indexOf(id) >= 0 ? selectedChats.filter(function(t) { return t !== id }) : selectedChats.concat([id])
        selectionAnchor = index
    }
    function selectRange(index) {
        const from = selectionAnchor < 0 ? index : selectionAnchor
        selectedChats = rows.slice(Math.min(from, index), Math.max(from, index) + 1)
            .filter(function(row) { return row.type === "chat" }).map(function(row) { return row.chat.id })
    }
    function trashChats(ids) {
        if (!ids.length) return
        if (controller && ids.indexOf(controller.threadId) >= 0) controller.showThreads()
        selectedChats = []
        researchStore.trashAiThreads(ids)
    }
    function moveChats(ids, folder) {
        if (researchStore.moveAiThreads(ids, folder)) setGroupOpen(groupKey(folder), true)
    }
    // A new Thread, named, with a new chat in it.
    function newThread(name) {
        const id = researchStore.createAiFolder(name)
        if (!id.length) return ""
        setGroupOpen(id, true)
        newChatRequested({folder: id})
        return id
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 8
        spacing: 6
        RowLayout {
            Layout.fillWidth: true; Layout.minimumWidth: 0
            spacing: 2
            Label {
                Layout.fillWidth: true; Layout.minimumWidth: 0
                text: qsTr("Threads")
                elide: Text.ElideRight
                font.pixelSize: Theme.fontBody; font.weight: Font.DemiBold; color: Theme.text
            }
            IconButton {
                id: sortButton
                objectName: "threadsSort"
                icon.name: "sort"; description: qsTr("Sort")
                onClicked: sortMenu.popup(sortButton, 0, sortButton.height)
                Menu {
                    id: sortMenu
                    objectName: "threadsSortMenu"
                    MenuItem { objectName: "threadsSortRecent"; text: qsTr("Recent First"); checkable: true; checked: !root.manual; onTriggered: root.setSort("recent") }
                    MenuItem { objectName: "threadsSortManual"; text: qsTr("Manual"); checkable: true; checked: root.manual; onTriggered: root.setSort("manual") }
                }
            }
            IconButton { objectName: "threadsTrash"; icon.name: "trash"; description: qsTr("Trash (in the Library)"); onClicked: root.trashRequested() }
            IconButton { objectName: "threadsNewThread"; icon.name: "add"; description: qsTr("New Thread"); onClicked: nameDialog.begin("new", "", "") }
        }
        TextField {
            id: search
            objectName: "threadsSearch"
            Layout.fillWidth: true; Layout.minimumWidth: 0
            implicitHeight: Theme.controlHeight
            font.pixelSize: Theme.fontSmall
            placeholderText: qsTr("Search chats")
            Keys.onEscapePressed: text = ""
        }
        // Click opens a chat or folds a Thread; Cmd/Ctrl-click and Shift-click choose several chats; a drag
        // moves them to another Thread (in Manual, to a place among the chats too); Delete or the right-click
        // menu moves them to the Trash.
        ListView {
            id: list
            objectName: "threadsList"
            Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumWidth: 0
            clip: true
            // Mouse drags move chats; the wheel and trackpad scroll.
            acceptedButtons: Qt.NoButton
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}
            model: root.rows
            property int clickModifiers: 0
            Keys.onDeletePressed: root.trashChats(root.selectedChats)
            Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Backspace && root.selectedChats.length) { root.trashChats(root.selectedChats); event.accepted = true }
            }
            delegate: ItemDelegate {
                id: row
                required property var modelData
                required property int index
                readonly property bool isGroup: modelData.type === "group"
                readonly property bool chosen: !isGroup && root.selectedChats.indexOf(modelData.chat.id) >= 0
                readonly property bool current: !isGroup && !!root.controller && root.controller.threadId === modelData.chat.id
                // Its answer is still being written (it may be in the background).
                readonly property bool answering: !isGroup && !!root.controller && root.controller.answeringThreads.indexOf(modelData.chat.id) >= 0
                objectName: isGroup ? "threadsGroup-" + modelData.name : "threadsChat-" + index
                width: ListView.view.width
                height: Theme.rowHeight
                highlighted: chosen || current
                leftPadding: isGroup ? 22 : 30
                rightPadding: isGroup || answering ? 30 : 8
                contentItem: Label {
                    text: row.isGroup ? row.modelData.name : row.modelData.chat.title
                    elide: Text.ElideRight; textFormat: Text.PlainText
                    color: row.highlighted ? Theme.selectedText : row.isGroup && !row.modelData.id.length ? Theme.textSecondary : Theme.text
                }
                Icon {
                    visible: row.isGroup
                    x: 6; anchors.verticalCenter: parent.verticalCenter
                    name: row.isGroup && row.modelData.open ? "down" : "right"; size: Theme.fontSmall; color: Theme.textTertiary
                }
                // A Thread's count; under the pointer, a + for a new chat in it.
                Label {
                    visible: row.isGroup && !row.hovered
                    anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
                    text: row.isGroup ? row.modelData.count : ""; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
                }
                BusyIndicator {
                    objectName: "threadsAnswering-" + row.index
                    visible: row.answering
                    running: visible
                    anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
                    implicitWidth: 14; implicitHeight: 14
                }
                IconButton {
                    objectName: "threadsGroupAdd"
                    visible: row.isGroup && row.hovered
                    anchors.right: parent.right; anchors.rightMargin: 2; anchors.verticalCenter: parent.verticalCenter
                    width: 22; height: 22; glyphSize: Theme.fontBody
                    icon.name: "add"; description: qsTr("New chat in this Thread")
                    onClicked: root.newChatRequested({folder: row.modelData.id})
                }
                ToolTip.visible: hovered && !isGroup && !dragHandler.active
                ToolTip.delay: 600
                ToolTip.text: isGroup ? "" : modelData.chat.title + (modelData.chat.paper ? "\n" + modelData.chat.paper : "")
                onClicked: {
                    list.forceActiveFocus()
                    if (isGroup) { root.setGroupOpen(modelData.key, !modelData.open); return }
                    const mods = list.clickModifiers
                    const id = modelData.chat.id
                    if (mods & (Qt.ControlModifier | Qt.MetaModifier)) root.toggleChat(id, index)
                    else if (mods & Qt.ShiftModifier) root.selectRange(index)
                    else { root.selectedChats = []; root.selectionAnchor = index; Qt.callLater(function() { root.chatChosen(id) }) }
                }
                TapHandler {
                    acceptedButtons: Qt.LeftButton
                    acceptedModifiers: Qt.KeyboardModifierMask
                    // Only notes the keys held; the click itself goes to the row.
                    onPressedChanged: if (pressed) list.clickModifiers = point.modifiers
                }
                ContextTap {
                    onRequested: {
                        if (row.isGroup) { groupMenu.group = row.modelData; groupMenu.popup(); return }
                        if (!row.chosen) root.selectedChats = [row.modelData.chat.id]
                        chatMenu.ids = root.selectedChats.slice()
                        chatMenu.chat = row.modelData.chat
                        chatMenu.popup()
                    }
                }
                // Dragging a chosen chat moves every chosen one. In Manual, a Thread is dragged to another place too.
                DragHandler {
                    id: dragHandler
                    enabled: !row.isGroup || (root.manual && row.modelData.id.length > 0)
                    target: null
                    onActiveChanged: {
                        if (active) {
                            if (row.isGroup) { dragProxy.kind = "thread"; dragProxy.title = row.modelData.name; dragProxy.ids = [row.modelData.id]; return }
                            dragProxy.kind = "chats"
                            const id = row.modelData.chat.id
                            dragProxy.ids = root.selectedChats.indexOf(id) >= 0 ? root.selectedChats.slice() : [id]
                            dragProxy.title = dragProxy.ids.length > 1 ? dragProxy.ids.length + qsTr(" chats") : row.modelData.chat.title
                        } else {
                            const out = root.draggingOut
                            root.draggingOut = false
                            if (out) root.workspace.finishDrag(false)
                            if (dragProxy.Drag.active) {
                                if (!out) dragProxy.Drag.drop()
                                dragProxy.ids = []
                            }
                        }
                    }
                    onCentroidChanged: if (active) {
                        const at = row.mapToItem(root, centroid.position.x, centroid.position.y)
                        dragProxy.x = at.x + 8; dragProxy.y = at.y - dragProxy.height / 2
                        // Out of the list, one chat goes where a dragged tab would.
                        const out = dragProxy.kind === "chats" && !!root.workspace && dragProxy.ids.length === 1 && (at.x < 0 || at.y < 0 || at.x > root.width || at.y > root.height)
                        if (out) {
                            const p = row.mapToItem(null, centroid.position.x, centroid.position.y)
                            root.workspace.dragChat(dragProxy.ids[0], dragProxy.title, p.x, p.y)
                        } else if (root.draggingOut) root.workspace.finishDrag(true)
                        root.draggingOut = out
                    }
                }
                // Chats onto a Thread go into it; in Manual, chats onto a chat and a Thread onto a Thread go before or
                // after it (the line shows where).
                DropArea {
                    id: drop
                    anchors.fill: parent
                    keys: ["owelk/chats"]
                    property string act: ""
                    function actFor(source, y) {
                        if (!source) return ""
                        if (source.kind === "thread") return root.manual && row.isGroup ? (y > height / 2 && row.modelData.id.length ? "after" : "before") : ""
                        if (row.isGroup) return "into"
                        return root.manual ? (y > height / 2 ? "after" : "before") : ""
                    }
                    onEntered: function(drag) { act = actFor(drag.source, drag.y); drag.accepted = act.length > 0 }
                    onPositionChanged: function(drag) { act = actFor(drag.source, drag.y) }
                    onExited: act = ""
                    // After the drop: the list is laid out again, which would take this row (and the drag) with it.
                    onDropped: function(event) {
                        const how = actFor(event.source, event.y), ids = event.source.ids.slice(), thread = event.source.kind === "thread"
                        const target = row.isGroup ? row.modelData.id : row.modelData.chat.id
                        act = ""
                        Qt.callLater(function() {
                            if (how === "into") root.moveChats(ids, target)
                            else if (thread) root.placeThread(ids[0], target, how === "after")
                            else if (how.length) root.placeChats(ids, target, how === "after")
                        })
                    }
                    Rectangle { anchors.fill: parent; color: "transparent"; border.color: Theme.accent; radius: Theme.radius; visible: drop.containsDrag && drop.act === "into" }
                    Rectangle {
                        objectName: "threadsDropLine"
                        visible: drop.containsDrag && (drop.act === "before" || drop.act === "after")
                        x: row.isGroup ? 4 : 24; width: parent.width - x - 4; height: 2; radius: 1
                        y: drop.act === "after" ? parent.height - 1 : -1
                        color: Theme.accent
                    }
                }
            }
            Label {
                anchors.centerIn: parent
                width: parent.width - 16
                visible: list.count === 0
                text: root.needle.length ? qsTr("No chat matches.") : qsTr("Chats about a paper gather in its Thread. Make your own Threads with +.")
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere; horizontalAlignment: Text.AlignHCenter
                color: Theme.textTertiary; font.pixelSize: Theme.fontSmall
            }
        }
    }
    // What follows the pointer while chats are dragged to another Thread or place (or a Thread, in Manual).
    Rectangle {
        id: dragProxy
        objectName: "threadsDragProxy"
        property var ids: []
        // "chats", or "thread" (a Thread moved in Manual)
        property string kind: "chats"
        property string title
        visible: ids.length > 0 && !root.draggingOut
        width: Math.min(root.width - 16, proxyLabel.implicitWidth + 16); height: Theme.rowHeight
        radius: Theme.radius; color: Theme.raised; border.color: Theme.border
        Drag.active: ids.length > 0
        Drag.keys: ["owelk/chats"]
        Drag.source: dragProxy
        Drag.hotSpot: Qt.point(0, height / 2)
        Label {
            id: proxyLabel
            anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
            verticalAlignment: Text.AlignVCenter
            text: dragProxy.title; elide: Text.ElideRight; textFormat: Text.PlainText
            font.pixelSize: Theme.fontSmall; color: Theme.text
        }
    }
    // A chat: rename it, move it (or every chosen one) to another Thread, or trash it.
    Menu {
        id: chatMenu
        objectName: "threadsChatMenu"
        property var ids: []
        property var chat: ({})
        MenuItem {
            objectName: "threadsOpenInTab"
            visible: chatMenu.ids.length === 1
            height: visible ? implicitHeight : 0
            text: qsTr("Open in New Tab")
            onTriggered: { const id = chatMenu.chat.id; Qt.callLater(function() { root.chatInTabRequested(id) }) }
        }
        MenuItem {
            visible: chatMenu.ids.length === 1
            height: visible ? implicitHeight : 0
            text: qsTr("Rename…")
            onTriggered: nameDialog.begin("chat", chatMenu.chat.id, chatMenu.chat.title)
        }
        Menu {
            id: moveMenu
            objectName: "threadsMoveMenu"
            title: qsTr("Move To")
            Instantiator {
                model: root.foldersByName.concat([{id: "", name: qsTr("Unfiled")}])
                delegate: MenuItem {
                    required property var modelData
                    objectName: "threadsMoveTo-" + modelData.name
                    text: modelData.name
                    checkable: true
                    checked: chatMenu.ids.length === 1 && chatMenu.chat.folder === modelData.id
                    onTriggered: root.moveChats(chatMenu.ids, modelData.id)
                }
                onObjectAdded: function(index, item) { moveMenu.insertItem(index, item) }
                onObjectRemoved: function(index, item) { moveMenu.removeItem(item) }
            }
        }
        MenuSeparator {}
        MenuItem {
            objectName: "threadsTrashChat"
            text: chatMenu.ids.length > 1 ? qsTr("Move ") + chatMenu.ids.length + qsTr(" to Trash") : qsTr("Move to Trash")
            palette.windowText: Theme.danger
            onTriggered: root.trashChats(chatMenu.ids)
        }
    }
    // A Thread: a new chat in it, a new name, or gone (its chats stay, unfiled).
    Menu {
        id: groupMenu
        objectName: "threadsGroupMenu"
        property var group: ({})
        readonly property bool folder: !!group.id && group.id.length > 0
        MenuItem { objectName: "threadsGroupNewChat"; text: qsTr("New Chat Here"); onTriggered: root.newChatRequested({folder: groupMenu.group.id}) }
        MenuItem {
            objectName: "threadsGroupRename"
            visible: groupMenu.folder; height: visible ? implicitHeight : 0
            text: qsTr("Rename…")
            onTriggered: nameDialog.begin("folder", groupMenu.group.id, groupMenu.group.name)
        }
        MenuItem {
            objectName: "threadsGroupDelete"
            visible: groupMenu.folder; height: visible ? implicitHeight : 0
            text: qsTr("Delete Thread")
            palette.windowText: Theme.danger
            onTriggered: researchStore.deleteAiFolder(groupMenu.group.id)
        }
    }
    // Names a new Thread, or renames a Thread or a chat.
    Dialog {
        id: nameDialog
        objectName: "threadsNameDialog"
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: 360
        modal: true
        property string kind: ""
        property string target: ""
        function begin(what, id, name) {
            kind = what; target = id
            nameField.text = name
            open()
            nameField.selectAll(); nameField.forceActiveFocus()
        }
        title: kind === "chat" ? qsTr("Rename Chat") : kind === "folder" ? qsTr("Rename Thread") : qsTr("New Thread")
        standardButtons: Dialog.Ok | Dialog.Cancel
        TextField { id: nameField; objectName: "threadsNameField"; width: parent.width; placeholderText: qsTr("Name"); onAccepted: nameDialog.accept() }
        onAccepted: {
            if (kind === "chat") researchStore.renameAiThread(target, nameField.text)
            else if (kind === "folder") researchStore.renameAiFolder(target, nameField.text)
            else root.newThread(nameField.text)
        }
    }
}
