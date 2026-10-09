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
    signal linkActivated(string link)
    signal newNoteRequested(url source)
    signal aiRequested(var spec)
    signal settingsRequested()
    // The document area (tabs dragged onto a collection) and the Library opened with a filter.
    property var documents: null
    signal libraryFilterRequested(var filter)
    function panelName(panel) { return panel === "files" ? "Library" : panel === "ai" ? "AI" : panel === "document" ? "Document" : "" }
    // A slice of the window: no corners or frame; the 1px edge beside the document is the resize
    // edge in Main.qml.
    color: Theme.sidebar
    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        Loader {
            Layout.fillWidth: true
            Layout.fillHeight: true
            sourceComponent: root.activePanel === "files" ? files : root.activePanel === "document" ? navigation : root.activePanel === "ai" ? aiPanel : null
        }
    }
    Component {
        id: files
        FilePanel {
            folder: root.folder
            documents: root.documents
            onDocumentChosen: function(source) { root.documentChosen(source) }
            onFolderChosen: function(folder) { root.folderChosen(folder) }
            onLibraryFilterRequested: function(filter) { root.libraryFilterRequested(filter) }
        }
    }
    Component { id: aiPanel; AiPanel { controller: root.aiController; onLinkActivated: function(link) { root.linkActivated(link) }; onSettingsRequested: root.settingsRequested() } }
    Component {
        id: navigation
        PdfNavigationPanel {
            reader: root.reader
            mode: root.navigationMode
            onModeChosen: function(mode) { root.navigationModeChosen(mode) }
            onLinkActivated: function(link) { root.linkActivated(link) }
            onNewNoteRequested: function(source) { root.newNoteRequested(source) }
        }
    }
}
