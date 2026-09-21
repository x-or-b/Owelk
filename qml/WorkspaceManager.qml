import "UiTheme.js" as Theme
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs as Native

UiControls.Dialog {
    id: root
    objectName: "workspaceManager"
    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(720, parent ? parent.width - 32 : 720)
    height: Math.min(650, parent ? parent.height - 32 : 650)
    title: "Workspace links"
    modal: true
    standardButtons: Dialog.Close
    property string workspaceId: ""
    property var details: ({})
    property url currentSource: ""
    property string error: ""
    property int mode: 0
    readonly property var availableCaptures: researchStore.captures.filter(function(c) {
        return !(root.details.captures || []).some(function(link) { return link.id === c.id })
    })
    signal documentChosen(url source)
    signal noteRequested(string id)
    signal deleteRequested(string id)
    function refresh() {
        const next = researchStore.workspaceDetails(workspaceId)
        if (JSON.stringify(next) !== JSON.stringify(details)) details = next
    }
    function begin(id) { workspaceId = id; refresh(); if (!details.id) return; nameField.text = details.name; error = ""; open() }
    function linkDocument(source, linked) {
        error = researchStore.setWorkspaceDocument(workspaceId, source, linked) ? "" : "Could not update the document link."
    }
    function linkCapture(id, linked) {
        error = researchStore.setWorkspaceCapture(workspaceId, id, linked) ? "" : "Could not update the capture link."
    }
    Connections { target: researchStore; function onHomeChanged() { if (root.visible) root.refresh() } }
    contentItem: ColumnLayout {
        spacing: 10
        RowLayout {
            Layout.fillWidth: true
            UiControls.TextField { id: nameField; objectName: "workspaceNameEditor"; Layout.fillWidth: true; maximumLength: 120; selectByMouse: true }
            UiControls.Button {
                objectName: "renameWorkspaceButton"; text: "Rename"
                enabled: nameField.text.trim().length > 0 && nameField.text.trim() !== root.details.name
                onClicked: root.error = researchStore.renameWorkspace(root.workspaceId, nameField.text) ? "" : "Could not rename this workspace."
            }
        }
        RowLayout {
            UiControls.Button { text: "Documents (" + (root.details.documents || []).length + ")"; checkable: true; checked: root.mode === 0; onClicked: root.mode = 0 }
            UiControls.Button { text: "Captures (" + (root.details.captures || []).length + ")"; checkable: true; checked: root.mode === 1; onClicked: root.mode = 1 }
            Item { Layout.fillWidth: true }
        }
        Label {
            Layout.fillWidth: true
            text: "Unlink only removes the association. PDFs, captures, notes and open tabs are kept."
            wrapMode: Text.Wrap; color: "#666666"; font.pixelSize: 12
        }
        RowLayout {
            visible: root.mode === 0
            UiControls.Button { objectName: "linkCurrentDocument"; text: "Link current PDF"; enabled: root.currentSource.toString().length > 0; onClicked: root.linkDocument(root.currentSource, true) }
            UiControls.Button { text: "Link PDF…"; onClicked: pdfPicker.open() }
        }
        RowLayout {
            visible: root.mode === 1; Layout.fillWidth: true
            UiControls.ComboBox {
                id: capturePicker; objectName: "workspaceCapturePicker"
                Layout.fillWidth: true
                textRole: "label"
                model: root.availableCaptures.map(function(c) { return {id: c.id, label: c.name + " · p. " + (Number(c.page) + 1) + " · " + (c.text || c.note || "Region capture").slice(0, 90)} })
                contentItem: Text { text: capturePicker.displayText; textFormat: Text.PlainText; color: "#333333"; elide: Text.ElideRight; verticalAlignment: Text.AlignVCenter }
                delegate: UiControls.ItemDelegate {
                    required property var modelData
                    required property int index
                    width: capturePicker.width; highlighted: capturePicker.highlightedIndex === index
                    background: Rectangle { color: highlighted ? "#dedede" : "#fafafa" }
                    contentItem: Text { text: modelData.label; textFormat: Text.PlainText; color: "#333333"; elide: Text.ElideMiddle; verticalAlignment: Text.AlignVCenter }
                }
            }
            UiControls.Button { objectName: "linkCaptureButton"; text: "Link capture"; enabled: capturePicker.currentIndex >= 0 && root.availableCaptures.length > 0; onClicked: root.linkCapture(root.availableCaptures[capturePicker.currentIndex].id, true) }
        }
        ListView {
            id: list; objectName: "workspaceLinksList"
            Layout.fillWidth: true; Layout.fillHeight: true
            model: root.mode === 0 ? root.details.documents || [] : root.details.captures || []
            clip: true; spacing: 4
            ScrollBar.vertical: ScrollBar {}
            delegate: Rectangle {
                required property var modelData
                width: list.width; height: root.mode === 0 ? 62 : 94
                color: "#f0f0f0"; border.color: "#dedede"; radius: Theme.cornerRadius
                RowLayout {
                    anchors.fill: parent; anchors.margins: 8
                    ColumnLayout {
                        Layout.fillWidth: true
                        Label { Layout.fillWidth: true; text: modelData.name; textFormat: Text.PlainText; elide: Text.ElideMiddle; color: "#333333" }
                        Label {
                            Layout.fillWidth: true
                            text: root.mode === 0 ? modelData.source.toString() : "p. " + (Number(modelData.page) + 1) + " · " + (modelData.text || "Region capture")
                            textFormat: Text.PlainText; elide: Text.ElideRight; color: "#666666"; font.pixelSize: 11
                        }
                        Label { Layout.fillWidth: true; visible: root.mode === 1 && !!modelData.note; text: "Note · " + (modelData.note || ""); textFormat: Text.PlainText; elide: Text.ElideRight; font.pixelSize: 11; color: "#555555" }
                    }
                    UiControls.ToolButton { text: "Open"; onClicked: { root.close(); if (root.mode === 0) root.documentChosen(modelData.source); else researchStore.openCapture(modelData.id) } }
                    UiControls.ToolButton { visible: root.mode === 1; text: "Note"; onClicked: { root.close(); root.noteRequested(modelData.id) } }
                    UiControls.ToolButton { objectName: "unlinkWorkspaceItem"; text: "Unlink"; onClicked: { if (root.mode === 0) root.linkDocument(modelData.source, false); else root.linkCapture(modelData.id, false) } }
                }
            }
            Label { anchors.centerIn: parent; visible: list.count === 0; text: root.mode === 0 ? "No linked documents" : "No linked captures"; color: "#777777" }
        }
        Label { Layout.fillWidth: true; visible: root.error.length > 0; text: root.error; wrapMode: Text.Wrap; color: "#b42323" }
        UiControls.Button { objectName: "deleteWorkspaceButton"; text: "Delete workspace…"; palette.buttonText: "#b42323"; onClicked: deleteDialog.open() }
    }
    Native.FileDialog {
        id: pdfPicker; title: "Link PDF to workspace"; nameFilters: ["PDF files (*.pdf)"]
        onAccepted: root.linkDocument(selectedFile, true)
    }
    UiControls.Dialog {
        id: deleteDialog; objectName: "deleteWorkspaceDialog"
        parent: Overlay.overlay; anchors.centerIn: parent
        title: "Delete workspace?"; modal: true; standardButtons: Dialog.Ok | Dialog.Cancel
        Label { width: 360; wrapMode: Text.Wrap; text: "This workspace will leave your lists. PDFs, captures, notes and open tabs are kept. The saved workspace layout is archived locally." }
        onAccepted: root.deleteRequested(root.workspaceId)
    }
}
