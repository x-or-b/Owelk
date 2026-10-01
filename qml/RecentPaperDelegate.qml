import QtQuick
import QtQuick.Controls

UiControls.ItemDelegate {
    id: root
    required property var modelData
    objectName: "recentPaper-" + modelData.url.toString()
    signal documentChosen(url source, var position)
    text: (modelData.favorite ? "★ " : "") + modelData.name
    opacity: modelData.readingState === "read" ? .65 : 1
    onClicked: documentChosen(modelData.url, modelData.position)
    ToolTip.visible: hovered
    ToolTip.delay: 450
    ToolTip.text: (modelData.fileName && modelData.fileName !== modelData.name ? modelData.fileName + "\n" : "")
        + modelData.url.toString() + "\nRight-click for details or to remove from Recent Papers"
    MouseArea { anchors.fill: parent; acceptedButtons: Qt.RightButton; onClicked: menu.popup() }
    UiControls.Menu {
        id: menu; objectName: "recentPaperMenu"
        UiControls.MenuItem { objectName: "recentPaperDetails"; text: "Paper Details…"; onTriggered: { details.active = true; details.item.begin(root.modelData.url) } }
        UiControls.MenuItem {
            objectName: "recentPaperReadState"
            text: root.modelData.readingState === "read" ? "Mark as Unread" : "Mark as Read"
            onTriggered: researchStore.setReadingState(root.modelData.url, root.modelData.readingState === "read" ? "unread" : "read")
        }
        UiControls.MenuItem {
            text: root.modelData.favorite ? "Remove from Favorites" : "Add to Favorites"
            onTriggered: researchStore.setFavorite(root.modelData.url, !root.modelData.favorite)
        }
        UiControls.MenuItem { text: "Locate Original PDF…"; onTriggered: researchStore.requestRelink(root.modelData.url) }
        UiControls.MenuItem { objectName: "removeRecentOption"; text: "Remove from Recent Papers…"; onTriggered: confirmation.open() }
    }
    Loader { id: details; active: false; sourceComponent: PaperDetailsDialog {} }
    UiControls.Dialog {
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
