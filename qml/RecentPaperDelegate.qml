import QtQuick
import QtQuick.Controls

ItemDelegate {
    id: root
    required property var modelData
    objectName: "recentPaper-" + modelData.url.toString()
    signal documentChosen(url source, var position)
    text: modelData.name
    onClicked: documentChosen(modelData.url, modelData.position)
    ToolTip.visible: hovered
    ToolTip.delay: 450
    ToolTip.text: modelData.url.toString() + "\nRight-click to remove from Recent Papers"
    MouseArea { anchors.fill: parent; acceptedButtons: Qt.RightButton; onClicked: menu.popup() }
    Menu { id: menu; objectName: "recentPaperMenu"; MenuItem { objectName: "removeRecentOption"; text: "Remove from Recent Papers…"; onTriggered: confirmation.open() } }
    Dialog {
        id: confirmation
        objectName: "removeRecentDialog"
        parent: Overlay.overlay
        anchors.centerIn: parent
        title: "Remove from Recent Papers?"
        width: 390
        modal: true
        standardButtons: Dialog.Ok | Dialog.Cancel
        Label { text: "The original PDF, open tabs and captures will be kept."; wrapMode: Text.Wrap; width: 330 }
        onAccepted: { const source = root.modelData.url; Qt.callLater(function() { researchStore.removeRecentDocument(source) }) }
    }
}
