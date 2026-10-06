import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui

// The one right-click menu for a paper, wherever it is listed (Home, Files, Library, search).
// One instance per view: rows call show(row). Dialogs are created only when used.
// Order: open | details and organization | state | copy | file | remove (red, last).
Item {
    id: root
    property var paper: ({})
    // Recent-paper lists also offer "Remove from Recent Papers".
    property bool recent: false
    // When the list is one collection, the menu can take the paper out of it.
    property string collectionId: ""
    signal openRequested(url source, var position)
    readonly property alias menu: menu
    readonly property var removeDialog: remove.item
    function show(row) { paper = row; menu.popup() }
    Menu {
        id: menu
        objectName: "paperMenu"
        MenuItem { objectName: "paperOpenOption"; text: "Open"; onTriggered: root.openRequested(root.paper.url, root.paper.position) }
        MenuSeparator {}
        MenuItem { objectName: "paperDetailsOption"; text: "Paper Details…"; onTriggered: { details.active = true; details.item.begin(root.paper.url) } }
        MenuItem { objectName: "libraryTagsOption"; text: "Tags…"; onTriggered: { tags.active = true; tags.item.begin(root.paper.url) } }
        Menu {
            id: collections
            title: "Collections"
            property var rows: []
            onAboutToShow: rows = researchStore.collections()
            Instantiator {
                model: collections.rows
                delegate: MenuItem {
                    required property var modelData
                    checkable: true
                    checked: menu.opened && researchStore.documentOrganization(root.paper.url).collections.indexOf(modelData.id) >= 0
                    text: "    ".repeat(modelData.depth) + modelData.name
                    onTriggered: researchStore.setDocumentCollection(root.paper.url, modelData.id, checked)
                }
                onObjectAdded: function(index, object) { collections.insertItem(index, object) }
                onObjectRemoved: function(index, object) { collections.removeItem(object) }
            }
            MenuItem { text: "New Collection…"; onTriggered: { collectionName.active = true; collectionName.item.open() } }
        }
        MenuItem {
            objectName: "removeFromCollectionOption"
            visible: root.collectionId.length > 0; height: visible ? implicitHeight : 0
            text: "Remove from This Collection"
            onTriggered: researchStore.setDocumentCollection(root.paper.url, root.collectionId, false)
        }
        MenuSeparator {}
        MenuItem {
            objectName: "paperReadStateOption"
            text: root.paper.readingState === "read" ? "Mark as Unread" : "Mark as Read"
            onTriggered: researchStore.setReadingState(root.paper.url, root.paper.readingState === "read" ? "unread" : "read")
        }
        MenuItem { text: root.paper.favorite ? "Remove from Favorites" : "Add to Favorites"; onTriggered: researchStore.setFavorite(root.paper.url, !root.paper.favorite) }
        MenuSeparator {}
        MenuItem { objectName: "copyBibtex"; text: "Copy BibTeX"; onTriggered: { researchStore.copyText(researchStore.bibtex([root.paper.url.toString()])); researchStore.notify("BibTeX copied.") } }
        MenuItem { text: "Copy File Path"; onTriggered: researchStore.copyText(researchStore.localPath(root.paper.url)) }
        MenuSeparator {}
        MenuItem {
            visible: root.paper.excluded !== undefined; height: visible ? implicitHeight : 0
            text: root.paper.excluded ? "Include in Text Search" : "Exclude from Text Search"
            onTriggered: researchStore.setExcludedFromIndex(root.paper.url, !root.paper.excluded)
        }
        MenuItem { text: "Locate Original PDF…"; onTriggered: researchStore.requestRelink(root.paper.url) }
        MenuSeparator {}
        MenuItem {
            objectName: "removeRecentOption"
            visible: root.recent; height: visible ? implicitHeight : 0
            text: "Remove from Recent Papers…"
            palette.windowText: Theme.danger
            onTriggered: { remove.active = true; remove.item.open() }
        }
        MenuItem {
            objectName: "removeFromLibraryOption"
            text: "Remove from Library…"
            palette.windowText: Theme.danger
            onTriggered: { confirm.mode = "library"; confirm.open() }
        }
        MenuItem {
            objectName: "movePdfToTrashOption"
            text: "Move PDF to Trash…"
            palette.windowText: Theme.danger
            onTriggered: { confirm.mode = "trash"; confirm.open() }
        }
    }
    Loader { id: details; active: false; sourceComponent: PaperDetailsDialog {} }
    ConfirmDialog {
        id: confirm
        objectName: "paperConfirm"
        property string mode: "library"
        title: mode === "trash" ? "Move this PDF to the Trash?" : "Remove this paper from the Library?"
        message: mode === "trash"
            ? "The file goes to the system Trash, where you can put it back. The paper leaves the Library; its annotations and captures are kept."
            : "It leaves the Library, recent papers, collections and tags. The PDF file, annotations and captures are kept; opening the file again brings it back."
        actionText: mode === "trash" ? "Move to Trash" : "Remove"
        onConfirmed: {
            const source = root.paper.url, trash = mode === "trash"
            Qt.callLater(function() { if (trash) researchStore.movePdfsToTrash([source]); else researchStore.removeFromLibrary([source]) })
        }
    }
    Loader {
        id: tags
        active: false
        sourceComponent: Dialog {
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
                Label {
                    readonly property var names: researchStore.tags().map(function(t) { return t.name })
                    visible: names.length > 0
                    Layout.fillWidth: true
                    text: "Existing: " + names.join(", ")
                    wrapMode: Text.Wrap; font.pixelSize: Theme.fontSmall; color: Theme.textTertiary
                }
            }
            onAccepted: researchStore.setDocumentTags(source, tagField.text.split(",").map(function(t) { return t.trim() }).filter(function(t) { return t.length }))
        }
    }
    Loader {
        id: collectionName
        active: false
        sourceComponent: Dialog {
            id: newCollection
            parent: Overlay.overlay
            anchors.centerIn: parent
            width: 360
            modal: true
            title: "New collection"
            standardButtons: Dialog.Save | Dialog.Cancel
            onOpened: { nameField.clear(); nameField.forceActiveFocus() }
            TextField { id: nameField; width: parent.width; placeholderText: "Collection name"; onAccepted: newCollection.accept() }
            onAccepted: {
                const id = researchStore.createCollection(nameField.text)
                if (id) researchStore.setDocumentCollection(root.paper.url, id, true)
            }
        }
    }
    Loader {
        id: remove
        active: false
        sourceComponent: Dialog {
            objectName: "removeRecentDialog"
            parent: Overlay.overlay
            anchors.centerIn: parent
            title: "Remove from Recent Papers?"
            width: 390
            modal: true
            standardButtons: Dialog.Ok | Dialog.Cancel
            Label { text: "The original PDF, open tabs and captures will be kept."; wrapMode: Text.Wrap; width: 330 }
            onAccepted: { const source = root.paper.url; Qt.callLater(function() { researchStore.removeRecentDocument(source) }) }
        }
    }
}
