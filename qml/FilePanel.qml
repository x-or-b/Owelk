import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import Owelk.Ui
import "WorkspaceTree.js" as Tree

// The Library panel: the bookshelf beside the reader. Collections (drop a tab or a paper on one to
// file it), workspaces, tags, and the paper folder. Sections fold; the folder takes the rest.
Item {
    id: root
    objectName: "libraryPanel"
    property url folder
    // The document workspace, for tabs dropped on a collection.
    property var workspace: null
    signal libraryFilterRequested(var filter)
    signal workspaceChosen(string id)
    signal workspaceManageRequested(string id)
    property var collections: []
    property var tags: []
    property int unsorted: 0
    function refreshShelf() { collections = researchStore.collections(); tags = researchStore.tags(); unsorted = researchStore.unsortedCount() }
    function sectionOpen(name, fallback) { return researchStore.setting("library.section." + name, fallback ? "1" : "0") === "1" }
    property bool collectionsOpen: sectionOpen("collections", true)
    property bool workspacesOpen: sectionOpen("workspaces", true)
    property bool tagsOpen: sectionOpen("tags", false)
    property bool folderOpen: sectionOpen("folder", true)
    function setSection(name, open) { researchStore.setSetting("library.section." + name, open ? "1" : "0") }
    Connections {
        target: researchStore
        function onDocumentsChanged() { root.refreshShelf() }
        function onHomeChanged() { root.refreshShelf() }
    }
    // Tabs dragged over a collection are filed there (PDF tabs only); the tab stays open.
    function claimDrop(id, x, y) {
        if (!visible || !collectionsOpen || !workspace) return null
        const p = shelf.mapFromItem(null, x, y)
        if (p.x < 0 || p.y < 0 || p.x > shelf.width || p.y > shelf.height) return null
        const i = shelf.indexAt(p.x, p.y + shelf.contentY)
        const row = i >= 0 ? shelf.model[i] : null
        if (!row || row.unsorted) return null
        const strip = Tree.owner(workspace.tree, id)
        const tab = strip ? strip.tabs.find(function(t) { return t.id === id }) : null
        if (!tab || tab.kind) return null
        return {handler: root, collection: row.id, name: row.name, source: tab.source}
    }
    function dropTab(id, target) {
        if (researchStore.setDocumentCollection(target.source, target.collection, true)) researchStore.notify("Added to " + target.name + ".")
    }
    Component.onDestruction: if (workspace) workspace.removeDropHandler(root)
    // A section heading: a chevron and a name; click folds it.
    component SectionHeader: Item {
        id: heading
        property string title
        property bool open
        signal toggled()
        default property alias actions: actionRow.data
        Layout.fillWidth: true
        implicitHeight: Theme.rowHeight
        Icon { id: chevron; x: 2; anchors.verticalCenter: parent.verticalCenter; name: heading.open ? "down" : "right"; size: Theme.fontSmall; color: Theme.textTertiary }
        Label {
            anchors.left: chevron.right; anchors.leftMargin: 4; anchors.verticalCenter: parent.verticalCenter
            text: heading.title; font.pixelSize: Theme.fontCaption; font.weight: Font.DemiBold; color: Theme.textSecondary
        }
        TapHandler { onTapped: heading.toggled() }
        Row { id: actionRow; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; spacing: 2 }
    }
    property var pending: ({})
    property var latestRequests: ({})
    property bool initialized: false
    property string status: ""
    signal folderChosen(url folder)
    signal documentChosen(url source)

    function load(url, parentUrl, depth) {
        const request = researchStore.listFolder(url)
        pending[request] = {parentUrl: parentUrl, depth: depth}
        latestRequests[parentUrl] = request
    }
    function refresh() {
        if (!rows) return
        rows.clear()
        pending = ({})
        latestRequests = ({})
        status = ""
        if (folder.toString().length) { status = "Loading…"; load(folder, "", 0) }
    }
    function toggle(index) {
        const row = rows.get(index)
        if (!row.directory) { documentChosen(row.url); return }
        if (row.expanded) {
            let count = 0
            while (index + count + 1 < rows.count && rows.get(index + count + 1).depth > row.depth) count++
            if (count) rows.remove(index + 1, count)
            rows.setProperty(index, "expanded", false)
        } else {
            rows.setProperty(index, "expanded", true)
            rows.setProperty(index, "loading", true)
            load(row.url, row.url, row.depth + 1)
        }
    }
    onFolderChanged: if (initialized) refresh()
    Component.onCompleted: { initialized = true; refresh(); refreshShelf(); if (workspace) workspace.addDropHandler(root) }
    ListModel { id: rows }
    Connections {
        target: researchStore
        function onFolderLoaded(requestId, folder, entries, error) {
            const request = root.pending[requestId]
            if (!request) return
            delete root.pending[requestId]
            if (root.latestRequests[request.parentUrl] !== requestId) return
            let insertAt = 0
            if (request.parentUrl.length) {
                let parentIndex = -1
                for (let i = 0; i < rows.count; ++i) {
                    if (rows.get(i).url === request.parentUrl) { parentIndex = i; break }
                }
                if (parentIndex < 0) return
                rows.setProperty(parentIndex, "loading", false)
                if (!rows.get(parentIndex).expanded) return
                insertAt = parentIndex + 1
                if (error.length) rows.setProperty(parentIndex, "expanded", false)
            }
            root.status = error
            for (let i = 0; i < entries.length; ++i) {
                rows.insert(insertAt + i, {name: entries[i].name, url: entries[i].url,
                    directory: entries[i].directory, depth: request.depth, expanded: false, loading: false})
            }
            if (!rows.count && !error.length) root.status = "No PDFs or subfolders."
        }
    }
    FolderDialog { id: folderDialog; title: "Open paper folder"; onAccepted: root.folderChosen(selectedFolder) }
    Menu {
        id: shelfMenu
        objectName: "panelCollectionMenu"
        property var collection: ({})
        MenuItem { text: "Open in Library"; onTriggered: root.libraryFilterRequested({collection: shelfMenu.collection.id}) }
        MenuItem { objectName: "panelAddPdfs"; text: "Add PDFs…"; onTriggered: addFiles.open() }
    }
    FileDialog {
        id: addFiles
        title: "Add PDFs to " + (shelfMenu.collection.name || "the collection")
        fileMode: FileDialog.OpenFiles
        nameFilters: ["PDF documents (*.pdf)"]
        onAccepted: researchStore.addDocuments(selectedFiles, shelfMenu.collection.id)
    }
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 8
        spacing: 2
        // --- Collections ----------------------------------------------------------------------
        SectionHeader {
            objectName: "collectionsSection"
            title: "Collections"; open: root.collectionsOpen
            onToggled: { root.collectionsOpen = !root.collectionsOpen; root.setSection("collections", root.collectionsOpen) }
        }
        ListView {
            id: shelf
            objectName: "panelCollections"
            visible: root.collectionsOpen
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(contentHeight, root.height * .35)
            clip: true
            interactive: contentHeight > height
            model: (root.unsorted > 0 ? [{unsorted: true, name: "Unsorted", count: root.unsorted, depth: 0}] : []).concat(root.collections)
            delegate: ItemDelegate {
                id: shelfRow
                required property var modelData
                objectName: "panelCollection-" + modelData.name
                width: ListView.view.width
                height: Theme.rowHeight
                leftPadding: 26 + 12 * (modelData.depth || 0)
                rightPadding: 34
                text: modelData.name
                readonly property bool tabOver: !!root.workspace && !!root.workspace.dropTarget && root.workspace.dropTarget.handler === root && root.workspace.dropTarget.collection === modelData.id
                highlighted: tabOver || drop.containsDrag
                onClicked: root.libraryFilterRequested(modelData.unsorted ? {unsorted: true} : {collection: modelData.id})
                Icon { x: 6 + 12 * (shelfRow.modelData.depth || 0); anchors.verticalCenter: parent.verticalCenter; name: shelfRow.modelData.unsorted ? "filter" : "folder"; size: Theme.fontBody; color: Theme.textTertiary }
                Label { anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter; text: shelfRow.modelData.count; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary }
                // Papers dragged from the Library list are filed here too.
                DropArea {
                    id: drop
                    anchors.fill: parent
                    enabled: !shelfRow.modelData.unsorted
                    keys: ["owelk/paper", "text/uri-list"]
                    // A Library paper is filed here; PDF files from the desktop are added to the Library and filed.
                    onDropped: function(event) {
                        if (event.source && event.source.paperUrls) researchStore.setDocumentsCollection(event.source.paperUrls, shelfRow.modelData.id, true)
                        else researchStore.addDocuments(event.urls.filter(function(u) { return /\.pdf$/i.test(u.toString()) }), shelfRow.modelData.id)
                    }
                }
                TapHandler { acceptedButtons: Qt.RightButton; enabled: !shelfRow.modelData.unsorted; onTapped: { shelfMenu.collection = shelfRow.modelData; shelfMenu.popup() } }
            }
        }
        Label {
            visible: root.collectionsOpen && !shelf.count
            Layout.fillWidth: true; leftPadding: 8; wrapMode: Text.Wrap
            text: "Create collections in the Library to file papers by topic."
            font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
        }
        // --- Workspaces -----------------------------------------------------------------------
        SectionHeader {
            title: "Workspaces"; open: root.workspacesOpen
            onToggled: { root.workspacesOpen = !root.workspacesOpen; root.setSection("workspaces", root.workspacesOpen) }
        }
        Repeater {
            model: root.workspacesOpen ? researchStore.recentWorkspaces.slice(0, 8) : []
            delegate: ItemDelegate {
                id: workspaceRow
                required property var modelData
                objectName: "panelWorkspace-" + modelData.name
                Layout.fillWidth: true
                implicitHeight: Theme.rowHeight
                leftPadding: 26
                text: modelData.name
                onClicked: root.workspaceChosen(modelData.id)
                Icon { x: 6; anchors.verticalCenter: parent.verticalCenter; name: "workspace"; size: Theme.fontBody; color: Theme.textTertiary }
                TapHandler { acceptedButtons: Qt.RightButton; onTapped: workspaceMenu.popup() }
                Menu {
                    id: workspaceMenu
                    MenuItem { text: "Open"; onTriggered: root.workspaceChosen(workspaceRow.modelData.id) }
                    MenuItem { text: "Manage Links…"; onTriggered: root.workspaceManageRequested(workspaceRow.modelData.id) }
                }
            }
        }
        // --- Tags -----------------------------------------------------------------------------
        SectionHeader {
            title: "Tags"; open: root.tagsOpen
            visible: root.tags.length > 0
            onToggled: { root.tagsOpen = !root.tagsOpen; root.setSection("tags", root.tagsOpen) }
        }
        Flow {
            visible: root.tagsOpen && root.tags.length > 0
            Layout.fillWidth: true; Layout.leftMargin: 6; Layout.bottomMargin: 4
            spacing: 4
            Repeater {
                model: root.tagsOpen ? root.tags : []
                delegate: Chip {
                    required property var modelData
                    text: "# " + modelData.name
                    onClicked: root.libraryFilterRequested({tag: modelData.id})
                }
            }
        }
        // --- Folder ---------------------------------------------------------------------------
        SectionHeader {
            title: root.folder.toString().length ? "Folder · " + researchStore.fileName(root.folder) : "Recent files"
            open: root.folderOpen
            onToggled: { root.folderOpen = !root.folderOpen; root.setSection("folder", root.folderOpen) }
            IconButton { icon.name: "open"; description: "Open a folder…"; width: 22; height: 22; glyphSize: Theme.fontBody; onClicked: folderDialog.open() }
            IconButton { icon.name: "reload"; description: "Refresh folder"; width: 22; height: 22; glyphSize: Theme.fontBody; enabled: root.folder.toString().length > 0; onClicked: root.refresh() }
        }
        Label { Layout.fillWidth: true; visible: root.folderOpen && root.status.length > 0; text: root.status; wrapMode: Text.Wrap; color: Theme.textTertiary }
        Item { Layout.fillHeight: true; visible: !root.folderOpen }
        ListView {
            objectName: "folderTree"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.folderOpen && root.folder.toString().length > 0
            model: rows
            clip: true
            ScrollBar.vertical: ScrollBar {}
            delegate: ItemDelegate {
                id: fileRow
                required property int index
                required property string name
                required property string url
                required property bool directory
                required property bool expanded
                required property bool loading
                required property int depth
                width: ListView.view.width
                height: Theme.rowHeight
                // A chevron for folders, a document glyph for PDFs.
                leftPadding: 26 + depth * 14
                text: name
                onClicked: root.toggle(index)
                MouseArea { anchors.fill: parent; acceptedButtons: Qt.RightButton; onClicked: { fileMenu.row = {url: fileRow.url, directory: fileRow.directory, index: fileRow.index}; fileMenu.popup() } }
                Icon {
                    x: 6 + fileRow.depth * 14; anchors.verticalCenter: parent.verticalCenter
                    name: fileRow.loading ? "reload" : fileRow.directory ? (fileRow.expanded ? "down" : "right") : "document"
                    size: Theme.fontBody
                    color: Theme.textTertiary
                }
                ToolTip.visible: hovered
                ToolTip.delay: 500
                ToolTip.text: researchStore.localPath(url)
            }
        }
        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.folderOpen && !root.folder.toString().length
            model: researchStore.recentDocuments
            clip: true
            ScrollBar.vertical: ScrollBar {}
            delegate: RecentPaperDelegate {
                width: ListView.view.width
                height: Theme.rowHeight
                onDocumentChosen: function(source, position) { root.documentChosen(source) }
                onMenuRequested: function(row) { recentMenu.show(row) }
            }
        }
    }
    PaperMenu {
        id: recentMenu
        recent: true
        onOpenRequested: function(source, position) { root.documentChosen(source) }
    }
    Menu {
        id: fileMenu
        objectName: "fileMenu"
        property var row: ({})
        readonly property string path: row.url ? researchStore.localPath(row.url) : ""
        MenuItem { text: fileMenu.row.directory ? "Expand or Collapse" : "Open"; onTriggered: root.toggle(fileMenu.row.index) }
        MenuSeparator {}
        MenuItem { text: "Copy Path"; onTriggered: researchStore.copyText(fileMenu.path) }
        MenuItem {
            text: Qt.platform.os === "osx" ? "Show in Finder" : "Show in Folder"
            onTriggered: Qt.openUrlExternally(fileMenu.row.directory ? fileMenu.row.url : researchStore.fileUrl(fileMenu.path.substring(0, fileMenu.path.lastIndexOf("/"))))
        }
    }
}
