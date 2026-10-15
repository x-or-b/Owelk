import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui

// A standalone Markdown note. Saves itself shortly after typing stops; [[ inserts a link to a
// paper, annotation or other note, and links open their source.
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
    // Notes sharing this note's key words; recomputed when it is opened or saved (local and quick).
    property var related: []
    signal activated()
    color: Theme.content
    function load() {
        loadedId = noteId
        researchStore.markOpened("note", noteId)
        const row = researchStore.note(noteId)
        loading = true
        titleField.text = row.title || ""
        body.text = row.body || ""
        loading = false
        dirty = false
        preview = (row.body || "").length > 0
        backlinks = researchStore.backlinks("note", noteId)
        related = researchStore.relatedNotes(noteId)
    }
    function save() {
        if (!dirty || !loadedId.length) return true
        if (!researchStore.saveNote(loadedId, titleField.text, body.text)) return false
        dirty = false
        savedMark.restart()
        controller.updateNoteTab(loadedId, titleField.text)
        related = researchStore.relatedNotes(loadedId)
        return true
    }
    // Done (or Esc): saved, the tab closes and the one before comes back (an empty note is not kept).
    // A syllable still being composed (Korean, Japanese, …) is committed first, so it is saved too.
    function done() { Qt.inputMethod.commit(); if (save()) controller.finishNote(loadedId) }
    Timer { id: savedMark; interval: 1500 }
    Shortcut {
        objectName: "noteDoneShortcut"
        sequence: "Escape"
        enabled: root.isActive && root.visible && !linkPicker.opened
        onActivated: root.done()
    }
    function focusTitle() { preview = false; titleField.forceActiveFocus() }
    function focusBody() { preview = false; body.cursorPosition = body.length; body.forceActiveFocus() }
    onNoteIdChanged: { save(); if (noteId.length) load() }
    Component.onDestruction: save()
    Timer { id: autosave; interval: 600; onTriggered: root.save() }
    Connections {
        target: researchStore
        // Text added from elsewhere (Link to Note…, an AI answer) while there are unsaved edits joins them,
        // so the next save keeps both; without edits the note simply reloads (below).
        function onNoteAppended(noteId, markdown) {
            if (!root.dirty || noteId !== root.loadedId) return
            const kept = body.text.replace(/\n+$/, "")
            body.text = kept + (kept.length ? "\n\n" : "") + markdown.trim() + "\n"
        }
        // A note rewritten as a whole (an AI proposal applied, or undone): typing not yet saved is saved
        // first, so Undo brings it back; the new text then loads below.
        function onNoteReplacing(noteId) { if (noteId === root.loadedId && root.dirty) root.save() }
        function onNotesChanged() {
            if (root.dirty || !root.noteId.length) return
            const row = researchStore.note(root.noteId)
            if (row.deleted) { root.controller.closeNoteTabs(root.noteId); return }
            root.loading = true
            if ((row.body || "") !== body.text) body.text = row.body || ""
            if ((row.title || "") !== titleField.text) { titleField.text = row.title || ""; root.controller.updateNoteTab(root.noteId, titleField.text) }
            root.loading = false
            root.dirty = false
        }
        function onLinksChanged() { root.backlinks = researchStore.backlinks("note", root.noteId) }
    }
    // The AI panel with this note attached: questions about it, or changes it can apply.
    function askAi() { Qt.inputMethod.commit(); save(); controller.aiRequested({attach: true, note: noteId}) }
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
            // Right-click the header for the note's actions (also in its tab's menu).
            TapHandler { acceptedButtons: Qt.RightButton; onTapped: noteMenu.popup() }
            Menu {
                id: noteMenu
                MenuItem { objectName: "noteAskAi"; text: qsTr("Ask AI about This Note"); onTriggered: root.askAi() }
                MenuItem { text: qsTr("Copy Markdown"); onTriggered: researchStore.copyText(body.text) }
                MenuSeparator {}
                MenuItem {
                    objectName: "deleteNoteOption"
                    text: qsTr("Move Note to Trash")
                    palette.windowText: Theme.danger
                    onTriggered: { root.save(); const id = root.noteId; if (researchStore.deleteNote(id)) root.controller.closeNoteTabs(id) }
                }
            }
            TextField {
                id: titleField
                objectName: "noteTitle"
                Layout.fillWidth: true
                placeholderText: qsTr("Untitled note")
                font.pixelSize: Theme.fontTitle
                background: Item {}
                onTextEdited: { root.dirty = true; autosave.restart() }
                onActiveFocusChanged: if (activeFocus) root.activated()
                Keys.onReturnPressed: { root.preview = false; body.forceActiveFocus() }
            }
            IconButton {
                objectName: "notePreviewToggle"
                icon.name: root.preview ? "edit" : "preview"
                description: root.preview ? qsTr("Edit") : qsTr("Preview")
                onClicked: { root.save(); root.preview = !root.preview; if (!root.preview) body.forceActiveFocus() }
            }
            IconButton {
                objectName: "noteInsertLink"; icon.name: "link"; description: qsTr("Insert link · [[")
                onClicked: { root.preview = false; linkPicker.open() }
            }
            IconButton {
                objectName: "noteAskAiButton"; icon.name: "ai"; description: qsTr("Ask AI about this note")
                onClicked: root.askAi()
            }
            // Saving is automatic; a quiet word says it happened.
            Label {
                objectName: "noteSaved"
                text: qsTr("Saved")
                opacity: savedMark.running ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 200 } }
                font.pixelSize: Theme.fontSmall; color: Theme.textTertiary
            }
            Button { objectName: "noteDone"; text: qsTr("Done"); onClicked: root.done() }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.separator }
        ScrollView {
            Layout.fillWidth: true; Layout.fillHeight: true
            visible: !root.preview
            TextArea {
                id: body
                objectName: "noteBody"
                placeholderText: qsTr("Write in Markdown. Type [[ to link a paper, annotation or note.")
                wrapMode: TextEdit.Wrap
                selectByMouse: true
                font.pixelSize: Theme.fontHeadline
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
                text: root.preview ? researchStore.markdownHtml(body.text.length ? body.text : qsTr("*Empty note*"), Theme.accent, Theme.text, Theme.fontHeadline, Theme.textTertiary) : ""
                textFormat: Text.RichText
                wrapMode: Text.Wrap
                font.pixelSize: Theme.fontHeadline
                color: Theme.text
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
            Label { text: qsTr("Linked from"); font.pixelSize: Theme.fontCaption; font.bold: true; color: Theme.textTertiary }
            Repeater {
                model: root.backlinks
                delegate: ItemDelegate {
                    required property var modelData
                    Layout.fillWidth: true
                    text: modelData.title
                    font.pixelSize: Theme.fontSmall
                    onClicked: root.openLink("owelk://" + modelData.kind + "/" + modelData.id)
                }
            }
        }
        ColumnLayout {
            objectName: "noteRelated"
            Layout.fillWidth: true
            visible: root.related.length > 0
            spacing: 2
            Label { text: qsTr("Related notes"); font.pixelSize: Theme.fontCaption; font.bold: true; color: Theme.textTertiary }
            Repeater {
                model: root.related
                delegate: ItemDelegate {
                    required property var modelData
                    Layout.fillWidth: true
                    text: modelData.title
                    font.pixelSize: Theme.fontSmall
                    onClicked: root.openLink("owelk://note/" + modelData.id)
                }
            }
        }
    }
    Popup {
        id: linkPicker
        objectName: "noteLinkPicker"
        parent: root
        x: 16; y: 64
        width: Math.min(480, root.width - 32)
        padding: 8
        property var candidates: []
        // The candidate Return links: the first of new results, moved with the arrow keys or the pointer.
        onCandidatesChanged: linkList.currentIndex = candidates.length ? 0 : -1
        function choose(index) {
            if (index < 0 || index >= candidates.length) return
            root.insertLink(candidates[index].kind, candidates[index].id)
            close()
        }
        function move(step) {
            if (!candidates.length) return
            linkList.currentIndex = Math.max(0, Math.min(candidates.length - 1, linkList.currentIndex + step))
            linkList.positionViewAtIndex(linkList.currentIndex, ListView.Contain)
        }
        onOpened: { linkQuery.text = ""; candidates = researchStore.linkCandidates(""); linkQuery.forceActiveFocus() }
        onClosed: body.forceActiveFocus()
        contentItem: ColumnLayout {
            spacing: 6
            TextField {
                id: linkQuery
                objectName: "noteLinkQuery"
                Layout.fillWidth: true
                placeholderText: qsTr("Link to… (paper title, annotation text, note)")
                // Looked up once typing pauses (it searches the library on this thread).
                onTextChanged: linkLookup.restart()
                Timer { id: linkLookup; interval: 150; onTriggered: linkPicker.candidates = researchStore.linkCandidates(linkQuery.text) }
                Keys.onReturnPressed: {
                    if (linkLookup.running) { linkLookup.stop(); linkLookup.triggered() }
                    linkPicker.choose(linkList.currentIndex)
                }
                Keys.onEnterPressed: Keys.returnPressed(event)
                Keys.onUpPressed: linkPicker.move(-1)
                Keys.onDownPressed: linkPicker.move(1)
                Keys.onEscapePressed: linkPicker.close()
            }
            ListView {
                id: linkList
                objectName: "noteLinkCandidates"
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(240, contentHeight)
                clip: true
                model: linkPicker.candidates
                highlightMoveDuration: 0
                delegate: ItemDelegate {
                    required property var modelData
                    required property int index
                    width: ListView.view.width
                    highlighted: ListView.isCurrentItem
                    onHoveredChanged: if (hovered) linkList.currentIndex = index
                    objectName: "noteLinkCandidate-" + modelData.kind + "-" + modelData.id
                    text: ({note: qsTr("Note"), document: qsTr("Paper"), highlight: qsTr("Annotation")})[modelData.kind] + " · " + modelData.title
                    font.pixelSize: Theme.fontSmall
                    onClicked: linkPicker.choose(index)
                }
            }
        }
    }
}
