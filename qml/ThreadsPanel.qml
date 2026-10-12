import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui

// Threads: AI chats gathered by paper and by collection, in a panel of their own beside the AI panel
// (Main.qml keeps it on the outer side). A chat opens in the AI panel; opened from a collection, its next
// questions are asked of the collection's papers.
Rectangle {
    id: root
    objectName: "threadsPanel"
    property var controller: null
    property var reader: null
    signal chatChosen(string id, var within)
    // {source} for a paper (empty: the one in the reader), {collection, collectionName} for a collection.
    signal newChatRequested(var spec)
    signal paperRequested(url source)
    signal collectionRequested(string id)
    signal trashRequested()
    color: Theme.sidebar

    property string sort: researchStore.setting("threads.sort", "recent")
    function setSort(value) { sort = value; researchStore.setSetting("threads.sort", value) }
    // Groups unfolded, by key ("collection:<id>", "paper:<id>"), remembered between sessions.
    property var openGroups: {
        try { return JSON.parse(researchStore.setting("threads.open", "{}")) || ({}) } catch (e) { return ({}) }
    }
    function toggleGroup(key) {
        const next = Object.assign({}, openGroups)
        if (next[key]) delete next[key]
        else next[key] = true
        openGroups = next
        researchStore.setSetting("threads.open", JSON.stringify(next))
    }
    property var chats: []
    property var collectionList: []
    // Chats whose words match the search (by id); null while there is no search.
    property var matched: null
    readonly property string needle: search.text.trim()
    function refresh() {
        chats = researchStore.aiThreads()
        collectionList = researchStore.collections()
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
    Component.onCompleted: refresh()

    readonly property string paperKey: reader && reader.source ? reader.source.toString() : ""
    function byChat(a, b) {
        if (sort === "name") return a.title.localeCompare(b.title)
        return a.openedAt < b.openedAt ? 1 : a.openedAt > b.openedAt ? -1 : 0
    }
    function byGroup(a, b) {
        if (sort === "name") return a.name.localeCompare(b.name)
        return a.latest < b.latest ? 1 : a.latest > b.latest ? -1 : 0
    }
    // The list as rows: section headings, groups (folded or not) and chats.
    readonly property var rows: {
        const words = needle.toLowerCase(), found = matched
        const hit = function(chat) { return !found || !!found[chat.id] }
        const named = function(name) { return words.length > 0 && (name || "").toLowerCase().indexOf(words) >= 0 }
        const group = function(kind, id, name, members, extra) {
            const list = named(name) ? members : members.filter(hit)
            if (!list.length) return null
            list.sort(byChat)
            const latest = list.reduce(function(m, c) { return c.openedAt > m ? c.openedAt : m }, "")
            return Object.assign({type: "group", kind: kind, id: id, key: kind + ":" + id, name: name, chats: list, latest: latest}, extra || {})
        }
        const here = paperKey.length ? chats.filter(function(c) { return c.source.toString() === paperKey }) : []
        const collections = collectionList.map(function(c) {
            return group("collection", c.id, c.name, chats.filter(function(chat) { return chat.collections.indexOf(c.id) >= 0 }))
        }).filter(function(g) { return g !== null }).sort(byGroup)
        const papers = {}
        chats.forEach(function(chat) {
            const source = chat.source.toString()
            if (!source.length || source === paperKey) return
            const key = chat.document || source
            if (!papers[key]) papers[key] = {source: chat.source, name: chat.paper || source.replace(/^.*\//, ""), list: []}
            papers[key].list.push(chat)
        })
        const paperGroups = Object.keys(papers).map(function(key) {
            return group("paper", key, papers[key].name, papers[key].list, {source: papers[key].source})
        }).filter(function(g) { return g !== null }).sort(byGroup)
        const other = chats.filter(function(c) { return !c.source.toString().length && !c.collections.length && hit(c) }).sort(byChat)
        const list = []
        const section = function(key, title) { list.push({type: "section", key: key, title: title}) }
        const chatRow = function(chat, depth, within) { list.push({type: "chat", key: chat.id + "/" + list.length, chat: chat, depth: depth, within: within || null}) }
        const shownHere = here.filter(function(c) { return hit(c) || named(c.paper) }).sort(byChat)
        if (shownHere.length) {
            section("here", qsTr("This Paper"))
            shownHere.forEach(function(chat) { chatRow(chat, 0) })
        }
        const addGroups = function(groups) {
            groups.forEach(function(g) {
                const open = words.length > 0 || !!openGroups[g.key]
                list.push(Object.assign({}, g, {open: open, count: g.chats.length}))
                if (open) g.chats.forEach(function(chat) {
                    chatRow(chat, 1, g.kind === "collection" ? {collection: g.id, collectionName: g.name} : null)
                })
            })
        }
        if (collections.length) { section("collections", qsTr("Collections")); addGroups(collections) }
        if (paperGroups.length) { section("papers", qsTr("Papers")); addGroups(paperGroups) }
        if (other.length) {
            section("other", qsTr("Other"))
            other.forEach(function(chat) { chatRow(chat, 0) })
        }
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
        const ids = []
        rows.slice(Math.min(from, index), Math.max(from, index) + 1).forEach(function(row) {
            if (row.type === "chat" && ids.indexOf(row.chat.id) < 0) ids.push(row.chat.id)
        })
        selectedChats = ids
    }
    function trashChats(ids) {
        if (!ids.length) return
        if (controller && ids.indexOf(controller.threadId) >= 0) controller.showThreads()
        selectedChats = []
        researchStore.trashAiThreads(ids)
    }
    onChatsChanged: {
        const ids = chats.map(function(c) { return c.id })
        selectedChats = selectedChats.filter(function(id) { return ids.indexOf(id) >= 0 })
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
                    MenuItem { objectName: "threadsSortRecent"; text: qsTr("Recent First"); checkable: true; checked: root.sort !== "name"; onTriggered: root.setSort("recent") }
                    MenuItem { objectName: "threadsSortName"; text: qsTr("By Name"); checkable: true; checked: root.sort === "name"; onTriggered: root.setSort("name") }
                }
            }
            IconButton { objectName: "threadsTrash"; icon.name: "trash"; description: qsTr("Trash (in the Library)"); onClicked: root.trashRequested() }
            IconButton { objectName: "threadsNewChat"; icon.name: "add"; description: qsTr("New chat"); onClicked: root.newChatRequested({}) }
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
        // Click opens a chat; Cmd/Ctrl-click and Shift-click choose several; Delete or the right-click
        // menu moves them to the Trash.
        ListView {
            id: list
            objectName: "threadsList"
            Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumWidth: 0
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}
            model: root.rows
            property int clickModifiers: 0
            Keys.onDeletePressed: root.trashChats(root.selectedChats)
            Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Backspace && root.selectedChats.length) { root.trashChats(root.selectedChats); event.accepted = true }
            }
            delegate: Item {
                id: entry
                required property var modelData
                required property int index
                readonly property string type: modelData.type
                readonly property bool chosen: type === "chat" && root.selectedChats.indexOf(modelData.chat.id) >= 0
                readonly property bool current: type === "chat" && !!root.controller && root.controller.threadId === modelData.chat.id
                width: ListView.view.width
                height: type === "section" ? Theme.rowHeight + (index > 0 ? 4 : 0) : Theme.rowHeight
                Label {
                    visible: entry.type === "section"
                    anchors.left: parent.left; anchors.leftMargin: 6; anchors.bottom: parent.bottom; anchors.bottomMargin: 4
                    text: entry.modelData.title || ""
                    font.pixelSize: Theme.fontCaption; font.weight: Font.DemiBold; color: Theme.textSecondary
                }
                ItemDelegate {
                    id: row
                    objectName: entry.type === "group" ? "threadsGroup-" + entry.modelData.name : entry.type === "chat" ? "threadsChat-" + entry.index : ""
                    visible: entry.type !== "section"
                    anchors.fill: parent
                    highlighted: entry.chosen || entry.current
                    leftPadding: entry.type === "group" ? 22 : entry.modelData.depth ? 30 : 8
                    rightPadding: entry.type === "group" ? 30 : 8
                    contentItem: Label {
                        text: entry.type === "group" ? entry.modelData.name : entry.type === "chat" ? entry.modelData.chat.title : ""
                        elide: Text.ElideRight; textFormat: Text.PlainText
                        color: row.highlighted ? Theme.selectedText : Theme.text
                    }
                    Icon {
                        visible: entry.type === "group"
                        x: 6; anchors.verticalCenter: parent.verticalCenter
                        name: entry.modelData.open ? "down" : "right"; size: Theme.fontSmall; color: Theme.textTertiary
                    }
                    Label {
                        visible: entry.type === "group"
                        anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
                        text: entry.modelData.count || ""; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
                    }
                    ToolTip.visible: hovered && entry.type === "chat"
                    ToolTip.delay: 600
                    ToolTip.text: entry.type === "chat" ? entry.modelData.chat.title + (entry.modelData.chat.paper ? "\n" + entry.modelData.chat.paper : "") : ""
                    onClicked: {
                        list.forceActiveFocus()
                        if (entry.type === "group") { root.toggleGroup(entry.modelData.key); return }
                        const mods = list.clickModifiers
                        const id = entry.modelData.chat.id, within = entry.modelData.within
                        if (mods & (Qt.ControlModifier | Qt.MetaModifier)) root.toggleChat(id, entry.index)
                        else if (mods & Qt.ShiftModifier) root.selectRange(entry.index)
                        else { root.selectedChats = []; root.selectionAnchor = entry.index; Qt.callLater(function() { root.chatChosen(id, within) }) }
                    }
                    TapHandler {
                        acceptedButtons: Qt.LeftButton
                        acceptedModifiers: Qt.KeyboardModifierMask
                        // Only notes the keys held; the click itself goes to the row.
                        onPressedChanged: if (pressed) list.clickModifiers = point.modifiers
                    }
                    TapHandler {
                        acceptedButtons: Qt.RightButton
                        onTapped: {
                            if (entry.type === "group") { groupMenu.group = entry.modelData; groupMenu.popup(); return }
                            if (!entry.chosen) root.selectedChats = [entry.modelData.chat.id]
                            chatMenu.ids = root.selectedChats.slice()
                            chatMenu.chat = entry.modelData.chat
                            chatMenu.popup()
                        }
                    }
                }
            }
            Label {
                anchors.centerIn: parent
                width: parent.width - 16
                visible: list.count === 0
                text: root.needle.length ? qsTr("No chat matches.") : qsTr("Ask about a selection, page or figure, or start a chat with +.")
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere; horizontalAlignment: Text.AlignHCenter
                color: Theme.textTertiary; font.pixelSize: Theme.fontSmall
            }
        }
    }
    // A chat: rename it, file it under collections (its paper's collections are fixed), or trash it.
    Menu {
        id: chatMenu
        objectName: "threadsChatMenu"
        property var ids: []
        property var chat: ({})
        readonly property bool single: ids.length === 1
        MenuItem {
            visible: chatMenu.single
            height: visible ? implicitHeight : 0
            text: qsTr("Rename…")
            onTriggered: { renameDialog.chatId = chatMenu.chat.id; renameField.text = chatMenu.chat.title; renameDialog.open() }
        }
        Menu {
            id: fileMenu
            objectName: "threadsFileMenu"
            title: qsTr("Collections")
            enabled: chatMenu.single && root.collectionList.length > 0
            Instantiator {
                model: chatMenu.single ? root.collectionList : []
                delegate: MenuItem {
                    required property var modelData
                    readonly property var chat: chatMenu.chat
                    readonly property bool chosen: (chat.chosenCollections || []).indexOf(modelData.id) >= 0
                    objectName: "threadsFile-" + modelData.name
                    text: modelData.name
                    checkable: true
                    checked: (chat.collections || []).indexOf(modelData.id) >= 0
                    // Filed through its paper: taken out by taking the paper out of the collection.
                    enabled: chosen || !checked
                    onTriggered: researchStore.setAiThreadCollection(chat.id, modelData.id, !chosen)
                }
                onObjectAdded: function(index, item) { fileMenu.insertItem(index, item) }
                onObjectRemoved: function(index, item) { fileMenu.removeItem(item) }
            }
        }
        MenuSeparator {}
        MenuItem {
            objectName: "threadsTrashChat"
            text: chatMenu.ids.length > 1 ? qsTr("Move ") + chatMenu.ids.length + qsTr(" to Trash") : qsTr("Move to Trash")
            onTriggered: root.trashChats(chatMenu.ids)
        }
    }
    Menu {
        id: groupMenu
        objectName: "threadsGroupMenu"
        property var group: ({})
        MenuItem {
            objectName: "threadsGroupNewChat"
            text: qsTr("New Chat Here")
            onTriggered: root.newChatRequested(groupMenu.group.kind === "collection" ? {collection: groupMenu.group.id, collectionName: groupMenu.group.name} : {source: groupMenu.group.source})
        }
        MenuItem {
            text: groupMenu.group.kind === "collection" ? qsTr("Show in Library") : qsTr("Open Paper")
            onTriggered: {
                if (groupMenu.group.kind === "collection") root.collectionRequested(groupMenu.group.id)
                else root.paperRequested(groupMenu.group.source)
            }
        }
    }
    Dialog {
        id: renameDialog
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: 360
        modal: true
        title: qsTr("Rename Chat")
        property string chatId: ""
        standardButtons: Dialog.Ok | Dialog.Cancel
        TextField { id: renameField; objectName: "threadsRenameField"; width: parent.width; onAccepted: renameDialog.accept() }
        onAccepted: researchStore.renameAiThread(chatId, renameField.text)
    }
}
