import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    objectName: "captureShelf"
    color: "#fafafa"
    property string deletingId: ""
    property var viewingCapture: ({})
    function requestDelete(id) { deletingId = id; deleteDialog.open() }
    function viewText(capture) { viewingCapture = capture; textDialog.open() }
    Dialog {
        id: textDialog
        objectName: "excerptDialog"
        parent: Overlay.overlay
        anchors.centerIn: parent
        title: "Text excerpt"
        width: Math.min(600, parent.width - 32)
        height: Math.min(540, parent.height - 32)
        modal: true
        standardButtons: Dialog.Close
        ColumnLayout {
            anchors.fill: parent
            spacing: 12
            Label {
                Layout.fillWidth: true
                text: (root.viewingCapture.name || "") + " · p. " + (Number(root.viewingCapture.page || 0) + 1)
                textFormat: Text.PlainText
                elide: Text.ElideMiddle
                color: "#666666"
            }
            ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                TextArea {
                    objectName: "excerptText"
                    text: root.viewingCapture.text || ""
                    textFormat: TextEdit.PlainText
                    readOnly: true
                    selectByMouse: true
                    wrapMode: TextEdit.Wrap
                    background: Rectangle { color: "#f5f5f5"; border.color: "#dddddd" }
                }
            }
            RowLayout {
                Button { objectName: "copyExcerptButton"; text: "Copy text"; onClicked: researchStore.copyText(root.viewingCapture.text) }
                Button {
                    text: "View source"
                    onClicked: { textDialog.close(); researchStore.openCapture(root.viewingCapture.id) }
                }
            }
        }
    }
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
                objectName: "captureCard-" + modelData.id
                width: list.width
                height: contentItem.implicitHeight + 20
                padding: 10
                onClicked: researchStore.openCapture(modelData.id)
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.RightButton
                    onClicked: function(mouse) { captureMenu.popup(card, mouse.x, mouse.y) }
                }
                Menu {
                    id: captureMenu
                    objectName: "captureMenu-" + card.modelData.id
                    MenuItem { objectName: "readExcerpt-" + card.modelData.id; text: "Read Excerpt…"; visible: card.modelData.kind === "text"; height: visible ? implicitHeight : 0; onTriggered: root.viewText(card.modelData) }
                    MenuItem { text: "Copy Text"; visible: card.modelData.kind === "text"; height: visible ? implicitHeight : 0; onTriggered: researchStore.copyText(card.modelData.text) }
                    MenuItem { text: "Locate Original PDF…"; onTriggered: researchStore.requestRelink(card.modelData.source) }
                    MenuItem {
                        text: "Delete"
                        palette.text: "#b42323"
                        palette.windowText: "#b42323"
                        palette.highlightedText: "#b42323"
                        onTriggered: root.requestDelete(card.modelData.id)
                    }
                }
                ToolButton {
                    id: captureActions
                    objectName: "captureActions-" + card.modelData.id
                    anchors.right: parent.right; anchors.bottom: parent.bottom
                    width: 28; height: 28; text: "…"
                    Accessible.name: "Capture actions"
                    onClicked: captureMenu.popup(captureActions, 0, captureActions.height)
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
                        visible: card.modelData.kind !== "text"
                        width: parent.width
                        height: Math.min(155, width / Math.max(.4, implicitWidth / Math.max(1, implicitHeight)))
                        source: card.modelData.image
                        sourceSize.width: 520
                        asynchronous: true
                        fillMode: Image.PreserveAspectFit
                    }
                    Label {
                        objectName: "excerptPreview"
                        visible: card.modelData.kind === "text"
                        width: parent.width
                        text: card.modelData.text || ""
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        maximumLineCount: 6
                        elide: Text.ElideRight
                        font.pixelSize: 13
                        color: "#333333"
                    }
                    Label {
                        width: parent.width
                        text: card.modelData.name
                        textFormat: Text.PlainText
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
                text: "No saved captures.\nSelect text and Save excerpt,\nor use Capture region."
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                lineHeight: 1.5
                color: "#777777"
            }
        }
    }
}
