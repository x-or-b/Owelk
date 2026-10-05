import QtQuick
import QtQuick.Controls
import Owelk.Ui

ItemDelegate {
    id: root
    required property var modelData
    objectName: "recentPaper-" + modelData.url.toString()
    signal documentChosen(url source, var position)
    text: modelData.name
    rightPadding: modelData.favorite ? 30 : 10
    // Read papers are quieter; favorites carry a star.
    opacity: modelData.readingState === "read" ? .65 : 1
    Icon { visible: root.modelData.favorite; anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter; name: "star"; size: Theme.fontBody; color: Theme.accent }
    onClicked: documentChosen(modelData.url, modelData.position)
    ToolTip.visible: hovered
    ToolTip.delay: 500
    ToolTip.text: modelData.name + "\n" + researchStore.localPath(modelData.url)
    MouseArea { anchors.fill: parent; acceptedButtons: Qt.RightButton; onClicked: menu.popup() }
    Menu {
        id: menu; objectName: "recentPaperMenu"
        MenuItem { objectName: "recentPaperDetails"; text: "Paper Details…"; onTriggered: { details.active = true; details.item.begin(root.modelData.url) } }
        MenuItem {
            objectName: "recentPaperReadState"
            text: root.modelData.readingState === "read" ? "Mark as Unread" : "Mark as Read"
            onTriggered: researchStore.setReadingState(root.modelData.url, root.modelData.readingState === "read" ? "unread" : "read")
        }
        MenuItem {
            text: root.modelData.favorite ? "Remove from Favorites" : "Add to Favorites"
            onTriggered: researchStore.setFavorite(root.modelData.url, !root.modelData.favorite)
        }
        MenuItem { text: "Locate Original PDF…"; onTriggered: researchStore.requestRelink(root.modelData.url) }
        MenuItem { objectName: "removeRecentOption"; text: "Remove from Recent Papers…"; onTriggered: confirmation.open() }
    }
    Loader { id: details; active: false; sourceComponent: PaperDetailsDialog {} }
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
