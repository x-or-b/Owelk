import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    property string side: "left"
    property var panels: []
    property string activePanel: panels.length ? panels[0] : ""
    property url folder
    signal closePanel(string panel)
    signal documentChosen(url source)
    signal folderChosen(url folder)
    color: "#f7f7f7"
    border.color: "#dddddd"
    onPanelsChanged: if (panels.indexOf(activePanel) < 0) activePanel = panels.length ? panels[0] : ""
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 1
        spacing: 0
        RowLayout {
            Layout.fillWidth: true
            spacing: 0
            Repeater {
                model: root.panels
                delegate: Rectangle {
                    required property string modelData
                    Layout.preferredWidth: modelData === "files" ? 55 : 78
                    Layout.preferredHeight: 34
                    color: root.activePanel === modelData ? "#e9e9e9" : "transparent"
                    Label { anchors.centerIn: parent; text: modelData === "files" ? "Files" : "Captures"; font.pixelSize: 12 }
                    TapHandler { onTapped: root.activePanel = modelData }
                }
            }
            Item { Layout.fillWidth: true }
            ToolButton { objectName: "closePanel"; text: "×"; onClicked: root.closePanel(root.activePanel); Accessible.name: "Close panel" }
        }
        Loader {
            Layout.fillWidth: true
            Layout.fillHeight: true
            sourceComponent: root.activePanel === "files" ? files : root.activePanel === "captures" ? captures : null
        }
    }
    Component {
        id: files
        FilePanel {
            folder: root.folder
            onDocumentChosen: function(source) { root.documentChosen(source) }
            onFolderChosen: function(folder) { root.folderChosen(folder) }
        }
    }
    Component { id: captures; CaptureShelf {} }
}
