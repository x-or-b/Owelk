import Owelk.Ui
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Dialog {
    id: root
    objectName: "captureNoteDialog"
    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(640, parent ? parent.width - 32 : 640)
    height: Math.min(610, parent ? parent.height - 32 : 610)
    modal: true
    closePolicy: Popup.NoAutoClose
    title: "Capture note"
    property var capture: ({})
    property string original: ""
    property string error: ""
    readonly property bool dirty: editor.text !== original
    // Unsaved text survives a crash: it is kept as a draft and offered the next time.
    readonly property string draftKey: capture.id ? "capture-note:" + capture.id : ""
    property string savedDraft: ""
    Timer { id: draftTimer; interval: 1000; onTriggered: if (root.dirty) researchStore.saveDraft(root.draftKey, editor.text) }
    function begin(id) {
        if (dirty) { open(); return }
        const item = researchStore.captures.find(function(c) { return c.id === id })
        if (!item) return
        capture = item; original = item.note || ""; editor.text = original; error = ""
        const kept = researchStore.draft(draftKey)
        savedDraft = kept.length && kept !== original ? kept : ""
        open()
    }
    function saveNote() {
        if (!researchStore.saveCaptureNote(capture.id, editor.text)) {
            error = "Could not save. Your draft is still here. Check storage and that the capture has not been deleted."
            return false
        }
        original = editor.text; error = ""
        researchStore.clearDraft(draftKey); savedDraft = ""
        return true
    }
    function requestClose() { if (dirty) discardDialog.open(); else close() }
    onOpened: editor.forceActiveFocus()
    contentItem: ColumnLayout {
        spacing: 10
        Label {
            Layout.fillWidth: true
            text: (root.capture.name || "") + " · p. " + (Number(root.capture.page || 0) + 1)
            textFormat: Text.PlainText; elide: Text.ElideMiddle; color: Theme.textSecondary
        }
        Label { text: "Source capture · read-only"; color: Theme.textTertiary; font.pixelSize: Theme.fontCaption }
        ScrollView {
            visible: root.capture.kind === "text"
            Layout.fillWidth: true; Layout.preferredHeight: 110
            TextArea {
                objectName: "noteSourceText"
                text: root.capture.text || ""; textFormat: TextEdit.PlainText
                readOnly: true; selectByMouse: true; wrapMode: TextEdit.Wrap
                color: Theme.textSecondary
            }
        }
        Image {
            visible: root.capture.kind === "region"
            Layout.fillWidth: true; Layout.preferredHeight: 110
            source: root.capture.image || ""; sourceSize.width: 600
            fillMode: Image.PreserveAspectFit; asynchronous: true
        }
        Label { text: "Your note"; font.bold: true; color: Theme.text }
        RowLayout {
            objectName: "captureNoteDraftBar"
            visible: root.savedDraft.length > 0
            Layout.fillWidth: true
            Label { Layout.fillWidth: true; text: "Unsaved text from last time is kept."; color: Theme.textSecondary; font.pixelSize: Theme.fontSmall }
            Button { objectName: "restoreCaptureNoteDraft"; text: "Restore"; onClicked: { editor.text = root.savedDraft; root.savedDraft = "" } }
            Button { text: "Discard"; onClicked: { researchStore.clearDraft(root.draftKey); root.savedDraft = "" } }
        }
        ScrollView {
            Layout.fillWidth: true; Layout.fillHeight: true
            TextArea {
                id: editor
                objectName: "captureNoteEditor"
                placeholderText: "Your interpretation, questions, or comparison with another paper…"
                textFormat: TextEdit.PlainText; selectByMouse: true; wrapMode: TextEdit.Wrap
                color: Theme.text
                Keys.onEscapePressed: root.requestClose()
                onTextChanged: if (root.opened) draftTimer.restart()
            }
        }
        Label { text: (root.dirty ? "Unsaved · " : "") + editor.text.length + " / 10,000 characters"; color: editor.text.length > 10000 ? Theme.danger : Theme.textTertiary; font.pixelSize: Theme.fontCaption }
        Label { Layout.fillWidth: true; visible: root.error.length > 0; text: root.error; wrapMode: Text.Wrap; color: Theme.danger }
        RowLayout {
            Layout.fillWidth: true
            Button {
                objectName: "deleteCaptureNote"
                text: "Delete note"; visible: root.original.trim().length > 0
                palette.buttonText: Theme.danger
                onClicked: deleteDialog.open()
            }
            Button {
                text: "View source"
                onClicked: {
                    if (root.dirty && !root.saveNote()) return
                    root.close(); researchStore.openCapture(root.capture.id)
                }
                ToolTip.visible: hovered; ToolTip.text: "Save any edits and view the original PDF"
            }
            Item { Layout.fillWidth: true }
            Button { objectName: "cancelCaptureNote"; text: "Cancel"; onClicked: root.requestClose() }
            Button { objectName: "saveCaptureNote"; text: "Save"; enabled: editor.text.length <= 10000; onClicked: if (root.saveNote()) root.close() }
        }
    }
    Dialog {
        id: discardDialog
        objectName: "discardNoteDialog"
        parent: Overlay.overlay; anchors.centerIn: parent
        title: "Discard unsaved edits?"; modal: true
        standardButtons: Dialog.Discard | Dialog.Cancel
        Label { text: "The previously saved note will be kept." }
        onDiscarded: { researchStore.clearDraft(root.draftKey); editor.text = root.original; root.close(); close() }
    }
    Dialog {
        id: deleteDialog
        objectName: "deleteNoteDialog"
        parent: Overlay.overlay; anchors.centerIn: parent
        title: "Delete this note?"; modal: true
        standardButtons: Dialog.Ok | Dialog.Cancel
        Label { text: "Only the note will be removed. The source capture will be kept." }
        onAccepted: {
            if (researchStore.saveCaptureNote(root.capture.id, "")) { root.original = ""; editor.text = ""; root.close() }
            else root.error = "Could not delete the note. Your draft is still here."
        }
    }
}
