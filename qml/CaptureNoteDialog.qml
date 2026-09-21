import "UiTheme.js" as Theme
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

UiControls.Dialog {
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
    function begin(id) {
        if (dirty) { open(); return }
        const item = researchStore.captures.find(function(c) { return c.id === id })
        if (!item) return
        capture = item; original = item.note || ""; editor.text = original; error = ""
        open()
    }
    function saveNote() {
        if (!researchStore.saveCaptureNote(capture.id, editor.text)) {
            error = "Could not save. Your draft is still here. Check storage and that the capture has not been deleted."
            return false
        }
        original = editor.text; error = ""
        return true
    }
    function requestClose() { if (dirty) discardDialog.open(); else close() }
    onOpened: editor.forceActiveFocus()
    contentItem: ColumnLayout {
        spacing: 10
        Label {
            Layout.fillWidth: true
            text: (root.capture.name || "") + " · p. " + (Number(root.capture.page || 0) + 1)
            textFormat: Text.PlainText; elide: Text.ElideMiddle; color: "#555555"
        }
        Label { text: "Source capture · read-only"; color: "#666666"; font.pixelSize: 11 }
        ScrollView {
            visible: root.capture.kind === "text"
            Layout.fillWidth: true; Layout.preferredHeight: 110
            UiControls.TextArea {
                objectName: "noteSourceText"
                text: root.capture.text || ""; textFormat: TextEdit.PlainText
                readOnly: true; selectByMouse: true; wrapMode: TextEdit.Wrap
                color: "#444444"
                background: Rectangle { color: "#eeeeee"; border.color: "#d2d2d2" }
            }
        }
        Image {
            visible: root.capture.kind === "region"
            Layout.fillWidth: true; Layout.preferredHeight: 110
            source: root.capture.image || ""; sourceSize.width: 600
            fillMode: Image.PreserveAspectFit; asynchronous: true
        }
        Label { text: "Your note"; font.bold: true; color: "#333333" }
        ScrollView {
            Layout.fillWidth: true; Layout.fillHeight: true
            UiControls.TextArea {
                id: editor
                objectName: "captureNoteEditor"
                placeholderText: "Your interpretation, questions, or comparison with another paper…"
                textFormat: TextEdit.PlainText; selectByMouse: true; wrapMode: TextEdit.Wrap
                color: "#333333"
                background: Rectangle { color: "#ffffff"; border.color: editor.activeFocus ? "#8296ac" : "#b5b5b5"; radius: Theme.cornerRadius }
                Keys.onEscapePressed: root.requestClose()
            }
        }
        Label { text: (root.dirty ? "Unsaved · " : "") + editor.text.length + " / 10,000 characters"; color: editor.text.length > 10000 ? "#b42323" : "#777777"; font.pixelSize: 11 }
        Label { Layout.fillWidth: true; visible: root.error.length > 0; text: root.error; wrapMode: Text.Wrap; color: "#b42323" }
        RowLayout {
            Layout.fillWidth: true
            UiControls.Button {
                objectName: "deleteCaptureNote"
                text: "Delete note"; visible: root.original.trim().length > 0
                palette.buttonText: "#b42323"
                onClicked: deleteDialog.open()
            }
            UiControls.Button {
                text: "View source"
                onClicked: {
                    if (root.dirty && !root.saveNote()) return
                    root.close(); researchStore.openCapture(root.capture.id)
                }
                ToolTip.visible: hovered; ToolTip.text: "Save any edits and view the original PDF"
            }
            Item { Layout.fillWidth: true }
            UiControls.Button { objectName: "cancelCaptureNote"; text: "Cancel"; onClicked: root.requestClose() }
            UiControls.Button { objectName: "saveCaptureNote"; text: "Save"; enabled: editor.text.length <= 10000; onClicked: if (root.saveNote()) root.close() }
        }
    }
    UiControls.Dialog {
        id: discardDialog
        objectName: "discardNoteDialog"
        parent: Overlay.overlay; anchors.centerIn: parent
        title: "Discard unsaved edits?"; modal: true
        standardButtons: Dialog.Discard | Dialog.Cancel
        Label { text: "The previously saved note will be kept." }
        onDiscarded: { editor.text = root.original; root.close(); close() }
    }
    UiControls.Dialog {
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
