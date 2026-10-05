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
        collectionRows = researchStore.collections()
        tagRows = researchStore.tags()
        noteRows = showingNotes ? researchStore.notes(!!filter.notesTrash) : []
    }
    function setFilter(next) { filter = next; filterEdited(next); refresh() }
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
    PaperDetailsDialog { id: details }
    Dialog {
        id: tagDialog
        objectName: "libraryTagDialog"
        property url source: ""
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: 380
        modal: true
        title: "Tags"
        standardButtons: Dialog.Save | Dialog.Cancel
        function begin(url) { source = url; tagField.text = researchStore.documentOrganization(url).tags.join(", "); open(); tagField.forceActiveFocus() }
        ColumnLayout {
            width: parent.width
            TextField { id: tagField; objectName: "libraryTagField"; Layout.fillWidth: true; placeholderText: "Comma-separated, e.g. SLAM, to read"; onAccepted: tagDialog.accept() }
            Label { text: "Existing: " + root.tagRows.map(function(t) { return t.name }).join(", "); visible: root.tagRows.length > 0; wrapMode: Text.Wrap; Layout.fillWidth: true; font.pixelSize: 12; color: Theme.textTertiary }
        }
        onAccepted: researchStore.setDocumentTags(source, tagField.text.split(",").map(function(t) { return t.trim() }).filter(function(t) { return t.length }))
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
        function begin(id, name, parent) { collectionId = id; parentId = parent || ""; collectionName.text = name || ""; open(); collectionName.forceActiveFocus() }
        TextField { id: collectionName; objectName: "collectionName"; width: parent.width; placeholderText: "Collection name"; onAccepted: collectionDialog.accept() }
        onAccepted: {
            if (collectionId.length) researchStore.renameCollection(collectionId, collectionName.text)
            else researchStore.createCollection(collectionName.text, parentId)
        }
    }
    Menu {
        id: collectionMenu
        property var row: ({})
        MenuItem { text: "New Sub-collection…"; onTriggered: collectionDialog.begin("", "", collectionMenu.row.id) }
        MenuItem { text: "Rename…"; onTriggered: collectionDialog.begin(collectionMenu.row.id, collectionMenu.row.name) }
        MenuItem {
            text: "Delete Collection"
            palette.text: Theme.danger; palette.windowText: Theme.danger; palette.highlightedText: Theme.danger
            onTriggered: { researchStore.deleteCollection(collectionMenu.row.id); if (root.filter.collection === collectionMenu.row.id) root.setFilter({}) }
        }
    }
    Menu {
        id: paperMenu
        property var row: ({})
        MenuItem { text: "Open"; onTriggered: root.documentChosen(paperMenu.row.url, paperMenu.row.position) }
        MenuItem { text: "Paper Details…"; onTriggered: details.begin(paperMenu.row.url) }
        MenuItem { objectName: "libraryTagsOption"; text: "Tags…"; onTriggered: tagDialog.begin(paperMenu.row.url) }
        Menu {
            id: addToCollection
            title: "Collections"
            Instantiator {
                model: root.collectionRows
                delegate: MenuItem {
                    required property var modelData
                    checkable: true
                    checked: paperMenu.opened && researchStore.documentOrganization(paperMenu.row.url).collections.indexOf(modelData.id) >= 0
                    text: "    ".repeat(modelData.depth) + modelData.name
                    onTriggered: researchStore.setDocumentCollection(paperMenu.row.url, modelData.id, checked)
                }
                onObjectAdded: function(index, object) { addToCollection.insertItem(index, object) }
                onObjectRemoved: function(index, object) { addToCollection.removeItem(object) }
            }
            MenuItem { text: "New Collection…"; onTriggered: collectionDialog.begin("", "") }
        }
        MenuSeparator {}
        MenuItem { text: paperMenu.row.readingState === "read" ? "Mark as Unread" : "Mark as Read"; onTriggered: researchStore.setReadingState(paperMenu.row.url, paperMenu.row.readingState === "read" ? "unread" : "read") }
        MenuItem { text: paperMenu.row.favorite ? "Remove from Favorites" : "Add to Favorites"; onTriggered: researchStore.setFavorite(paperMenu.row.url, !paperMenu.row.favorite) }
        MenuItem { text: paperMenu.row.excluded ? "Include in Text Search" : "Exclude from Text Search"; onTriggered: researchStore.setExcludedFromIndex(paperMenu.row.url, !paperMenu.row.excluded) }
        MenuItem { text: "Locate Original PDF…"; onTriggered: researchStore.requestRelink(paperMenu.row.url) }
        MenuItem { objectName: "copyBibtex"; text: "Copy BibTeX"; onTriggered: { researchStore.copyText(researchStore.bibtex([paperMenu.row.url.toString()])); researchStore.notify("BibTeX copied.") } }
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
                model: [{key: "all", label: "All Papers"}, {key: "favorite", value: true, label: "Favorites"},
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
                        text: entry.modelData.header || ""; font.pixelSize: 11; font.bold: true; color: Theme.textTertiary
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
                        font.pixelSize: 13
                        // Selection uses the accent surface; the label stays dark and readable.
                        background: Rectangle {
                            radius: Theme.radius
                            color: item.highlighted ? Theme.selected : item.hovered ? Theme.hover : "transparent"
                        }
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
                            font.pixelSize: 11; color: Theme.textTertiary
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
                            onDropped: function(drop) { researchStore.setDocumentCollection(drop.source.paperUrl, entry.modelData.value, true) }
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
                Label { Layout.fillWidth: true; text: root.filter.notesTrash ? "Notes trash" : "Notes"; font.pixelSize: 15; font.weight: Font.DemiBold; color: Theme.text }
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
                    width: noteList.width; height: 50
                    onClicked: if (!root.filter.notesTrash) root.noteChosen(modelData.id)
                    contentItem: RowLayout {
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 2
                            Label { Layout.fillWidth: true; text: noteItem.modelData.title; elide: Text.ElideRight; textFormat: Text.PlainText; color: Theme.text; font.pixelSize: 13 }
                            Label { Layout.fillWidth: true; text: noteItem.modelData.snippet || " "; elide: Text.ElideRight; textFormat: Text.PlainText; font.pixelSize: 11; color: Theme.textTertiary }
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
                Label { objectName: "libraryCount"; Layout.fillWidth: true; text: root.rows.length + (root.rows.length === 1 ? " paper" : " papers"); font.pixelSize: 12; color: Theme.textTertiary }
                ToolButton {
                    objectName: "exportBibtex"
                    text: "Export BibTeX…"; font.pixelSize: 12
                    enabled: root.rows.length > 0
                    ToolTip.visible: hovered; ToolTip.delay: 450; ToolTip.text: "Save the papers listed here as a .bib file"
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
                    objectName: "libraryPaper-" + modelData.id
                    width: papers.width
                    height: 50
                    onClicked: root.documentChosen(modelData.url, modelData.position)
                    ToolTip.visible: hovered; ToolTip.delay: 600
                    ToolTip.text: modelData.fileName + (modelData.duplicate ? "\nSame file as another library entry" : "") + (modelData.excluded ? "\nExcluded from text search" : "")
                    Drag.active: dragHandler.active
                    Drag.keys: ["owelk/paper"]
                    Drag.source: paper
                    Drag.hotSpot: Qt.point(20, 20)
                    DragHandler { id: dragHandler; target: null; onActiveChanged: if (!active) paper.Drag.drop() }
                    TapHandler { acceptedButtons: Qt.RightButton; onTapped: { paperMenu.row = paper.modelData; paperMenu.popup() } }
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
                            Label { Layout.fillWidth: true; text: paper.modelData.name; elide: Text.ElideRight; textFormat: Text.PlainText; color: Theme.text; font.pixelSize: 13 }
                            Label {
                                Layout.fillWidth: true; elide: Text.ElideRight; textFormat: Text.PlainText; font.pixelSize: 11; color: Theme.textTertiary
                                text: [paper.modelData.authors, paper.modelData.year, paper.modelData.tags ? "# " + paper.modelData.tags : ""].filter(function(s) { return s && s.length }).join("  ·  ")
                            }
                        }
                        Label { visible: paper.modelData.duplicate; text: "duplicate"; font.pixelSize: 11; color: Theme.textTertiary }
                        IconButton {
                            objectName: "libraryFavorite-" + paper.modelData.id
                            icon.name: "star"; implicitWidth: 24
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
