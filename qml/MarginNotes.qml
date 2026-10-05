import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui
import "Platform.js" as Platform

// Notes beside the page: the paper's comments (on a selection or a spot) and highlights with a
// note, in page order. Hover a note to outline its place on the page, click to go there, write
// and edit in place. They are the same annotations as on the page, so export, search and undo
// work on them too.
Rectangle {
    id: root
    objectName: "marginNotes"
    required property var canvas
    property url source
    // The note being written for a new place: {page, selection} or {page, rectangle}.
    property var draft: null
    property string editingId: ""
    readonly property var notes: canvas.savedHighlights
        .filter(function(h) { return h.kind === "comment" || (h.kind === "highlight" && !!h.body) })
        .sort(function(a, b) { return a.page - b.page || ((a.rectangles[0] || {}).y || 0) - ((b.rectangles[0] || {}).y || 0) })
    color: Theme.sidebar
    function beginDraft(spec) {
        draft = spec
        editingId = ""
        list.positionViewAtBeginning()
        Qt.callLater(function() { const card = list.headerItem ? list.headerItem.item : null; if (card) card.field.forceActiveFocus() })
    }
    function edit(id) {
        draft = null
        editingId = id
        const at = notes.findIndex(function(n) { return n.id === id })
        if (at >= 0) list.positionViewAtIndex(at, ListView.Contain)
    }
    function saveDraft(body) {
        if (!draft || !body.trim().length) { draft = null; return }
        const color = canvas.markColor
        if (draft.selection) {
            const s = draft.selection
            researchStore.commentText(root.source, s.page, s.from, s.to, s.text, body, color)
        } else {
            researchStore.saveAnnotation(root.source, draft.page, {kind: "comment", page: draft.page, rectangles: [draft.rectangle],
                                                                   color: color, sha256: canvas.documentFingerprint, body: body})
        }
        draft = null
    }
    Rectangle { anchors.left: parent.left; width: 1; height: parent.height; color: Theme.separator }
    ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: 1
        spacing: 0
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.barHeight
            Layout.leftMargin: 12; Layout.rightMargin: 6
            Label {
                Layout.fillWidth: true
                text: "Notes" + (root.notes.length ? "  " + root.notes.length : "")
                font.pixelSize: Theme.fontSmall; font.weight: Font.DemiBold; color: Theme.textSecondary
            }
            IconButton {
                objectName: "newMarginNote"
                icon.name: "add"
                description: root.canvas.selectedAnchor ? "Note on the selection" : "New note · then click a place on the page"
                onClicked: {
                    if (root.canvas.selectedAnchor) root.beginDraft({page: root.canvas.selectedAnchor.page, selection: root.canvas.selectedAnchor})
                    else { root.canvas.captureMode = false; root.canvas.tool = "comment" }
                }
            }
        }
        ListView {
            id: list
            objectName: "marginNoteList"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 8
            topMargin: 4; bottomMargin: 12
            model: root.notes
            ScrollBar.vertical: ScrollBar {}
            header: Loader {
                id: draftCard
                width: list.width
                active: root.draft !== null
                height: active && item ? item.implicitHeight + 8 : 0
                sourceComponent: NoteCard {
                    width: list.width
                    page: root.draft ? root.draft.page : 0
                    quote: root.draft && root.draft.selection ? root.draft.selection.text || "" : ""
                    ink: root.canvas.markColor
                    editing: true
                    onCommitted: function(body) { root.saveDraft(body) }
                    onCancelled: root.draft = null
                }
            }
            delegate: NoteCard {
                id: card
                required property var modelData
                required property int index
                width: list.width
                objectName: "marginNote-" + modelData.id
                noteId: modelData.id
                page: modelData.page
                quote: modelData.text || ""
                body: modelData.body || ""
                ink: modelData.color
                // A page heading above the first note of each page.
                pageHeading: index === 0 || root.notes[index - 1].page !== modelData.page
                current: root.canvas.currentPage === modelData.page
                editing: root.editingId === modelData.id
                onHoveredChanged: root.canvas.focusedMark = hovered ? modelData.id : (root.canvas.focusedMark === modelData.id ? "" : root.canvas.focusedMark)
                onOpened: root.canvas.showSource(modelData.page, modelData.rectangles[0])
                onEditRequested: root.edit(modelData.id)
                onCommitted: function(text) {
                    root.editingId = ""
                    if (text.trim().length && text !== (modelData.body || "")) researchStore.updateHighlight(modelData.id, modelData.color, text)
                }
                onCancelled: root.editingId = ""
                onRemoveRequested: { const id = modelData.id; Qt.callLater(function() { researchStore.removeHighlight(id) }) }
            }
            // Follow the page being read (unless the pointer is in the list).
            Connections {
                target: root.canvas
                function onCurrentPageChanged() {
                    if (listHover.hovered || root.editingId.length || root.draft) return
                    const at = root.notes.findIndex(function(n) { return n.page >= root.canvas.currentPage })
                    if (at >= 0) list.positionViewAtIndex(at, ListView.Beginning)
                }
            }
            HoverHandler { id: listHover }
            Label {
                anchors.centerIn: parent
                width: parent.width - 32
                visible: root.notes.length === 0 && !root.draft
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: "Select text and add a note, or use + and click a place on the page."
                color: Theme.textTertiary
                font.pixelSize: Theme.fontSmall
            }
        }
    }

    // One note: page, the quoted text with its ink, and the note itself (editable in place).
    component NoteCard: Item {
        id: card
        property string noteId: ""
        property int page: 0
        property string quote: ""
        property string body: ""
        property color ink: Theme.accent
        property bool pageHeading: false
        property bool current: true
        property bool editing: false
        property alias field: editor
        readonly property bool hovered: hover.hovered
        signal opened()
        signal editRequested()
        signal committed(string text)
        signal cancelled()
        signal removeRequested()
        implicitHeight: column.implicitHeight
        height: implicitHeight
        ColumnLayout {
            id: column
            width: parent.width
            spacing: 4
            Label {
                visible: card.pageHeading
                Layout.leftMargin: 14; Layout.topMargin: 6
                text: "Page " + (card.page + 1)
                font.pixelSize: Theme.fontCaption; font.weight: Font.DemiBold
                color: card.current ? Theme.text : Theme.textTertiary
            }
            Rectangle {
                Layout.fillWidth: true
                Layout.leftMargin: 8; Layout.rightMargin: 8
                implicitHeight: inner.implicitHeight + 16
                radius: Theme.radius
                color: Theme.content
                border.width: card.editing || hover.hovered ? 1 : 1
                border.color: card.editing ? Theme.accentBorder : hover.hovered ? Theme.border : Theme.separator
                HoverHandler { id: hover }
                TapHandler { enabled: !card.editing; onTapped: card.opened(); onDoubleTapped: card.editRequested() }
                TapHandler { acceptedButtons: Qt.RightButton; enabled: card.noteId.length > 0; onTapped: noteMenu.popup() }
                Menu {
                    id: noteMenu
                    MenuItem { text: "Go to"; onTriggered: card.opened() }
                    MenuItem { text: "Edit"; onTriggered: card.editRequested() }
                    MenuItem { text: "Copy Note"; onTriggered: researchStore.copyText(card.body) }
                    MenuSeparator {}
                    MenuItem { objectName: "removeMarginNote"; text: "Delete Note"; palette.windowText: Theme.danger; onTriggered: card.removeRequested() }
                }
                ColumnLayout {
                    id: inner
                    x: 10; y: 8
                    width: parent.width - 20
                    spacing: 6
                    // The quoted text, marked with the note's ink.
                    RowLayout {
                        visible: card.quote.length > 0
                        Layout.fillWidth: true
                        spacing: 8
                        Rectangle { Layout.preferredWidth: 3; Layout.fillHeight: true; radius: 1.5; color: card.ink }
                        Label {
                            Layout.fillWidth: true
                            text: card.quote
                            textFormat: Text.PlainText
                            wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight
                            font.pixelSize: Theme.fontSmall; color: Theme.textSecondary
                        }
                    }
                    Label {
                        visible: !card.editing
                        Layout.fillWidth: true
                        text: card.body
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        color: card.current ? Theme.text : Theme.textSecondary
                    }
                    TextArea {
                        id: editor
                        objectName: "marginNoteEditor"
                        visible: card.editing
                        Layout.fillWidth: true
                        text: card.body
                        placeholderText: "Write a note…"
                        wrapMode: TextEdit.Wrap
                        onVisibleChanged: if (visible) { text = card.body; forceActiveFocus(); cursorPosition = length }
                        // Cmd+Return saves, Esc cancels, leaving the field saves.
                        Keys.onPressed: function(event) {
                            if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) { event.accepted = true; card.committed(text) }
                            else if (event.key === Qt.Key_Escape) { event.accepted = true; card.cancelled() }
                        }
                        onActiveFocusChanged: if (!activeFocus && card.editing) card.committed(text)
                    }
                    Label {
                        visible: card.editing
                        Layout.fillWidth: true
                        text: Platform.keys("Ctrl+Return") + " to save · Esc to cancel"
                        font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
                    }
                }
            }
        }
    }
}
