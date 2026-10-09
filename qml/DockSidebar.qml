import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui

Rectangle {
    id: root
    property string side: "left"
    property var panels: []
    // One panel per dock (Main.qml closes the other when one opens).
    readonly property string activePanel: panels.length ? panels[0] : ""
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
    // The Library panel's shelf: open the Library filtered, or a workspace.
    property var workspace: null
    signal libraryFilterRequested(var filter)
    signal workspaceChosen(string id)
    signal workspaceManageRequested(string id)
    function panelName(panel) { return panel === "files" ? "Library" : panel === "captures" ? "Captures" : panel === "ai" ? "AI" : panel === "document" ? "Document" : "" }
    // A slice of the window: no corners or frame; the 1px edge beside the document is the resize
    // edge in Main.qml.
    color: Theme.sidebar
    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        // Its name (one panel per dock; the status bar's icons open and close them).
        Label {
            objectName: "dockTitle"
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.barHeight
            leftPadding: 12
            verticalAlignment: Text.AlignVCenter
            text: root.panelName(root.activePanel)
            font.pixelSize: Theme.fontSmall
            font.weight: Font.DemiBold
            color: Theme.textSecondary
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
            workspace: root.workspace
            onDocumentChosen: function(source) { root.documentChosen(source) }
            onFolderChosen: function(folder) { root.folderChosen(folder) }
            onLibraryFilterRequested: function(filter) { root.libraryFilterRequested(filter) }
            onWorkspaceChosen: function(id) { root.workspaceChosen(id) }
            onWorkspaceManageRequested: function(id) { root.workspaceManageRequested(id) }
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
