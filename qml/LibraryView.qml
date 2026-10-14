import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui
import QtQuick.Dialogs as Native

// The Library tab: Papers (filtered by reading state, favorites, collection or tag), Notes, and the
// Trash (papers, notes and AI conversations together). Papers are referenced, never copied:
// collections and tags only group them.
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
    // Select mode (the Select button): a click picks a paper instead of opening it.
    property bool selecting: false
    function setSelecting(on) { selecting = on; if (!on) { selection = []; selectionAnchor = -1 } }
    readonly property bool allSelected: rows.length > 0 && selection.length === rows.length
    function selectAll(on) { selection = on ? rows.map(function(r) { return r.url.toString() }) : []; selectionAnchor = -1 }
    function isSelected(url) { return selection.indexOf(url.toString()) >= 0 }
    function rowClicked(index) {
        const row = rows[index], url = row.url.toString(), mods = researchStore.keyboardModifiers()
        if (mods & Qt.ShiftModifier && selectionAnchor >= 0) {
            const a = Math.min(selectionAnchor, index), b = Math.max(selectionAnchor, index)
            selection = rows.slice(a, b + 1).map(function(r) { return r.url.toString() })
        } else if (selecting || mods & Qt.ControlModifier) {
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
    // Which list: papers (no view in the filter), notes or the Trash.
    readonly property string view: filter.view === "notes" || filter.view === "trash" ? filter.view : "papers"
    readonly property bool showingNotes: view === "notes"
    readonly property bool showingTrash: view === "trash"
    function setView(next) { if (next !== "papers") setSelecting(false); setFilter(next === "papers" ? {} : {view: next}) }
    Shortcut { sequence: "Escape"; enabled: root.selecting && root.visible; onActivated: root.setSelecting(false) }
    // Delete or Backspace moves the chosen papers to the Trash (a text field being edited keeps its keys).
    Shortcut {
        sequences: [StandardKey.Delete, "Backspace"]
        enabled: root.selecting && root.visible && root.selection.length > 0
                 && !(root.Window.activeFocusItem && root.Window.activeFocusItem.cursorPosition !== undefined)
        onActivated: root.deleteSelection()
    }
    function deleteSelection() { const list = selection; setSelecting(false); Qt.callLater(function() { researchStore.deletePapers(list) }) }
    // What follows the pointer while papers are dragged onto a collection, the AI panel or a panel's shelf.
    Rectangle {
        id: dragGhost
        objectName: "libraryDragGhost"
        parent: Overlay.overlay
        visible: Drag.active
        z: 1000
        property var paperUrls: []
        property string title: ""
        width: Math.min(260, ghostLabel.implicitWidth + 20); height: Theme.controlHeight
        radius: Theme.radius
        color: Theme.raised
        border.width: 1; border.color: Theme.overlayBorder
        Drag.keys: ["owelk/paper"]
        Drag.source: dragGhost
        Drag.hotSpot: Qt.point(10, height / 2)
        Label {
            id: ghostLabel
            anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
            verticalAlignment: Text.AlignVCenter
            text: dragGhost.paperUrls.length > 1 ? dragGhost.paperUrls.length + qsTr(" papers") : dragGhost.title
            elide: Text.ElideRight; textFormat: Text.PlainText
            font.pixelSize: Theme.fontSmall; color: Theme.text
        }
        function follow(point) { const p = parent.mapFromItem(null, point.x, point.y); x = p.x - 10; y = p.y - height / 2 }
    }
    property int trashCount: 0
    property var trashRows: []
    readonly property var kindNames: ({paper: qsTr("Paper"), note: qsTr("Note"), ai: qsTr("AI conversation")})
    // Later, so a row is not removed while its own button handles the click.
    function restore(items) { Qt.callLater(function() { researchStore.restoreFromTrash(items); root.refresh() }) }
    // Deleting for good, after a word when notes link to what goes (their links stop opening).
    function deleteForGood(items) {
        const linked = researchStore.notesLinkingTo(items)
        if (!linked) { Qt.callLater(function() { researchStore.deleteForGood(items); root.refresh() }); return }
        purgeConfirm.items = items
        purgeConfirm.linked = linked
        purgeConfirm.open()
    }
    signal noteChosen(string id)
    signal newNoteRequested()
    // collection: "" for the whole library.
    signal askLibraryRequested(string collection, string collectionName)
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
        noteRows = showingNotes ? researchStore.notes(false) : []
        trashCount = researchStore.trashCount()
        trashRows = showingTrash ? researchStore.trash() : []
    }
    Loader { id: organizer; active: false; sourceComponent: OrganizePapersDialog {} }
    Loader { id: comparer; active: false; sourceComponent: ComparePapersDialog { onNoteCreated: function(id) { root.noteChosen(id) } } }
    function compareWithAi(urls) {
        comparer.active = true
        comparer.item.begin(urls)
    }
    function organizeWithAi(urls) {
        organizer.active = true
        organizer.item.begin(urls, root.filter.collection || "")
    }
    function setFilter(next) { filter = next; selection = []; selectionAnchor = -1; filterEdited(next); refresh() }
    function selected(key, value) { return key === "all" ? Object.keys(filter).length === 0 : filter[key] === value }
    onQueryChanged: refreshTimer.restart()
    onFilterChanged: if (filter.collection) researchStore.markOpened("collection", filter.collection)
    onSortChanged: refresh()
    Component.onCompleted: refresh()
    Timer { id: refreshTimer; interval: 120; onTriggered: root.refresh() }
    Connections {
        target: researchStore
        function onDocumentsChanged() { root.refresh() }
        function onRecentDocumentsChanged() { root.refresh() }
        function onNotesChanged() { root.refresh() }
        function onAiThreadsChanged() { if (root.showingTrash) root.refresh(); else root.trashCount = researchStore.trashCount() }
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
        title: collectionId.length ? qsTr("Rename collection") : qsTr("New collection")
        standardButtons: Dialog.Save | Dialog.Cancel
        // Papers to put in a new collection right away (New Collection… on a selection).
        property var papers: []
        function begin(collection, name, parentCollection) { beginFor(collection, name, parentCollection, []) }
        function beginFor(collection, name, parentCollection, urls) {
            collectionDialog.collectionId = collection || ""
            collectionDialog.parentId = parentCollection || ""
            collectionDialog.papers = urls || []
            collectionName.text = name || ""
            open()
            collectionName.forceActiveFocus()
        }
        TextField { id: collectionName; objectName: "collectionName"; width: parent.width; placeholderText: qsTr("Collection name"); onAccepted: collectionDialog.accept() }
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
        MenuItem { text: qsTr("New Sub-collection…"); onTriggered: collectionDialog.begin("", "", collectionMenu.row.id) }
        MenuItem { text: qsTr("Rename…"); onTriggered: collectionDialog.begin(collectionMenu.row.id, collectionMenu.row.name) }
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
        MenuItem { text: qsTr("Open"); onTriggered: root.noteChosen(noteMenu.noteId) }
        MenuItem { text: qsTr("Copy Markdown"); onTriggered: researchStore.copyText(researchStore.note(noteMenu.noteId).body || "") }
        MenuSeparator {}
        MenuItem { text: qsTr("Move Note to Trash"); palette.windowText: Theme.danger; onTriggered: researchStore.deleteNote(noteMenu.noteId) }
    }
    // Several selected papers: what applies to all of them.
    Menu {
        id: batchMenu
        objectName: "libraryBatchMenu"
        property var urls: []
        property var rows: []
        onAboutToShow: rows = researchStore.collections()
        MenuItem { enabled: false; text: batchMenu.urls.length + (batchMenu.urls.length === 1 ? qsTr(" paper") : qsTr(" papers")) }
        MenuSeparator {}
        Menu {
            id: batchCollections
            objectName: "libraryBatchCollections"
            title: qsTr("Add to Collection")
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
            MenuItem { text: qsTr("New Collection…"); onTriggered: collectionDialog.beginFor("", "", "", batchMenu.urls) }
        }
        MenuItem {
            visible: !!root.filter.collection; height: visible ? implicitHeight : 0
            text: qsTr("Remove from This Collection")
            onTriggered: researchStore.setDocumentsCollection(batchMenu.urls, root.filter.collection, false)
        }
        MenuItem { objectName: "batchCompare"; text: qsTr("Compare with AI…"); onTriggered: root.compareWithAi(batchMenu.urls) }
        MenuItem { objectName: "batchRenameToTitles"; text: qsTr("Rename Files from Details"); onTriggered: researchStore.renamePapersToTitles(batchMenu.urls) }
        MenuItem { objectName: "batchOrganize"; text: qsTr("Organize into Collections with AI…"); onTriggered: root.organizeWithAi(batchMenu.urls) }
        MenuSeparator {}
        MenuItem { text: qsTr("Mark as Read"); onTriggered: batchMenu.urls.forEach(function(u) { researchStore.setReadingState(u, "read") }) }
        MenuItem { text: qsTr("Add to Favorites"); onTriggered: batchMenu.urls.forEach(function(u) { researchStore.setFavorite(u, true) }) }
        MenuSeparator {}
        MenuItem { text: qsTr("Copy BibTeX"); onTriggered: { researchStore.copyText(researchStore.bibtex(batchMenu.urls)); researchStore.notify(qsTr("BibTeX copied.")) } }
        MenuSeparator {}
        MenuItem {
            objectName: "batchDeletePapers"; text: "Delete Papers"; palette.windowText: Theme.danger
            onTriggered: { const list = batchMenu.urls; root.setSelecting(false); Qt.callLater(function() { researchStore.deletePapers(list) }) }
        }
    }
    // A whole folder: every PDF under it, optionally as a collection tree.
    Native.FolderDialog {
        id: folderDialog
        title: qsTr("Add a folder of PDFs")
        onAccepted: { importOptions.folder = selectedFolder; importOptions.open() }
    }
    Dialog {
        id: importOptions
        objectName: "importFolderDialog"
        property url folder
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: 420
        modal: true
        title: qsTr("Add \u201c") + researchStore.fileName(folder) + qsTr("\u201d to the Library")
        standardButtons: Dialog.Ok | Dialog.Cancel
        Column {
            width: parent.width
            spacing: 8
            CheckBox {
                id: asCollections
                objectName: "importAsCollections"
                width: parent.width
                checked: true
                text: qsTr("Make a collection of the folder, with its subfolders as sub-collections")
            }
            Label {
                width: parent.width; wrapMode: Text.Wrap
                font.pixelSize: Theme.fontSmall; color: Theme.textTertiary
                text: (root.filter.collection ? qsTr("Inside the collection shown. ") : "") + qsTr("The PDFs stay where they are; titles and text are read in the background. Hidden folders are skipped.")
            }
        }
        onAccepted: researchStore.importFolder(folder, root.filter.collection || "", asCollections.checked)
    }
    // PDFs chosen or dropped here join the Library, and the collection being shown.
    Native.FileDialog {
        id: addDialog
        title: root.filter.collection ? qsTr("Add PDFs to this collection") : qsTr("Add PDFs to the Library")
        fileMode: Native.FileDialog.OpenFiles
        nameFilters: ["PDF documents (*.pdf)"]
        onAccepted: researchStore.addDocuments(selectedFiles, root.filter.collection || "")
    }
    PaperMenu {
        id: paperMenu
        collectionId: root.filter.collection || ""
        onOpenRequested: function(source, position) { root.documentChosen(source, position) }
    }
    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        // The three lists, in the same small switch as the panels' views.
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.barHeight + 8
            color: Theme.sidebar
            TabBar {
                objectName: "libraryViews"
                anchors.left: parent.left; anchors.leftMargin: 8; anchors.verticalCenter: parent.verticalCenter
                width: Math.min(parent.width - 16, 320)
                currentIndex: ["papers", "notes", "trash"].indexOf(root.view)
                TabButton { objectName: "libraryPapersTab"; text: qsTr("Papers"); onClicked: root.setView("papers") }
                TabButton { objectName: "libraryNotesTab"; text: qsTr("Notes"); onClicked: root.setView("notes") }
                TabButton { objectName: "libraryTrashTab"; text: root.trashCount ? qsTr("Trash ") + root.trashCount : qsTr("Trash"); onClicked: root.setView("trash") }
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.separator }
        }
        RowLayout {
            Layout.fillWidth: true; Layout.fillHeight: true
            spacing: 0
            // Sidebar for papers: built-in views, collections, tags.
            Rectangle {
                visible: !root.showingNotes && !root.showingTrash
                Layout.preferredWidth: 210; Layout.fillHeight: true
                color: Theme.sidebar
                ListView {
                    id: sidebar
                    anchors.fill: parent; anchors.margins: 8
                    clip: true
                    spacing: 1
                    model: [{key: "all", label: qsTr("All Papers")}, {key: "unsorted", value: true, label: qsTr("Unsorted"), count: root.unsortedCount}, {key: "favorite", value: true, label: qsTr("Favorites")},
                            {key: "state", value: "unread", label: qsTr("Unread")}, {key: "state", value: "reading", label: qsTr("Reading")},
                            {key: "state", value: "read", label: qsTr("Read")}, {header: qsTr("Collections"), add: true}]
                        .concat(root.collectionRows.map(function(c) { return {key: "collection", value: c.id, label: c.name, depth: c.depth, count: c.count, row: c} }))
                        .concat(root.tagRows.length ? [{header: qsTr("Tags")}] : [])
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
                            description: qsTr("New collection"); onClicked: collectionDialog.begin("", "")
                        }
                        ItemDelegate {
                            id: item
                            visible: !entry.modelData.header
                            objectName: "librarySidebar-" + entry.modelData.key + "-" + (entry.modelData.value === undefined ? "" : entry.modelData.value)
                            anchors.fill: parent
                            leftPadding: 8 + 14 * (entry.modelData.depth || 0)
                            highlighted: !entry.modelData.header && root.selected(entry.modelData.key, entry.modelData.value)
                            text: entry.modelData.label || ""
                            contentItem: Label {
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
            Rectangle { visible: !root.showingNotes && !root.showingTrash; Layout.preferredWidth: 1; Layout.fillHeight: true; color: Theme.separator }
            ColumnLayout {
                Layout.fillWidth: true; Layout.fillHeight: true
                Layout.margins: 12
                spacing: 8
                // The Trash: papers, notes and AI conversations; restore, delete for good, or empty it.
                RowLayout {
                    Layout.fillWidth: true
                    visible: root.showingTrash
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 2
                        Label { text: qsTr("Trash"); font.pixelSize: Theme.fontHeadline; font.weight: Font.DemiBold; color: Theme.text }
                        Label {
                            Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: Theme.fontSmall; color: Theme.textTertiary
                            text: (researchStore.trashDays() > 0 ? qsTr("Papers, notes and AI conversations are deleted for good after ") + researchStore.trashDays() + qsTr(" days")
                                                                  : qsTr("Papers, notes and AI conversations stay until you empty the Trash"))
                                + qsTr(" (Settings › Data). A paper deleted for good loses its annotations; a PDF Owelk keeps goes to the system Trash.")
                        }
                    }
                    Button {
                        objectName: "emptyTrash"; text: qsTr("Empty Trash"); enabled: root.trashRows.length > 0
                        onClicked: {
                            emptyTrashConfirm.linked = researchStore.notesLinkingTo(root.trashRows)
                            emptyTrashConfirm.open()
                        }
                    }
                }
                ListView {
                    id: trashList
                    objectName: "libraryTrash"
                    visible: root.showingTrash
                    Layout.fillWidth: true; Layout.fillHeight: true
                    clip: true
                    model: root.trashRows
                    ScrollBar.vertical: ScrollBar {}
                    delegate: ItemDelegate {
                        id: trashItem
                        required property var modelData
                        required property int index
                        objectName: "trashed-" + modelData.kind + "-" + modelData.id
                        width: trashList.width; height: Theme.rowHeightTall
                        separator: index < trashList.count - 1
                        contentItem: RowLayout {
                            spacing: 10
                            Icon { name: ({paper: "document", note: "note", ai: "ai"})[trashItem.modelData.kind]; size: Theme.fontBody; color: Theme.textTertiary }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 2
                                Label { Layout.fillWidth: true; text: trashItem.modelData.title; elide: Text.ElideRight; textFormat: Text.PlainText; color: Theme.text }
                                Label {
                                    Layout.fillWidth: true; elide: Text.ElideRight; textFormat: Text.PlainText; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
                                    text: [root.kindNames[trashItem.modelData.kind], trashItem.modelData.kind === "ai" ? "" : trashItem.modelData.detail,
                                           trashItem.modelData.daysLeft >= 0 ? qsTr("deleted in ") + trashItem.modelData.daysLeft + (trashItem.modelData.daysLeft === 1 ? qsTr(" day") : qsTr(" days")) : ""]
                                          .filter(function(t) { return t && t.length }).join(" · ")
                                }
                            }
                            IconButton {
                                objectName: "restore-" + trashItem.modelData.kind + "-" + trashItem.modelData.id
                                icon.name: "restore"; description: qsTr("Restore")
                                onClicked: root.restore([trashItem.modelData])
                            }
                            IconButton {
                                objectName: "purge-" + trashItem.modelData.kind + "-" + trashItem.modelData.id
                                icon.name: "trash"; tint: Theme.danger; description: "Delete for good"
                                onClicked: root.deleteForGood([trashItem.modelData])
                            }
                        }
                    }
                    Label { anchors.centerIn: parent; visible: trashList.count === 0; text: qsTr("Trash is empty."); color: Theme.textTertiary }
                }
                ConfirmDialog {
                    id: emptyTrashConfirm
                    objectName: "emptyTrashConfirm"
                    property int linked: 0
                    title: "Delete " + root.trashRows.length + (root.trashRows.length === 1 ? qsTr(" item") : qsTr(" items")) + qsTr(" for good?")
                    message: qsTr("Papers lose their annotations, and PDFs Owelk keeps go to the system Trash.")
                             + (linked ? " " + linked + (linked === 1 ? qsTr(" note links") : qsTr(" notes link")) + qsTr(" to them; those links will no longer open.") : "")
                    actionText: qsTr("Empty Trash")
                    onConfirmed: Qt.callLater(function() { researchStore.emptyTrash(); root.refresh() })
                }
                ConfirmDialog {
                    id: purgeConfirm
                    objectName: "purgeConfirm"
                    property var items: []
                    property int linked: 0
                    title: "Delete for good?"
                    message: linked + (linked === 1 ? qsTr(" note links") : qsTr(" notes link")) + qsTr(" to this; the link will no longer open")
                             + (items.length && items[0].kind === "ai" ? qsTr(" (it reads \u201cDeleted conversation\u201d).") : ".")
                    actionText: "Delete"
                    onConfirmed: { const chosen = items; Qt.callLater(function() { researchStore.deleteForGood(chosen); root.refresh() }) }
                }
                RowLayout {
                    Layout.fillWidth: true
                    visible: root.showingNotes
                    Label { Layout.fillWidth: true; text: qsTr("Notes"); font.pixelSize: Theme.fontHeadline; font.weight: Font.DemiBold; color: Theme.text }
                    IconButton { objectName: "libraryNewNote"; icon.name: "note"; description: qsTr("New note"); onClicked: root.newNoteRequested() }
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
                        onClicked: root.noteChosen(modelData.id)
                        TapHandler { acceptedButtons: Qt.RightButton; onTapped: { noteMenu.noteId = noteItem.modelData.id; noteMenu.popup() } }
                        contentItem: ColumnLayout {
                            spacing: 2
                            Label { Layout.fillWidth: true; text: noteItem.modelData.title; elide: Text.ElideRight; textFormat: Text.PlainText; color: Theme.text }
                            Label { Layout.fillWidth: true; text: noteItem.modelData.snippet || " "; elide: Text.ElideRight; textFormat: Text.PlainText; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary }
                        }
                    }
                    Label { anchors.centerIn: parent; visible: noteList.count === 0; text: qsTr("No notes yet."); color: Theme.textTertiary }
                }
                RowLayout {
                    Layout.fillWidth: true
                    visible: !root.showingNotes && !root.showingTrash
                    TextField {
                        objectName: "libraryQuery"
                        Layout.fillWidth: true
                        placeholderText: qsTr("Filter by title, author, year, DOI or file name")
                        onTextChanged: root.query = text
                    }
                    ComboBox {
                        objectName: "librarySort"
                        Layout.preferredWidth: 140
                        model: [qsTr("Last opened"), qsTr("Last added"), qsTr("Title"), qsTr("Year")]
                        readonly property var keys: ["opened", "added", "title", "year"]
                        onActivated: function(index) { root.sort = keys[index] }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    visible: !root.showingNotes && !root.showingTrash
                    Label {
                        objectName: "libraryCount"; Layout.fillWidth: true
                        text: root.selecting ? (root.selection.length ? root.selection.length + qsTr(" selected") : qsTr("Choose papers"))
                                             : root.rows.length + (root.rows.length === 1 ? qsTr(" paper") : qsTr(" papers"))
                        font.pixelSize: Theme.fontSmall; color: root.selecting && root.selection.length ? Theme.text : Theme.textTertiary
                    }
                    // Selecting: all or none, Delete for the chosen papers, and Done.
                    Button {
                        objectName: "librarySelectAll"
                        visible: root.selecting
                        flat: true; font.pixelSize: Theme.fontSmall; horizontalPadding: 8
                        implicitHeight: Theme.controlHeightSmall
                        text: root.allSelected ? qsTr("Deselect All") : qsTr("Select All")
                        onClicked: root.selectAll(!root.allSelected)
                    }
                    Button {
                        objectName: "libraryDeleteSelection"
                        visible: root.selecting
                        enabled: root.selection.length > 0
                        flat: true; font.pixelSize: Theme.fontSmall; horizontalPadding: 8
                        implicitHeight: Theme.controlHeightSmall
                        palette.buttonText: Theme.danger
                        text: qsTr("Delete")
                        onClicked: root.deleteSelection()
                    }
                    Button {
                        objectName: "librarySelectDone"
                        visible: root.selecting
                        flat: true; font.pixelSize: Theme.fontSmall; horizontalPadding: 8
                        implicitHeight: Theme.controlHeightSmall
                        text: qsTr("Done")
                        onClicked: root.setSelecting(false)
                    }
                    IconButton {
                        id: addButton
                        visible: !root.selecting
                        objectName: "libraryAddPdfs"
                        icon.name: "add"
                        description: qsTr("Add PDFs or a folder")
                        onClicked: addMenu.popup(addButton, 0, addButton.height)
                        Menu {
                            id: addMenu
                            objectName: "libraryAddMenu"
                            MenuItem { text: qsTr("Add PDFs…"); onTriggered: addDialog.open() }
                            MenuItem { objectName: "libraryAddFolder"; text: qsTr("Add Folder…"); onTriggered: folderDialog.open() }
                        }
                    }
                    IconButton {
                        objectName: "librarySelect"
                        visible: !root.selecting
                        enabled: root.rows.length > 0
                        icon.name: "check"
                        description: qsTr("Select papers")
                        onClicked: root.setSelecting(true)
                    }
                    // AI topic collections for the selection, or for the papers listed (Unsorted is the usual place).
                    IconButton {
                        visible: !root.selecting
                        objectName: "libraryOrganize"
                        icon.name: "organize"
                        enabled: (root.selection.length || root.rows.length) >= 2
                        description: qsTr("Organize with AI")
                        onClicked: root.organizeWithAi(root.selection.length ? root.selection : root.rows.map(function(r) { return r.url.toString() }))
                    }
                    // A question to the library (or the collection shown), answered from its papers with the pages linked.
                    IconButton {
                        visible: !root.selecting
                        objectName: "libraryAsk"
                        icon.name: "ai"
                        readonly property var shownCollection: root.filter.collection ? root.collectionRows.find(function(c) { return c.id === root.filter.collection }) || null : null
                        description: shownCollection ? qsTr("Ask this collection with AI") : qsTr("Ask your library with AI")
                        onClicked: root.askLibraryRequested(shownCollection ? shownCollection.id : "", shownCollection ? shownCollection.name : "")
                    }
                    IconButton {
                        visible: !root.selecting
                        objectName: "exportBibtex"
                        icon.name: "export"
                        enabled: root.rows.length > 0
                        description: qsTr("Export BibTeX")
                        onClicked: bibtexDialog.open()
                    }
                }
                Native.FileDialog {
                    id: bibtexDialog
                    title: qsTr("Export BibTeX")
                    fileMode: Native.FileDialog.SaveFile
                    defaultSuffix: "bib"
                    nameFilters: ["BibTeX (*.bib)"]
                    onAccepted: researchStore.exportBibTeX(root.rows.map(function(r) { return r.url.toString() }), researchStore.localPath(selectedFile))
                }
                ListView {
                    id: papers
                    objectName: "libraryList"
                    visible: !root.showingNotes && !root.showingTrash
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
                        ToolTip.text: modelData.fileName + (modelData.duplicate ? qsTr("\nSame file as another library entry") : "") + (modelData.excluded ? qsTr("\nExcluded from text search") : "")
                        DragHandler {
                            id: dragHandler
                            objectName: "libraryPaperDrag"
                            target: null
                            grabPermissions: PointerHandler.CanTakeOverFromAnything
                            onActiveChanged: {
                                if (active) {
                                    dragGhost.paperUrls = paper.paperUrls
                                    dragGhost.title = paper.modelData.name
                                    dragGhost.follow(centroid.scenePosition)
                                    dragGhost.Drag.active = true
                                } else if (dragGhost.Drag.active) {
                                    dragGhost.Drag.drop()
                                    dragGhost.Drag.active = false
                                }
                            }
                            onCentroidChanged: if (active) dragGhost.follow(centroid.scenePosition)
                        }
                        TapHandler {
                            acceptedButtons: Qt.RightButton
                            onTapped: {
                                if (paper.paperUrls.length > 1 || root.selecting && root.isSelected(paper.modelData.url)) { batchMenu.urls = paper.paperUrls; batchMenu.popup() }
                                else { root.selection = []; paperMenu.show(paper.modelData) }
                            }
                        }
                        contentItem: RowLayout {
                            spacing: 10
                            Rectangle {
                                objectName: "librarySelectMark"
                                visible: root.selecting
                                readonly property bool chosen: root.isSelected(paper.modelData.url)
                                Layout.preferredWidth: 16; Layout.preferredHeight: 16; radius: 8
                                color: chosen ? Theme.accent : "transparent"
                                border.width: chosen ? 0 : 1.5; border.color: Theme.border
                                Icon { anchors.centerIn: parent; visible: parent.chosen; name: "check"; size: 11; color: Theme.onAccent }
                            }
                            Rectangle {
                                // Reading state: hollow unread, half reading, full read.
                                visible: !root.selecting
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
                                    ToolTip.text: qsTr("Add to ") + modelData.name
                                    onClicked: { const url = paper.modelData.url, id = modelData.id; Qt.callLater(function() { researchStore.setDocumentCollection(url, id, true) }) }
                                }
                            }
                            // The star shows on favorites; on hover it is the toggle.
                            IconButton {
                                objectName: "libraryFavorite-" + paper.modelData.id
                                icon.name: "star"
                                opacity: paper.modelData.favorite || paper.hovered || hovered ? 1 : 0
                                tint: paper.modelData.favorite ? Theme.accent : Theme.textDisabled
                                description: paper.modelData.favorite ? qsTr("Remove from Favorites") : qsTr("Add to Favorites")
                                onClicked: researchStore.setFavorite(paper.modelData.url, !paper.modelData.favorite)
                            }
                        }
                    }
                    DropArea {
                        anchors.fill: parent
                        keys: ["text/uri-list"]
                        onDropped: function(drop) {
                            const pdfs = drop.urls.filter(function(u) { return /\.pdf$/i.test(u.toString()) })
                            if (pdfs.length) { researchStore.addDocuments(pdfs, root.filter.collection || ""); drop.acceptProposedAction() }
                        }
                        Rectangle { anchors.fill: parent; visible: parent.containsDrag; color: "transparent"; radius: Theme.radius; border.width: 2; border.color: Theme.accent }
                    }
                    Label {
                        anchors.centerIn: parent
                        visible: papers.count === 0
                        text: root.filter.collection ? qsTr("No papers here yet. Add PDFs with +, or drop them here.") : root.query.length || Object.keys(root.filter).length ? qsTr("No papers match.") : qsTr("Papers you open or add with + appear here.")
                        color: Theme.textTertiary
                    }
                }
            }
        }
    }
}
