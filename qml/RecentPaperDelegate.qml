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
    signal menuRequested(var row)
    MouseArea { anchors.fill: parent; acceptedButtons: Qt.RightButton; onClicked: root.menuRequested(root.modelData) }
}
