import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui
import QtQuick.Dialogs as Native
import QtQuick.Pdf

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
    // What can be chosen in the list shown: papers (URLs) or notes (ids).
    readonly property var selectable: showingNotes ? noteRows.map(function(n) { return n.id })
                                    : showingForYou ? forYouRows.map(function(p) { return p.id })
                                    : rows.map(function(r) { return r.url.toString() })
    readonly property bool allSelected: selectable.length > 0 && selection.length === selectable.length
    function selectAll(on) { selection = on ? selectable.slice() : []; selectionAnchor = -1 }
    function noteClicked(index) {
        const id = noteRows[index].id, mods = researchStore.keyboardModifiers()
        if (mods & Qt.ShiftModifier && selectionAnchor >= 0) {
            const a = Math.min(selectionAnchor, index), b = Math.max(selectionAnchor, index)
            selection = noteRows.slice(a, b + 1).map(function(n) { return n.id })
        } else if (selecting || mods & Qt.ControlModifier) {
            selection = selection.indexOf(id) >= 0 ? selection.filter(function(n) { return n !== id }) : selection.concat([id])
            selectionAnchor = index
        } else {
            selection = []; selectionAnchor = index
            root.noteChosen(id)
        }
    }
    // The chosen notes in a new AI chat, to ask about them or have them rewritten.
    signal askNotesRequested(var ids)
    function askAboutNotes(ids) { const list = ids.slice(); setSelecting(false); root.askNotesRequested(list) }
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
    // Which list: papers (no view in the filter), For You, notes or the Trash.
    readonly property string view: ["notes", "trash", "foryou"].indexOf(filter.view) >= 0 ? filter.view : "papers"
    readonly property bool showingPapers: view === "papers"
    readonly property bool showingNotes: view === "notes"
    readonly property bool showingTrash: view === "trash"
    readonly property bool showingForYou: view === "foryou"
    // For You: new papers found for what is followed, narrowed to one source when chosen.
    readonly property var forYou: researchStore.forYou
    property string forYouSource: ""
    // For You reads in a column of at most 920 px, in the middle.
    readonly property real forYouInset: Math.max(0, (listColumn.width - 920) / 2)
    // A period chip: all, today, the last 7 or 30 days (by the paper's date, else when it was found).
    property string forYouRange: "all"
    function forYouDay(p) { return new Date((p.date && p.date.length ? p.date : (p.foundAt || "").slice(0, 10)) + "T00:00:00") }
    function inForYouRange(p, range) {
        if (range === "all") return true
        const today = new Date(); today.setHours(0, 0, 0, 0)
        const age = Math.round((today - forYouDay(p)) / 86400000)
        return range === "today" ? age <= 0 : range === "week" ? age < 7 : age < 30
    }
    readonly property var forYouFromSource: forYou.items.filter(function(p) { return !forYouSource.length || p.source === forYouSource })
    readonly property var forYouRows: forYouFromSource.filter(function(p) { return root.inForYouRange(p, root.forYouRange) })
    // "Lovelace et al." and "Today", "3 days ago": the details at a glance.
    function shortAuthors(authors) {
        const names = (authors || "").split(/\s*,\s*/).filter(function(n) { return n.length })
        if (!names.length) return ""
        const family = names[0].split(/\s+/).pop()
        return names.length > 1 ? family + qsTr(" et al.") : family
    }
    function relativeDay(p) {
        const day = forYouDay(p)
        if (isNaN(day.getTime())) return ""
        const today = new Date(); today.setHours(0, 0, 0, 0)
        const age = Math.round((today - day) / 86400000)
        return age <= 0 ? qsTr("Today") : age === 1 ? qsTr("Yesterday") : age < 7 ? age + qsTr(" days ago") : day.toLocaleDateString(Qt.locale(), Locale.ShortFormat)
    }
    function forYouClicked(index) {
        const id = forYouRows[index].id, mods = researchStore.keyboardModifiers()
        if (mods & Qt.ShiftModifier && selectionAnchor >= 0) {
            const a = Math.min(selectionAnchor, index), b = Math.max(selectionAnchor, index)
            selection = forYouRows.slice(a, b + 1).map(function(p) { return p.id })
        } else if (selecting || mods & Qt.ControlModifier) {
            selection = selection.indexOf(id) >= 0 ? selection.filter(function(p) { return p !== id }) : selection.concat([id])
            selectionAnchor = index
        } else {
            // Open in place: the whole abstract at once (a web page takes a while), with Add and its page.
            // With a preview showing, the paper clicked is shown there too.
            selection = []; selectionAnchor = index
            if (previewShown && forYouRows[index].hasPdf) { forYouOpen = id; previewForYou(id); return }
            forYouOpen = forYouOpen === id ? "" : id
        }
    }
    // A paper read beside the list before deciding (Preview): its PDF on the right, the list moves left.
    property string forYouPreview: ""
    property url forYouPreviewUrl: ""
    property string forYouPreviewError: ""
    readonly property bool previewShown: showingForYou && forYouPreview.length > 0
    function previewForYou(id) {
        if (forYouPreview === id && (forYouPreviewUrl.toString().length || forYou.previewing === id)) return
        forYouPreview = id; forYouPreviewUrl = ""; forYouPreviewError = ""
        forYou.preview(id)
    }
    function closePreview() { forYouPreview = ""; forYouPreviewUrl = ""; forYouPreviewError = "" }
    Connections {
        target: root.forYou
        function onPreviewReady(id, file) { if (id === root.forYouPreview) root.forYouPreviewUrl = file }
        function onPreviewFailed(id, why) { if (id === root.forYouPreview) root.forYouPreviewError = why }
        // Added or dismissed: its preview closes.
        function onChanged() { if (root.forYouPreview.length && !root.forYou.items.some(function(p) { return p.id === root.forYouPreview })) root.closePreview() }
    }
    Shortcut { sequence: "Escape"; enabled: root.previewShown && !root.selecting && root.visible; onActivated: root.closePreview() }
    // The paper opened in place (from a click here or on Home).
    property string forYouOpen: ""
    function openForYou(id) {
        forYouOpen = id
        Qt.callLater(function() {
            const at = root.forYouRows.findIndex(function(p) { return p.id === id })
            if (at >= 0) forYouList.positionViewAtIndex(at, ListView.Contain)
        })
    }
    // Its page, in a tab that gives way to the PDF downloaded there (which then gets Add's details).
    function openForYouPage(paper) { forYou.expect(paper.id); root.webRequested(paper.url) }
    function addForYou(ids) { const list = ids.slice(); setSelecting(false); forYou.add(list) }
    function dismissForYou(ids) { const list = ids.slice(); setSelecting(false); forYou.dismiss(list) }
    // A Settings page (For You's gear), and a paper's page to read in a web tab.
    signal settingsRequested(string page)
    signal webRequested(url address)
    Connections { target: root.forYou; function onChanged() { const present = root.selectable; root.selection = root.selection.filter(function(u) { return present.indexOf(u) >= 0 }) } }
    function setView(next) { if (next !== view) { setSelecting(false); closePreview() } setFilter(next === "papers" ? {} : {view: next}) }
    Shortcut { sequence: "Escape"; enabled: root.selecting && root.visible; onActivated: root.setSelecting(false) }
    // Delete or Backspace moves the chosen papers to the Trash (a text field being edited keeps its keys).
    Shortcut {
        sequences: [StandardKey.Delete, "Backspace"]
        enabled: root.selecting && root.visible && root.selection.length > 0
                 && !(root.Window.activeFocusItem && root.Window.activeFocusItem.cursorPosition !== undefined)
        onActivated: root.deleteSelection()
    }
    function deleteSelection() {
        if (showingForYou) { dismissForYou(selection); return }
        const list = selection, notes = showingNotes
        setSelecting(false)
        Qt.callLater(function() { if (notes) list.forEach(function(id) { researchStore.deleteNote(id) }); else researchStore.deletePapers(list) })
    }
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
        collectionRows = researchStore.collections()
        tagRows = researchStore.tags()
        noteRows = showingNotes ? researchStore.notes(false) : []
        const present = selectable
        selection = selection.filter(function(u) { return present.indexOf(u) >= 0 })
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
    onFilterChanged: {
        if (filter.collection) researchStore.markOpened("collection", filter.collection)
        if (filter.open) openForYou(filter.open)
    }
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
        // Papers like this collection's, in For You.
        MenuItem {
            objectName: "collectionFollow"
            checkable: true
            checked: collectionMenu.visible && root.forYou.following(collectionMenu.row.id || "")
            text: qsTr("Follow in For You")
            onTriggered: root.forYou.follow(collectionMenu.row.id, !root.forYou.following(collectionMenu.row.id))
        }
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
        MenuItem { text: qsTr("Ask AI…"); onTriggered: root.askAboutNotes([noteMenu.noteId]) }
        MenuItem { text: qsTr("Copy Markdown"); onTriggered: researchStore.copyText(researchStore.note(noteMenu.noteId).body || "") }
        MenuSeparator {}
        MenuItem { text: qsTr("Move Note to Trash"); palette.windowText: Theme.danger; onTriggered: researchStore.deleteNote(noteMenu.noteId) }
    }
    // Several selected notes: ask the AI about them, copy them, or move them to the Trash.
    Menu {
        id: noteBatchMenu
        objectName: "libraryNoteBatchMenu"
        property var ids: []
        MenuItem { enabled: false; text: noteBatchMenu.ids.length + (noteBatchMenu.ids.length === 1 ? qsTr(" note") : qsTr(" notes")) }
        MenuSeparator {}
        MenuItem { objectName: "noteBatchAsk"; text: qsTr("Ask AI…"); onTriggered: root.askAboutNotes(noteBatchMenu.ids) }
        MenuItem {
            text: qsTr("Copy Markdown")
            onTriggered: { researchStore.copyText(noteBatchMenu.ids.map(function(id) { const n = researchStore.note(id); return "# " + (n.title || "") + "\n\n" + (n.body || "").trim() }).join("\n\n---\n\n")); researchStore.notify(qsTr("Copied.")) }
        }
        MenuSeparator {}
        MenuItem { text: qsTr("Move Notes to Trash"); palette.windowText: Theme.danger; onTriggered: { const list = noteBatchMenu.ids; root.setSelecting(false); Qt.callLater(function() { list.forEach(function(id) { researchStore.deleteNote(id) }) }) } }
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
                width: Math.min(parent.width - 16, 420)
                currentIndex: ["papers", "foryou", "notes", "trash"].indexOf(root.view)
                TabButton { objectName: "libraryPapersTab"; text: qsTr("Papers"); onClicked: root.setView("papers") }
                TabButton { objectName: "libraryForYouTab"; text: root.forYou.items.length ? qsTr("For You ") + root.forYou.items.length : qsTr("For You"); onClicked: root.setView("foryou") }
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
                visible: root.showingPapers
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
            Rectangle { visible: root.showingPapers; Layout.preferredWidth: 1; Layout.fillHeight: true; color: Theme.separator }
            ColumnLayout {
                id: listColumn
                Layout.fillWidth: true; Layout.fillHeight: true
                Layout.margins: 12
                spacing: 8
                // For You: new papers for the topics and collections followed; add them, dismiss them, or
                // read their page. Select works as for papers (Add, Dismiss).
                RowLayout {
                    Layout.fillWidth: true; Layout.leftMargin: root.forYouInset; Layout.rightMargin: root.forYouInset
                    visible: root.showingForYou
                    spacing: 8
                    Label { text: qsTr("For You"); font.pixelSize: Theme.fontHeadline; font.weight: Font.DemiBold; color: Theme.text }
                    Label {
                        objectName: "libraryForYouCount"
                        Layout.alignment: Qt.AlignBaseline
                        visible: root.forYou.items.length > 0
                        text: root.forYouRows.length + (root.forYouRows.length === 1 ? qsTr(" paper") : qsTr(" papers"))
                        font.pixelSize: Theme.fontSmall; color: Theme.textTertiary
                    }
                    Item { Layout.fillWidth: true }
                    Label {
                        visible: root.forYou.explaining
                        text: qsTr("AI is reading…")
                        font.pixelSize: Theme.fontSmall; color: Theme.textTertiary
                    }
                    // The AI's view of each paper: most relevant first, one sentence on why.
                    IconButton {
                        objectName: "libraryForYouExplain"
                        icon.name: "ai"; description: qsTr("Explain with AI")
                        enabled: !root.forYou.explaining && root.forYou.items.some(function(p) { return !p.why })
                        onClicked: root.forYou.explain()
                    }
                    IconButton {
                        objectName: "libraryForYouRefresh"
                        icon.name: "reload"; description: qsTr("Check now")
                        enabled: root.forYou.configured && !root.forYou.checking
                        onClicked: root.forYou.refresh()
                    }
                    IconButton { objectName: "libraryForYouSettings"; icon.name: "settings"; description: qsTr("For You settings"); onClicked: root.settingsRequested("foryou") }
                }
                Label {
                    objectName: "libraryForYouAiProblem"
                    visible: root.showingForYou && root.forYou.aiProblem.length > 0 && !root.forYou.explaining
                    Layout.fillWidth: true; Layout.leftMargin: root.forYouInset; Layout.rightMargin: root.forYouInset
                    text: root.forYou.aiProblem
                    wrapMode: Text.Wrap; font.pixelSize: Theme.fontSmall; color: Theme.textTertiary
                }
                RowLayout {
                    Layout.fillWidth: true; Layout.leftMargin: root.forYouInset; Layout.rightMargin: root.forYouInset
                    visible: root.showingForYou && root.forYou.items.length > 0
                    spacing: 4
                    Repeater {
                        model: root.selecting ? [] : [{key: "all", name: qsTr("All")}, {key: "today", name: qsTr("Today")},
                                                      {key: "week", name: qsTr("This week")}, {key: "month", name: qsTr("This month")}]
                        delegate: Chip {
                            required property var modelData
                            readonly property int count: root.forYouFromSource.filter(function(p) { return root.inForYouRange(p, modelData.key) }).length
                            objectName: "libraryForYouRange-" + modelData.key
                            text: modelData.name
                            checkable: true
                            checked: root.forYouRange === modelData.key
                            // A period with nothing in it is quiet (still the one shown when chosen).
                            enabled: count > 0 || checked
                            ToolTip.text: count + (count === 1 ? qsTr(" paper") : qsTr(" papers"))
                            onClicked: root.forYouRange = modelData.key
                        }
                    }
                    Label {
                        objectName: "libraryForYouSelected"
                        visible: root.selecting
                        text: root.selection.length ? root.selection.length + qsTr(" selected") : qsTr("Choose papers")
                        font.pixelSize: Theme.fontSmall; color: root.selection.length ? Theme.text : Theme.textTertiary
                    }
                    Item { Layout.fillWidth: true }
                    IconButton {
                        objectName: "libraryForYouSelect"
                        visible: !root.selecting
                        icon.name: "check"; description: qsTr("Select papers")
                        onClicked: root.setSelecting(true)
                    }
                    ComboBox {
                        objectName: "libraryForYouSource"
                        visible: !root.selecting && sources.length > 1
                        Layout.preferredWidth: 200
                        readonly property var sources: (root.forYou.items, root.forYou.sources())
                        model: [qsTr("Everything")].concat(sources.map(function(s) { return s.name + " · " + s.count }))
                        currentIndex: Math.max(0, sources.findIndex(function(s) { return s.key === root.forYouSource }) + 1)
                        onActivated: function(index) { root.forYouSource = index > 0 ? sources[index - 1].key : "" }
                    }
                    Button {
                        objectName: "libraryForYouSelectAll"
                        visible: root.selecting
                        flat: true; font.pixelSize: Theme.fontSmall; horizontalPadding: 8
                        implicitHeight: Theme.controlHeightSmall
                        text: root.allSelected ? qsTr("Deselect All") : qsTr("Select All")
                        onClicked: root.selectAll(!root.allSelected)
                    }
                    Button {
                        objectName: "libraryForYouAddSelection"
                        visible: root.selecting
                        enabled: root.selection.length > 0
                        flat: true; font.pixelSize: Theme.fontSmall; horizontalPadding: 8
                        implicitHeight: Theme.controlHeightSmall
                        text: qsTr("Add")
                        onClicked: root.addForYou(root.selection)
                    }
                    Button {
                        objectName: "libraryForYouDismissSelection"
                        visible: root.selecting
                        enabled: root.selection.length > 0
                        flat: true; font.pixelSize: Theme.fontSmall; horizontalPadding: 8
                        implicitHeight: Theme.controlHeightSmall
                        text: qsTr("Dismiss")
                        onClicked: root.dismissForYou(root.selection)
                    }
                    Button {
                        objectName: "libraryForYouDone"
                        visible: root.selecting
                        flat: true; font.pixelSize: Theme.fontSmall; horizontalPadding: 8
                        implicitHeight: Theme.controlHeightSmall
                        text: qsTr("Done")
                        onClicked: root.setSelecting(false)
                    }
                }
                ListView {
                    id: forYouList
                    // A column of reading width, in the middle.
                    Layout.fillWidth: true; Layout.leftMargin: root.forYouInset; Layout.rightMargin: root.forYouInset
                    objectName: "libraryForYou"
                    visible: root.showingForYou
                    Layout.fillHeight: true
                    clip: true
                    model: root.showingForYou ? root.forYouRows : []
                    ScrollBar.vertical: ScrollBar {}
                    delegate: ItemDelegate {
                        id: found
                        required property var modelData
                        required property int index
                        readonly property bool chosen: root.selection.indexOf(modelData.id) >= 0
                        readonly property bool adding: root.forYou.adding.indexOf(modelData.id) >= 0
                        readonly property bool open: root.forYouOpen === modelData.id && !root.selecting
                        objectName: "libraryForYou-" + index
                        width: forYouList.width
                        height: forYouColumn.implicitHeight + 26
                        topPadding: 13; bottomPadding: 13
                        // Its own line, under the Add and Dismiss icons too (the list's ends at the text).
                        Rectangle {
                            visible: found.index < forYouList.count - 1 && !found.highlighted
                            anchors.bottom: parent.bottom; anchors.bottomMargin: -1
                            x: found.leftPadding; width: parent.width - found.leftPadding - 8
                            height: 1
                            color: Theme.separator
                        }
                        highlighted: chosen
                        rightPadding: found.open ? 12 : forYouActions.width + 12
                        onClicked: root.forYouClicked(index)
                        contentItem: RowLayout {
                            spacing: 10
                            Rectangle {
                                visible: root.selecting
                                Layout.preferredWidth: 16; Layout.preferredHeight: 16; radius: 8
                                color: found.chosen ? Theme.accent : "transparent"
                                border.width: found.chosen ? 0 : 1.5; border.color: Theme.border
                                Icon { anchors.centerIn: parent; visible: found.chosen; name: "check"; size: 11; color: Theme.onAccent }
                            }
                            // The title, why it fits (the AI's sentence), then who, when and from where, small;
                            // the abstract when opened.
                            ColumnLayout {
                                id: forYouColumn
                                Layout.fillWidth: true
                                spacing: 5
                                Label {
                                    Layout.fillWidth: true
                                    text: found.modelData.title
                                    wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight; textFormat: Text.PlainText
                                    font.pixelSize: Theme.fontBody; font.weight: Font.Medium; color: Theme.text
                                    lineHeight: 1.1
                                }
                                RowLayout {
                                    visible: !!found.modelData.why
                                    Layout.fillWidth: true
                                    spacing: 6
                                    Icon { name: "ai"; size: Theme.fontCaption; color: Theme.textTertiary; Layout.alignment: Qt.AlignTop; Layout.topMargin: 3 }
                                    Label {
                                        objectName: "libraryForYouWhy-" + found.index
                                        Layout.fillWidth: true
                                        text: found.modelData.why || ""
                                        wrapMode: Text.Wrap; textFormat: Text.PlainText
                                        font.pixelSize: Theme.fontSmall; color: Theme.textSecondary
                                        lineHeight: 1.15
                                    }
                                }
                                Label {
                                    objectName: "libraryForYouMeta-" + found.index
                                    Layout.fillWidth: true
                                    text: [root.shortAuthors(found.modelData.authors), root.relativeDay(found.modelData), found.modelData.sourceName,
                                           found.modelData.hasPdf ? "" : qsTr("No free PDF")].filter(function(t) { return t && t.length }).join("  ·  ")
                                    elide: Text.ElideRight; textFormat: Text.PlainText; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
                                }
                                Label {
                                    objectName: "libraryForYouAbstract-" + found.index
                                    Layout.fillWidth: true
                                    Layout.topMargin: 4
                                    visible: found.open && (found.modelData.abstract || "").length > 0
                                    text: found.modelData.abstract || ""
                                    wrapMode: Text.Wrap; textFormat: Text.PlainText
                                    font.pixelSize: Theme.fontSmall; color: Theme.text
                                    lineHeight: 1.2
                                }
                                // Opened: what to do with it.
                                RowLayout {
                                    visible: found.open
                                    Layout.topMargin: 6
                                    spacing: 6
                                    Label { visible: found.adding; text: qsTr("Adding…"); font.pixelSize: Theme.fontSmall; color: Theme.textTertiary }
                                    Button {
                                        objectName: "libraryForYouOpenAdd"
                                        visible: !found.adding && found.modelData.hasPdf
                                        highlighted: true
                                        implicitHeight: Theme.controlHeightSmall; font.pixelSize: Theme.fontSmall
                                        text: qsTr("Add to Library")
                                        onClicked: root.forYou.add([found.modelData.id])
                                    }
                                    Button {
                                        objectName: "libraryForYouOpenPreview"
                                        visible: found.modelData.hasPdf
                                        flat: true; implicitHeight: Theme.controlHeightSmall; font.pixelSize: Theme.fontSmall
                                        text: qsTr("Preview")
                                        onClicked: root.previewForYou(found.modelData.id)
                                    }
                                    Button {
                                        objectName: "libraryForYouOpenPage"
                                        flat: found.modelData.hasPdf; highlighted: !found.modelData.hasPdf
                                        implicitHeight: Theme.controlHeightSmall; font.pixelSize: Theme.fontSmall
                                        text: found.modelData.hasPdf ? qsTr("Open Page") : qsTr("Get PDF on Its Page")
                                        onClicked: root.openForYouPage(found.modelData)
                                        ToolTip.visible: hovered && !found.modelData.hasPdf; ToolTip.delay: 400
                                        ToolTip.text: qsTr("No free PDF was found. A PDF you download there joins the Library, and the paper leaves For You.")
                                    }
                                    Button {
                                        objectName: "libraryForYouOpenDismiss"
                                        visible: !found.adding
                                        flat: true; implicitHeight: Theme.controlHeightSmall; font.pixelSize: Theme.fontSmall
                                        text: qsTr("Dismiss")
                                        onClicked: root.forYou.dismiss([found.modelData.id])
                                    }
                                }
                            }
                        }
                        // Add and Dismiss on hover (and while the PDF comes), like Home; the room stays, so nothing moves.
                        Row {
                            id: forYouActions
                            visible: !root.selecting && !found.open
                            opacity: found.hovered || previewIcon.hovered || addIcon.hovered || dismissIcon.hovered || found.adding ? 1 : 0
                            anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
                            spacing: 2
                            Label { visible: found.adding; anchors.verticalCenter: parent.verticalCenter; text: qsTr("Adding…"); font.pixelSize: Theme.fontSmall; color: Theme.textTertiary }
                            IconButton {
                                id: previewIcon
                                objectName: "libraryForYouPreview-" + found.index
                                visible: !found.adding && found.modelData.hasPdf
                                icon.name: "preview"; description: qsTr("Preview the PDF")
                                onClicked: { root.forYouOpen = found.modelData.id; root.previewForYou(found.modelData.id) }
                            }
                            IconButton {
                                id: addIcon
                                objectName: "libraryForYouAdd-" + found.index
                                visible: !found.adding
                                icon.name: found.modelData.hasPdf ? "download" : "external"
                                description: found.modelData.hasPdf ? qsTr("Add to the Library") : qsTr("No free PDF: open its page")
                                onClicked: found.modelData.hasPdf ? root.forYou.add([found.modelData.id]) : root.openForYouPage(found.modelData)
                            }
                            IconButton {
                                id: dismissIcon
                                objectName: "libraryForYouDismiss-" + found.index
                                visible: !found.adding
                                icon.name: "close"; description: qsTr("Dismiss")
                                onClicked: root.forYou.dismiss([found.modelData.id])
                            }
                        }
                    }
                    // Nothing followed: the way to the settings; nothing new: when it last looked.
                    ColumnLayout {
                        anchors.centerIn: parent
                        width: Math.min(parent.width - 40, 420)
                        visible: forYouList.count === 0
                        spacing: 10
                        Label {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap
                            text: !root.forYou.configured ? qsTr("Follow a collection or a topic to see new papers here")
                                : root.forYou.checking ? qsTr("Looking for new papers…")
                                : root.forYou.problem.length ? root.forYou.problem
                                : root.forYou.lastChecked.getTime && !isNaN(root.forYou.lastChecked.getTime())
                                    ? qsTr("Nothing new. Checked ") + root.forYou.lastChecked.toLocaleString(Qt.locale(), Locale.ShortFormat)
                                    : qsTr("Not checked yet.")
                            color: root.forYou.problem.length && root.forYou.configured ? Theme.danger : Theme.textTertiary
                        }
                        Button {
                            objectName: "libraryForYouSetup"
                            visible: !root.forYou.configured
                            Layout.alignment: Qt.AlignHCenter
                            text: qsTr("Choose Topics…")
                            onClicked: root.settingsRequested("foryou")
                        }
                    }
                }
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
                }
                RowLayout {
                    Layout.fillWidth: true
                    visible: root.showingNotes
                    Label {
                        objectName: "libraryNoteCount"; Layout.fillWidth: true
                        text: root.selecting ? (root.selection.length ? root.selection.length + qsTr(" selected") : qsTr("Choose notes"))
                                             : root.noteRows.length + (root.noteRows.length === 1 ? qsTr(" note") : qsTr(" notes"))
                        font.pixelSize: Theme.fontSmall; color: root.selecting && root.selection.length ? Theme.text : Theme.textTertiary
                    }
                    Button {
                        objectName: "libraryNoteSelectAll"
                        visible: root.selecting
                        flat: true; font.pixelSize: Theme.fontSmall; horizontalPadding: 8
                        implicitHeight: Theme.controlHeightSmall
                        text: root.allSelected ? qsTr("Deselect All") : qsTr("Select All")
                        onClicked: root.selectAll(!root.allSelected)
                    }
                    Button {
                        objectName: "libraryNoteAsk"
                        visible: root.selecting
                        enabled: root.selection.length > 0
                        flat: true; font.pixelSize: Theme.fontSmall; horizontalPadding: 8
                        implicitHeight: Theme.controlHeightSmall
                        text: qsTr("Ask AI")
                        onClicked: root.askAboutNotes(root.selection)
                    }
                    Button {
                        objectName: "libraryNoteDelete"
                        visible: root.selecting
                        enabled: root.selection.length > 0
                        flat: true; font.pixelSize: Theme.fontSmall; horizontalPadding: 8
                        implicitHeight: Theme.controlHeightSmall
                        palette.buttonText: Theme.danger
                        text: qsTr("Delete")
                        onClicked: root.deleteSelection()
                    }
                    Button {
                        objectName: "libraryNoteDone"
                        visible: root.selecting
                        flat: true; font.pixelSize: Theme.fontSmall; horizontalPadding: 8
                        implicitHeight: Theme.controlHeightSmall
                        text: qsTr("Done")
                        onClicked: root.setSelecting(false)
                    }
                    IconButton { objectName: "libraryNewNote"; visible: !root.selecting; icon.name: "add"; description: qsTr("New note"); onClicked: root.newNoteRequested() }
                    IconButton {
                        objectName: "libraryNoteSelect"
                        visible: !root.selecting
                        enabled: root.noteRows.length > 0
                        icon.name: "check"
                        description: qsTr("Select notes")
                        onClicked: root.setSelecting(true)
                    }
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
                        readonly property bool chosen: root.selection.indexOf(modelData.id) >= 0
                        width: noteList.width; height: Theme.rowHeightTall
                        separator: index < noteList.count - 1
                        highlighted: chosen
                        onClicked: root.noteClicked(index)
                        // Right-click on a chosen note acts on all chosen ones.
                        TapHandler {
                            acceptedButtons: Qt.RightButton
                            onTapped: {
                                if (noteItem.chosen && (root.selection.length > 1 || root.selecting)) { noteBatchMenu.ids = root.selection.slice(); noteBatchMenu.popup() }
                                else { root.selection = []; noteMenu.noteId = noteItem.modelData.id; noteMenu.popup() }
                            }
                        }
                        contentItem: RowLayout {
                            spacing: 10
                            Rectangle {
                                objectName: "libraryNoteMark"
                                visible: root.selecting
                                Layout.preferredWidth: 16; Layout.preferredHeight: 16; radius: 8
                                color: noteItem.chosen ? Theme.accent : "transparent"
                                border.width: noteItem.chosen ? 0 : 1.5; border.color: Theme.border
                                Icon { anchors.centerIn: parent; visible: noteItem.chosen; name: "check"; size: 11; color: Theme.onAccent }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                Label { Layout.fillWidth: true; text: noteItem.modelData.title; elide: Text.ElideRight; textFormat: Text.PlainText; color: Theme.text }
                                Label { Layout.fillWidth: true; text: noteItem.modelData.snippet || " "; elide: Text.ElideRight; textFormat: Text.PlainText; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary }
                            }
                        }
                    }
                    Label { anchors.centerIn: parent; visible: noteList.count === 0; text: qsTr("No notes yet."); color: Theme.textTertiary }
                }
                RowLayout {
                    Layout.fillWidth: true
                    visible: root.showingPapers
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
                    visible: root.showingPapers
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
                    visible: root.showingPapers
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
            // --- For You's preview: the paper's PDF beside the list, to read before adding it -----------
            Rectangle { visible: root.previewShown; Layout.preferredWidth: 1; Layout.fillHeight: true; color: Theme.separator }
            ColumnLayout {
                id: previewPane
                objectName: "forYouPreviewPane"
                visible: root.previewShown
                Layout.preferredWidth: Math.round(root.width * .56)
                Layout.fillHeight: true
                spacing: 0
                readonly property var paper: root.forYou.items.find(function(p) { return p.id === root.forYouPreview }) || ({})
                readonly property bool adding: root.forYou.adding.indexOf(root.forYouPreview) >= 0
                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.barHeight + 8
                    Layout.leftMargin: 12; Layout.rightMargin: 8
                    spacing: 6
                    Label {
                        Layout.fillWidth: true
                        text: previewPane.paper.title || ""
                        elide: Text.ElideRight; textFormat: Text.PlainText
                        font.weight: Font.Medium; color: Theme.text
                    }
                    Label { visible: previewPane.adding; text: qsTr("Adding…"); font.pixelSize: Theme.fontSmall; color: Theme.textTertiary }
                    Button {
                        objectName: "forYouPreviewAdd"
                        visible: !previewPane.adding && !!previewPane.paper.id
                        highlighted: true
                        implicitHeight: Theme.controlHeightSmall; font.pixelSize: Theme.fontSmall
                        text: qsTr("Add to Library")
                        onClicked: root.forYou.add([root.forYouPreview])
                    }
                    Button {
                        objectName: "forYouPreviewDismiss"
                        visible: !previewPane.adding && !!previewPane.paper.id
                        flat: true; implicitHeight: Theme.controlHeightSmall; font.pixelSize: Theme.fontSmall
                        text: qsTr("Dismiss")
                        onClicked: root.forYou.dismiss([root.forYouPreview])
                    }
                    IconButton { objectName: "forYouPreviewClose"; icon.name: "close"; description: qsTr("Close the preview · Esc"); onClicked: root.closePreview() }
                }
                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.separator }
                Rectangle {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    color: Theme.pdfBackdrop
                    clip: true
                    PdfMultiPageView {
                        id: previewView
                        objectName: "forYouPreviewView"
                        anchors.fill: parent
                        visible: root.forYouPreviewUrl.toString().length > 0
                        document: PdfDocument { id: previewDocument; source: root.forYouPreviewUrl }
                    }
                    Label {
                        objectName: "forYouPreviewStatus"
                        anchors.centerIn: parent
                        width: Math.min(parent.width - 40, 360)
                        visible: !previewView.visible
                        horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap
                        text: root.forYouPreviewError.length ? qsTr("Could not get the PDF: ") + root.forYouPreviewError : qsTr("Getting the PDF…")
                        color: root.forYouPreviewError.length ? Theme.danger : Theme.textTertiary
                    }
                }
            }
        }
    }
}
