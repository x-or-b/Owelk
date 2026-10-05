import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui

Rectangle {
    id: root
    property string side: "left"
    property var panels: []
    property string activePanel: panels.length ? panels[0] : ""
    property url folder
    property var reader: null
    property var aiController: null
    property int navigationMode: 0
    signal navigationModeChosen(int mode)
    signal documentChosen(url source)
    signal folderChosen(url folder)
    signal noteRequested(string id)
    signal linkActivated(string link)
    signal aiRequested(var spec)
    signal settingsRequested()
    function panelName(panel) { return panel === "files" ? "Files" : panel === "captures" ? "Captures" : panel === "ai" ? "AI" : panel === "document" ? "Document" : "" }
    color: Theme.sidebar
    border.color: Theme.separator
    radius: Theme.radius
    onPanelsChanged: if (panels.indexOf(activePanel) < 0) activePanel = panels.length ? panels[0] : ""
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 1
        spacing: 0
        // One panel: its name. Several: a segmented control of their icons.
        Label {
            visible: root.panels.length === 1
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.barHeight
            leftPadding: 12
            verticalAlignment: Text.AlignVCenter
            text: root.panelName(root.activePanel)
            font.pixelSize: Theme.fontSmall
            font.weight: Font.DemiBold
            color: Theme.textSecondary
        }
        TabBar {
            objectName: "dockTabs"
            visible: root.panels.length > 1
            Layout.fillWidth: true
            Layout.margins: 6
            Layout.bottomMargin: 2
            currentIndex: root.panels.indexOf(root.activePanel)
            Repeater {
                model: root.panels
                delegate: TabButton {
                    required property string modelData
                    objectName: "dockTab-" + modelData
                    icon.name: ({files: "folder", captures: "capture", document: "document", ai: "ai"})[modelData]
                    ToolTip.text: root.panelName(modelData)
                    onClicked: root.activePanel = modelData
                }
            }
        }
        Loader {
            Layout.fillWidth: true
            Layout.fillHeight: true
            sourceComponent: root.activePanel === "files" ? files : root.activePanel === "captures" ? captures : root.activePanel === "document" ? navigation : root.activePanel === "ai" ? aiPanel : null
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
    Component { id: captures; CaptureShelf { onNoteRequested: function(id) { root.noteRequested(id) }; onAiRequested: function(spec) { root.aiRequested(spec) } } }
    Component { id: aiPanel; AiPanel { controller: root.aiController; onLinkActivated: function(link) { root.linkActivated(link) }; onSettingsRequested: root.settingsRequested() } }
    Component {
        id: navigation
        PdfNavigationPanel {
            reader: root.reader
            mode: root.navigationMode
            onModeChosen: function(mode) { root.navigationModeChosen(mode) }
            onLinkActivated: function(link) { root.linkActivated(link) }
        }
    }
}
