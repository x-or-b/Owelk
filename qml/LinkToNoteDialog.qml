import Owelk.Ui
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Add a link to a capture, annotation or paper at the end of a note (or in a new note).
UiControls.Dialog {
    id: root
    objectName: "linkToNoteDialog"
    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(440, parent ? parent.width - 32 : 440)
    title: "Link to note"
    modal: true
    standardButtons: Dialog.Cancel
    property string kind: ""
    property string targetId: ""
    property var noteRows: []
    function begin(targetKind, id) {
        kind = targetKind; targetId = id
        noteRows = researchStore.notes(false)
        open()
    }
    ColumnLayout {
        width: parent.width
        spacing: 6
        Label {
            Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
            text: researchStore.linkTarget(root.kind, root.targetId).title || ""
            font.pixelSize: 12; color: Theme.textTertiary
        }
        UiControls.Button {
            objectName: "linkToNewNote"
            text: "New Note with This Link"
            onClicked: {
                const link = researchStore.markdownLink(root.kind, root.targetId)
                if (researchStore.createNote("", "- " + link + "\n").length) researchStore.notify("Linked in a new note.")
                root.close()
            }
        }
        ListView {
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(260, contentHeight)
            clip: true
            model: root.noteRows
            delegate: UiControls.ItemDelegate {
                required property var modelData
                width: ListView.view.width
                objectName: "linkToNote-" + modelData.id
                text: modelData.title
                onClicked: { researchStore.appendNoteLink(modelData.id, root.kind, root.targetId); root.close() }
            }
        }
        Label { visible: root.noteRows.length === 0; text: "No notes yet."; color: Theme.textTertiary }
    }
}
