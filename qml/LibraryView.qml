import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui
import QtQuick.Dialogs as Native

// Every paper in the library, filtered by reading state, favorites, collection or tag.
// Papers are referenced, never copied: collections and tags only group them.
Rectangle {
    id: root
    objectName: "libraryView"
    color: Theme.content
    property var filter: ({})
    property string sort: "opened"
    property string query: ""
    property var rows: []
    property var collectionRows: []
    property int unsortedCount: 0
    // Papers chosen with Cmd/Ctrl-click or Shift-click (URLs as strings), for moving several at once.
    property var selection: []
    property int selectionAnchor: -1
    function isSelected(url) { return selection.indexOf(url.toString()) >= 0 }
    function rowClicked(index) {
        const row = rows[index], url = row.url.toString(), mods = researchStore.keyboardModifiers()
        if (mods & Qt.ShiftModifier && selectionAnchor >= 0) {
            const a = Math.min(selectionAnchor, index), b = Math.max(selectionAnchor, index)
            selection = rows.slice(a, b + 1).map(function(r) { return r.url.toString() })
        } else if (mods & Qt.ControlModifier) {
            selection = isSelected(url) ? selection.filter(function(u) { return u !== url }) : selection.concat([url])
            selectionAnchor = index
        } else {
            selection = []; selectionAnchor = index
            root.documentChosen(row.url, row.position)
        }
    }
    // The papers an action applies to: the selection when the row is part of it, else that row.
    function papersFor(row) { return isSelected(row.url) ? selection : [row.url.toString()] }
    property var tagRows: []
    property var noteRows: []
    readonly property bool showingNotes: !!(filter.notes || filter.notesTrash)
    signal noteChosen(string id)
    signal newNoteRequested()
    signal documentChosen(url source, var position)
    signal filterEdited(var filter)
    function refresh() {
        const f = Object.assign({}, filter)
        if (query.trim().length) f.text = query.trim()
        f.sort = sort
        rows = researchStore.libraryDocuments(f)
        unsortedCount = researchStore.unsortedCount()
        const present = rows.map(function(r) { return r.url.toString() })
        selection = selection.filter(function(u) { return present.indexOf(u) >= 0 })
        collectionRows = researchStore.collections()
        tagRows = researchStore.tags()
        noteRows = showingNotes ? researchStore.notes(!!filter.notesTrash) : []
    }
    function setFilter(next) { filter = next; selection = []; selectionAnchor = -1; filterEdited(next); refresh() }
    function selected(key, value) { return key === "all" ? Object.keys(filter).length === 0 : filter[key] === value }
    onQueryChanged: refreshTimer.restart()
    onSortChanged: refresh()
    Component.onCompleted: refresh()
    Timer { id: refreshTimer; interval: 120; onTriggered: root.refresh() }
    Connections {
        target: researchStore
        function onDocumentsChanged() { root.refresh() }
        function onRecentDocumentsChanged() { root.refresh() }
        function onNotesChanged() { if (root.showingNotes) root.refresh() }
    }
    Dialog {
        id: collectionDialog
        objectName: "collectionDialog"
        property string collectionId: ""
        property string parentId: ""
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: 360
        modal: true
        title: collectionId.length ? "Rename collection" : "New collection"
        standardButtons: Dialog.Save | Dialog.Cancel
        // Papers to put in a new collection right away (New Collection… on a selection).
        property var papers: []
        function begin(id, name, parent) { beginFor(id, name, parent, []) }
        function beginFor(id, name, parent, urls) { collectionId = id; parentId = parent || ""; papers = urls || []; collectionName.text = name || ""; open(); collectionName.forceActiveFocus() }
        TextField { id: collectionName; objectName: "collectionName"; width: parent.width; placeholderText: "Collection name"; onAccepted: collectionDialog.accept() }
        onAccepted: {
            if (collectionId.length) researchStore.renameCollection(collectionId, collectionName.text)
            else {
                const id = researchStore.createCollection(collectionName.text, parentId)
                if (id && papers.length) researchStore.setDocumentsCollection(papers, id, true)
            }
        }
    }
    Menu {
        id: collectionMenu
        property var row: ({})
        MenuItem { text: "New Sub-collection…"; onTriggered: collectionDialog.begin("", "", collectionMenu.row.id) }
        MenuItem { text: "Rename…"; onTriggered: collectionDialog.begin(collectionMenu.row.id, collectionMenu.row.name) }
        MenuItem {
            text: "Delete Collection"
            palette.windowText: Theme.danger
            onTriggered: { researchStore.deleteCollection(collectionMenu.row.id); if (root.filter.collection === collectionMenu.row.id) root.setFilter({}) }
        }
    }
    Menu {
        id: noteMenu
        objectName: "libraryNoteMenu"
        property string noteId: ""
        MenuItem { text: "Open"; onTriggered: root.noteChosen(noteMenu.noteId) }
        MenuItem { text: "Copy Markdown"; onTriggered: researchStore.copyText(researchStore.note(noteMenu.noteId).body || "") }
        MenuSeparator {}
        MenuItem { text: "Move Note to Trash"; palette.windowText: Theme.danger; onTriggered: researchStore.deleteNote(noteMenu.noteId) }
    }
    // Several selected papers: what applies to all of them.
    Menu {
        id: batchMenu
        objectName: "libraryBatchMenu"
        property var urls: []
        property var rows: []
        onAboutToShow: rows = researchStore.collections()
        MenuItem { enabled: false; text: batchMenu.urls.length + " papers" }
        MenuSeparator {}
        Menu {
            id: batchCollections
            objectName: "libraryBatchCollections"
            title: "Add to Collection"
            Instantiator {
                model: batchMenu.rows
                delegate: MenuItem {
                    required property var modelData
                    text: "    ".repeat(modelData.depth) + modelData.name
                    onTriggered: researchStore.setDocumentsCollection(batchMenu.urls, modelData.id, true)
                }
                onObjectAdded: function(index, object) { batchCollections.insertItem(index, object) }
                onObjectRemoved: function(index, object) { batchCollections.removeItem(object) }
            }
            MenuItem { text: "New Collection…"; onTriggered: collectionDialog.beginFor("", "", "", batchMenu.urls) }
        }
        MenuItem {
            visible: !!root.filter.collection; height: visible ? implicitHeight : 0
            text: "Remove from This Collection"
            onTriggered: researchStore.setDocumentsCollection(batchMenu.urls, root.filter.collection, false)
        }
        MenuSeparator {}
        MenuItem { text: "Mark as Read"; onTriggered: batchMenu.urls.forEach(function(u) { researchStore.setReadingState(u, "read") }) }
        MenuItem { text: "Add to Favorites"; onTriggered: batchMenu.urls.forEach(function(u) { researchStore.setFavorite(u, true) }) }
        MenuSeparator {}
        MenuItem { text: "Copy BibTeX"; onTriggered: { researchStore.copyText(researchStore.bibtex(batchMenu.urls)); researchStore.notify("BibTeX copied.") } }
    }
    PaperMenu {
        id: paperMenu
        collectionId: root.filter.collection || ""
        onOpenRequested: function(source, position) { root.documentChosen(source, position) }
    }
    RowLayout {
        anchors.fill: parent
        spacing: 0
        // Sidebar: built-in views, collections, tags.
        Rectangle {
            Layout.preferredWidth: 210; Layout.fillHeight: true
            color: Theme.sidebar
            ListView {
                id: sidebar
                anchors.fill: parent; anchors.margins: 8
                clip: true
                spacing: 1
                model: [{key: "all", label: "All Papers"}, {key: "unsorted", value: true, label: "Unsorted", count: root.unsortedCount}, {key: "favorite", value: true, label: "Favorites"},
                        {key: "state", value: "unread", label: "Unread"}, {key: "state", value: "reading", label: "Reading"},
                        {key: "state", value: "read", label: "Read"}, {header: "Notes"}, {key: "notes", value: true, label: "All Notes"},
                        {key: "notesTrash", value: true, label: "Notes Trash"}, {header: "Collections", add: true}]
                    .concat(root.collectionRows.map(function(c) { return {key: "collection", value: c.id, label: c.name, depth: c.depth, count: c.count, row: c} }))
                    .concat(root.tagRows.length ? [{header: "Tags"}] : [])
                    .concat(root.tagRows.map(function(t) { return {key: "tag", value: t.id, label: "# " + t.name, count: t.count} }))
                delegate: Item {
                    id: entry
                    required property var modelData
                    width: sidebar.width
                    height: modelData.header ? 34 : 28
                    Label {
                        visible: !!entry.modelData.header
                        anchors.left: parent.left; anchors.leftMargin: 6; anchors.bottom: parent.bottom; anchors.bottomMargin: 4
                        text: entry.modelData.header || ""; font.pixelSize: Theme.fontCaption; font.weight: Font.DemiBold; color: Theme.textTertiary
                    }
                    IconButton {
                        visible: !!entry.modelData.add
                        anchors.right: parent.right; anchors.bottom: parent.bottom
                        objectName: "newCollectionButton"; icon.name: "add"; implicitWidth: 24; implicitHeight: 22
                        description: "New collection"; onClicked: collectionDialog.begin("", "")
                    }
                    ItemDelegate {
                        id: item
                        visible: !entry.modelData.header
                        objectName: "librarySidebar-" + entry.modelData.key + "-" + (entry.modelData.value === undefined ? "" : entry.modelData.value)
                        anchors.fill: parent
                        leftPadding: 8 + 14 * (entry.modelData.depth || 0)
                        highlighted: !entry.modelData.header && root.selected(entry.modelData.key, entry.modelData.value)
                        text: entry.modelData.label || ""
                        contentItem: Text {
                            leftPadding: 0; rightPadding: 28
                            text: item.text; font: item.font; elide: Text.ElideRight; textFormat: Text.PlainText
                            color: item.highlighted ? Theme.selectedText : Theme.text
                            verticalAlignment: Text.AlignVCenter
                        }
                        onClicked: {
                            const next = {}
                            if (entry.modelData.key !== "all") next[entry.modelData.key] = entry.modelData.value
                            root.setFilter(next)
                        }
                        Label {
                            anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
                            visible: entry.modelData.count !== undefined; text: entry.modelData.count || 0
                            font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
                        }
                        TapHandler {
                            acceptedButtons: Qt.RightButton
                            enabled: entry.modelData.key === "collection"
                            onTapped: { collectionMenu.row = entry.modelData.row; collectionMenu.popup() }
                        }
                        // Drop a paper here to add it to this collection.
                        DropArea {
                            anchors.fill: parent
                            enabled: entry.modelData.key === "collection"
                            keys: ["owelk/paper"]
                            onDropped: function(drop) { researchStore.setDocumentsCollection(drop.source.paperUrls, entry.modelData.value, true) }
                            Rectangle { anchors.fill: parent; color: "transparent"; border.color: Theme.accent; radius: Theme.radius; visible: parent.containsDrag }
                        }
                    }
                }
            }
        }
        Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true; color: Theme.separator }
        ColumnLayout {
            Layout.fillWidth: true; Layout.fillHeight: true
            Layout.margins: 12
            spacing: 8
            RowLayout {
                Layout.fillWidth: true
                visible: root.showingNotes
                Label { Layout.fillWidth: true; text: root.filter.notesTrash ? "Notes trash" : "Notes"; font.pixelSize: Theme.fontHeadline; font.weight: Font.DemiBold; color: Theme.text }
                IconButton { objectName: "libraryNewNote"; visible: !root.filter.notesTrash; icon.name: "note"; description: "New note"; onClicked: root.newNoteRequested() }
            }
            ListView {
                id: noteList
                objectName: "libraryNotes"
                visible: root.showingNotes
                Layout.fillWidth: true; Layout.fillHeight: true
                clip: true
                model: root.noteRows
                delegate: ItemDelegate {
                    id: noteItem
                    required property var modelData
                    objectName: "libraryNote-" + modelData.id
                    required property int index
                    width: noteList.width; height: Theme.rowHeightTall
                    separator: index < noteList.count - 1
                    onClicked: if (!root.filter.notesTrash) root.noteChosen(modelData.id)
                    TapHandler { acceptedButtons: Qt.RightButton; enabled: !root.filter.notesTrash; onTapped: { noteMenu.noteId = noteItem.modelData.id; noteMenu.popup() } }
                    contentItem: RowLayout {
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 2
                            Label { Layout.fillWidth: true; text: noteItem.modelData.title; elide: Text.ElideRight; textFormat: Text.PlainText; color: Theme.text }
                            Label { Layout.fillWidth: true; text: noteItem.modelData.snippet || " "; elide: Text.ElideRight; textFormat: Text.PlainText; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary }
                        }
                        IconButton {
                            visible: !!root.filter.notesTrash; objectName: "restoreNote-" + noteItem.modelData.id
                            icon.name: "restore"; description: "Restore note"; onClicked: researchStore.restoreNote(noteItem.modelData.id)
                        }
                        IconButton {
                            visible: !!root.filter.notesTrash; objectName: "purgeNote-" + noteItem.modelData.id
                            icon.name: "trash"; tint: Theme.danger; description: "Delete permanently"
                            onClicked: researchStore.purgeNote(noteItem.modelData.id)
                        }
                    }
                }
                Label { anchors.centerIn: parent; visible: noteList.count === 0; text: root.filter.notesTrash ? "Trash is empty." : "No notes yet."; color: Theme.textTertiary }
            }
            RowLayout {
                Layout.fillWidth: true
                visible: !root.showingNotes
                TextField {
                    objectName: "libraryQuery"
                    Layout.fillWidth: true
                    placeholderText: "Filter by title, author, year, DOI or file name"
                    onTextChanged: root.query = text
                }
                ComboBox {
                    objectName: "librarySort"
                    Layout.preferredWidth: 140
                    model: ["Last opened", "Last added", "Title", "Year"]
                    readonly property var keys: ["opened", "added", "title", "year"]
                    onActivated: function(index) { root.sort = keys[index] }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                visible: !root.showingNotes
                Label { objectName: "libraryCount"; Layout.fillWidth: true; text: root.rows.length + (root.rows.length === 1 ? " paper" : " papers"); font.pixelSize: Theme.fontSmall; color: Theme.textTertiary }
                IconButton {
                    objectName: "exportBibtex"
                    icon.name: "export"
                    enabled: root.rows.length > 0
                    description: "Export BibTeX… · the papers listed here"
                    onClicked: bibtexDialog.open()
                }
            }
            Native.FileDialog {
                id: bibtexDialog
                title: "Export BibTeX"
                fileMode: Native.FileDialog.SaveFile
                defaultSuffix: "bib"
                nameFilters: ["BibTeX (*.bib)"]
                onAccepted: researchStore.exportBibTeX(root.rows.map(function(r) { return r.url.toString() }), researchStore.localPath(selectedFile))
            }
            ListView {
                id: papers
                objectName: "libraryList"
                visible: !root.showingNotes
                Layout.fillWidth: true; Layout.fillHeight: true
                clip: true
                model: root.rows
                ScrollBar.vertical: ScrollBar {}
                delegate: ItemDelegate {
                    id: paper
                    required property var modelData
                    readonly property url paperUrl: modelData.url
                    // Dragging a selected paper drags the whole selection.
                    readonly property var paperUrls: root.papersFor(modelData)
                    objectName: "libraryPaper-" + modelData.id
                    required property int index
                    width: papers.width
                    height: Theme.rowHeightTall
                    separator: index < papers.count - 1
                    highlighted: root.isSelected(modelData.url)
                    onClicked: root.rowClicked(index)
                    // Unsorted papers get up to two places they probably belong, from similar papers.
                    property var suggestions: []
                    property int suggestionRequest: -1
                    Component.onCompleted: if (root.filter.unsorted) suggestionRequest = researchStore.suggestCollections(modelData.url)
                    Connections {
                        target: researchStore
                        enabled: paper.suggestionRequest >= 0
                        function onCollectionsSuggested(request, source, list) { if (request === paper.suggestionRequest) paper.suggestions = list }
                    }
                    ToolTip.visible: hovered; ToolTip.delay: 600
                    ToolTip.text: modelData.fileName + (modelData.duplicate ? "\nSame file as another library entry" : "") + (modelData.excluded ? "\nExcluded from text search" : "")
                    Drag.active: dragHandler.active
                    Drag.keys: ["owelk/paper"]
                    Drag.source: paper
                    Drag.hotSpot: Qt.point(20, 20)
                    DragHandler { id: dragHandler; target: null; onActiveChanged: if (!active) paper.Drag.drop() }
                    TapHandler {
                        acceptedButtons: Qt.RightButton
                        onTapped: {
                            if (paper.paperUrls.length > 1) { batchMenu.urls = paper.paperUrls; batchMenu.popup() }
                            else { root.selection = []; paperMenu.show(paper.modelData) }
                        }
                    }
                    contentItem: RowLayout {
                        spacing: 10
                        Rectangle {
                            // Reading state: hollow unread, half reading, full read.
                            Layout.preferredWidth: 8; Layout.preferredHeight: 8; radius: 4
                            color: paper.modelData.readingState === "read" ? Theme.textTertiary : paper.modelData.readingState === "reading" ? Theme.accent : "transparent"
                            border.color: paper.modelData.readingState === "read" ? Theme.textTertiary : Theme.accent
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Label { Layout.fillWidth: true; text: paper.modelData.name; elide: Text.ElideRight; textFormat: Text.PlainText; color: Theme.text }
                            Label {
                                Layout.fillWidth: true; elide: Text.ElideRight; textFormat: Text.PlainText; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
                                text: [paper.modelData.authors, paper.modelData.year, paper.modelData.tags ? "# " + paper.modelData.tags : ""].filter(function(s) { return s && s.length }).join("  ·  ")
                            }
                        }
                        Label { visible: paper.modelData.duplicate; text: "duplicate"; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary }
                        Repeater {
                            model: paper.suggestions
                            delegate: Chip {
                                required property var modelData
                                objectName: "suggestion-" + modelData.name
                                text: "+ " + modelData.name
                                Layout.maximumWidth: 140
                                ToolTip.text: "Add to " + modelData.name + " · similar papers are there"
                                onClicked: { const url = paper.modelData.url, id = modelData.id; Qt.callLater(function() { researchStore.setDocumentCollection(url, id, true) }) }
                            }
                        }
                        // The star shows on favorites; on hover it is the toggle.
                        IconButton {
                            objectName: "libraryFavorite-" + paper.modelData.id
                            icon.name: "star"
                            opacity: paper.modelData.favorite || paper.hovered || hovered ? 1 : 0
                            tint: paper.modelData.favorite ? Theme.accent : Theme.textDisabled
                            description: paper.modelData.favorite ? "Remove from Favorites" : "Add to Favorites"
                            onClicked: researchStore.setFavorite(paper.modelData.url, !paper.modelData.favorite)
                        }
                    }
                }
                Label {
                    anchors.centerIn: parent
                    visible: papers.count === 0
                    text: root.query.length || Object.keys(root.filter).length ? "No papers match." : "Papers you open appear here."
                    color: Theme.textTertiary
                }
            }
        }
    }
}
