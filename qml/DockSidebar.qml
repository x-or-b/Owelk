import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    property string side: "left"
    property var panels: []
    property string activePanel: panels.length ? panels[0] : ""
    property url folder
    property var reader: null
    property int navigationMode: 0
    signal navigationModeChosen(int mode)
    signal documentChosen(url source)
    signal folderChosen(url folder)
    signal noteRequested(string id)
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
                    Layout.fillWidth: true
                    Layout.minimumWidth: modelData === "files" ? 48 : 74
                    Layout.preferredHeight: 34
                    color: root.activePanel === modelData ? "#e9e9e9" : "transparent"
                    Label { anchors.centerIn: parent; text: modelData === "files" ? "Files" : modelData === "captures" ? "Captures" : "Document"; font.pixelSize: 12 }
                    TapHandler { onTapped: root.activePanel = modelData }
                }
            }
        }
        Loader {
            Layout.fillWidth: true
            Layout.fillHeight: true
            sourceComponent: root.activePanel === "files" ? files : root.activePanel === "captures" ? captures : root.activePanel === "document" ? navigation : null
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
    Component { id: captures; CaptureShelf { onNoteRequested: function(id) { root.noteRequested(id) } } }
    Component {
        id: navigation
        PdfNavigationPanel {
            reader: root.reader
            mode: root.navigationMode
            onModeChosen: function(mode) { root.navigationModeChosen(mode) }
        }
    }
}
