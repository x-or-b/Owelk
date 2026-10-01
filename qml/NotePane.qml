import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "UiTheme.js" as Theme

// A standalone Markdown note. Saves itself shortly after typing stops; [[ inserts a link to a
// paper, excerpt, annotation or other note, and links open their source.
Rectangle {
    id: root
    objectName: "notePane"
    required property var controller
    property string noteId: ""
    property bool isActive: false
    property bool dirty: false
    property bool preview: false
    property bool loading: false
    // The note shown in the fields; noteId may already name the next one when switching tabs.
    property string loadedId: ""
    property var backlinks: []
    signal activated()
    color: Theme.surface
    function load() {
        loadedId = noteId
        const row = researchStore.note(noteId)
        loading = true
        titleField.text = row.title || ""
        body.text = row.body || ""
        loading = false
        dirty = false
        preview = (row.body || "").length > 0
        backlinks = researchStore.backlinks("note", noteId)
    }
    function save() {
        if (!dirty || !loadedId.length) return true
        if (!researchStore.saveNote(loadedId, titleField.text, body.text)) return false
        dirty = false
        controller.updateNoteTab(loadedId, titleField.text)
        return true
    }
    function focusTitle() { preview = false; titleField.forceActiveFocus() }
    onNoteIdChanged: { save(); if (noteId.length) load() }
    Component.onDestruction: save()
    Timer { id: autosave; interval: 600; onTriggered: root.save() }
    Connections {
        target: researchStore
        // Links appended from a capture's "Link to Note…" arrive while the note is open.
        function onNotesChanged() {
            if (root.dirty || !root.noteId.length) return
            const row = researchStore.note(root.noteId)
            if (row.deleted) { root.controller.closeNoteTabs(root.noteId); return }
            root.loading = true
            if ((row.body || "") !== body.text) body.text = row.body || ""
            root.loading = false
            root.dirty = false
        }
        function onLinksChanged() { root.backlinks = researchStore.backlinks("note", root.noteId) }
    }
    function openLink(link) {
        if (/^owelk:/.test(link) || /^https?:/.test(link)) controller.openLink(link)
    }
    // Replace the "[[" just typed (or insert at the cursor) with a Markdown link.
    function insertLink(kind, id) {
        const link = researchStore.markdownLink(kind, id)
        if (!link.length) return
        const at = body.cursorPosition
        const start = body.text.slice(Math.max(0, at - 2), at) === "[[" ? at - 2 : at
        body.remove(start, at)
        body.insert(start, link)
        body.cursorPosition = start + link.length
        body.forceActiveFocus()
    }
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 10
        RowLayout {
            Layout.fillWidth: true
            UiControls.TextField {
                id: titleField
                objectName: "noteTitle"
                Layout.fillWidth: true
                placeholderText: "Untitled note"
                font.pixelSize: 18
                background: Item {}
                onTextEdited: { root.dirty = true; autosave.restart() }
                onActiveFocusChanged: if (activeFocus) root.activated()
                Keys.onReturnPressed: { root.preview = false; body.forceActiveFocus() }
            }
            UiControls.ToolButton {
                objectName: "notePreviewToggle"
                text: root.preview ? "Edit" : "Preview"
                checkable: false
                onClicked: { root.save(); root.preview = !root.preview; if (!root.preview) body.forceActiveFocus() }
            }
            ReaderIconButton {
                objectName: "noteInsertLink"; kind: "link"; description: "Insert link to a paper, excerpt or note ([[)"
                onClicked: { root.preview = false; linkPicker.open() }
            }
            ReaderIconButton {
                description: "More"
                onClicked: noteMenu.popup(this, 0, height)
                UiControls.Menu {
                    id: noteMenu
                    UiControls.MenuItem { text: "Copy Markdown"; onTriggered: researchStore.copyText(body.text) }
                    UiControls.MenuItem {
                        objectName: "deleteNoteOption"
                        text: "Move Note to Trash"
                        palette.text: Theme.danger; palette.windowText: Theme.danger; palette.highlightedText: Theme.danger
                        onTriggered: { root.save(); const id = root.noteId; if (researchStore.deleteNote(id)) root.controller.closeNoteTabs(id) }
                    }
                }
            }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }
        ScrollView {
            Layout.fillWidth: true; Layout.fillHeight: true
            visible: !root.preview
            UiControls.TextArea {
                id: body
                objectName: "noteBody"
                placeholderText: "Write in Markdown. Type [[ to link a paper, excerpt or note."
                wrapMode: TextEdit.Wrap
                selectByMouse: true
                font.pixelSize: 14
                textFormat: TextEdit.PlainText
                background: Item {}
                onActiveFocusChanged: if (activeFocus) root.activated()
                onTextChanged: {
                    if (root.loading) return
                    root.dirty = true; autosave.restart()
                    if (focus && text.slice(Math.max(0, cursorPosition - 2), cursorPosition) === "[[") linkPicker.open()
                }
            }
        }
        ScrollView {
            Layout.fillWidth: true; Layout.fillHeight: true
            visible: root.preview
            Text {
                objectName: "notePreview"
                width: parent.width
                text: root.preview ? researchStore.markdownHtml(body.text.length ? body.text : "*Empty note*", Theme.accent) : ""
                textFormat: Text.RichText
                wrapMode: Text.Wrap
                font.pixelSize: 14
                color: Theme.textBody
                onLinkActivated: function(link) { root.openLink(link) }
                TapHandler { onDoubleTapped: { root.preview = false; body.forceActiveFocus() } }
                HoverHandler { cursorShape: parent.hoveredLink.length ? Qt.PointingHandCursor : Qt.IBeamCursor }
            }
        }
        ColumnLayout {
            objectName: "noteBacklinks"
            Layout.fillWidth: true
            visible: root.backlinks.length > 0
            spacing: 2
            Label { text: "Linked from"; font.pixelSize: 11; font.bold: true; color: Theme.textTertiary }
            Repeater {
                model: root.backlinks
                delegate: UiControls.ItemDelegate {
                    required property var modelData
                    Layout.fillWidth: true
                    text: modelData.title
                    font.pixelSize: 12
                    onClicked: root.openLink("owelk://" + modelData.kind + "/" + modelData.id)
                }
            }
        }
    }
    UiControls.Popup {
        id: linkPicker
        objectName: "noteLinkPicker"
        parent: root
        x: 16; y: 64
        width: Math.min(480, root.width - 32)
        padding: 8
        property var candidates: []
        onOpened: { linkQuery.text = ""; candidates = researchStore.linkCandidates(""); linkQuery.forceActiveFocus() }
        onClosed: body.forceActiveFocus()
        background: Rectangle { color: Theme.surfacePanel; border.color: Theme.borderPopup; radius: Theme.cornerRadius }
        contentItem: ColumnLayout {
            spacing: 6
            UiControls.TextField {
                id: linkQuery
                objectName: "noteLinkQuery"
                Layout.fillWidth: true
                placeholderText: "Link to… (paper title, excerpt text, note)"
                onTextChanged: linkPicker.candidates = researchStore.linkCandidates(text)
                Keys.onReturnPressed: if (linkPicker.candidates.length) { root.insertLink(linkPicker.candidates[0].kind, linkPicker.candidates[0].id); linkPicker.close() }
                Keys.onEscapePressed: linkPicker.close()
            }
            ListView {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(240, contentHeight)
                clip: true
                model: linkPicker.candidates
                delegate: UiControls.ItemDelegate {
                    required property var modelData
                    width: ListView.view.width
                    objectName: "noteLinkCandidate-" + modelData.kind + "-" + modelData.id
                    text: ({note: "Note", document: "Paper", capture: "Excerpt", highlight: "Annotation"})[modelData.kind] + " · " + modelData.title
                    font.pixelSize: 12
                    onClicked: { root.insertLink(modelData.kind, modelData.id); linkPicker.close() }
                }
            }
        }
    }
}
