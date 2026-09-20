import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    objectName: "captureShelf"
    color: "#fafafa"
    property string deletingId: ""
    function requestDelete(id) { deletingId = id; deleteDialog.open() }
    Dialog {
        id: deleteDialog
        objectName: "deleteCaptureDialog"
        parent: Overlay.overlay
        anchors.centerIn: parent
        title: "Delete capture?"
        width: 370
        modal: true
        standardButtons: Dialog.Ok | Dialog.Cancel
        Label { width: 310; wrapMode: Text.Wrap; text: "This capture will be moved to local trash. The original PDF will be kept." }
        onAccepted: { const id = root.deletingId; Qt.callLater(function() { researchStore.deleteCapture(id) }) }
    }
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 12
        RowLayout {
            Layout.fillWidth: true
            Label { text: researchStore.captures.length + " saved"; font.pixelSize: 12; color: "#666666" }
            Item { Layout.fillWidth: true }
        }
        Label {
            Layout.fillWidth: true
            text: "Select a capture to return to its source."
            wrapMode: Text.Wrap
            color: "#666666"
            font.pixelSize: 11
        }
        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 12
            clip: true
            model: researchStore.captures
            ScrollBar.vertical: ScrollBar {}
            delegate: ItemDelegate {
                id: card
                required property var modelData
                width: list.width
                height: preview.height + 67
                padding: 10
                onClicked: researchStore.openCapture(modelData.id)
                MouseArea { anchors.fill: parent; acceptedButtons: Qt.RightButton; onClicked: captureMenu.popup() }
                Menu {
                    id: captureMenu
                    MenuItem { text: "Locate Original PDF…"; onTriggered: researchStore.requestRelink(card.modelData.source) }
                    MenuItem { text: "Delete Capture…"; onTriggered: root.requestDelete(card.modelData.id) }
                }
                ToolButton {
                    anchors.right: parent.right; anchors.bottom: parent.bottom
                    width: 28; height: 28; text: "…"
                    Accessible.name: "Capture actions"
                    onClicked: captureMenu.popup()
                }
                background: Rectangle {
                    color: card.hovered ? "#eeeeee" : "white"
                    border.color: "#dddddd"
                    radius: 2
                }
                contentItem: Column {
                    spacing: 7
                    Image {
                        id: preview
                        width: parent.width
                        height: Math.min(155, width / Math.max(.4, implicitWidth / Math.max(1, implicitHeight)))
                        source: card.modelData.image
                        sourceSize.width: 520
                        asynchronous: true
                        fillMode: Image.PreserveAspectFit
                    }
                    Label {
                        width: parent.width
                        text: card.modelData.name
                        elide: Text.ElideMiddle
                        font.pixelSize: 11
                        color: "#444444"
                    }
                    Label { text: "p. " + (card.modelData.page + 1) + "  ·  View source"; font.pixelSize: 11; color: "#555555" }
                }
            }
            Label {
                anchors.centerIn: parent
                width: parent.width - 16
                visible: list.count === 0
                text: "No saved captures.\nUse Capture region in a document."
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                lineHeight: 1.5
                color: "#777777"
            }
        }
    }
}
