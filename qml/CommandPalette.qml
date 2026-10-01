import "UiTheme.js" as Theme
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "PaletteMatch.js" as Match

UiControls.Popup {
    id: root
    objectName: "commandPalette"
    width: Math.min(640, parent ? parent.width - 32 : 640)
    x: parent ? (parent.width - width) / 2 : 0
    y: parent ? Math.min(100, parent.height * .12) : 0
    padding: 12
    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    property bool hasDocument: false
    property bool hasSelection: false
    property bool canReopenTab: false
    property bool canCloseTab: hasDocument
    readonly property var commands: [
        {command: "/open paper", title: "File: Open PDF", enabled: true},
        {command: "/new tab", title: "Tab: New Home Tab", enabled: true},
        {command: "/close tab", title: "Tab: Close Active Tab", enabled: canCloseTab},
        {command: "/reopen tab", title: "Tab: Reopen Closed Tab", enabled: canReopenTab},
        {command: "/home", title: "View: Go to Home", enabled: true},
        {command: "/find", title: "Search: Find in Current PDF", enabled: hasDocument},
        {command: "/files", title: "Panel: Toggle Files", enabled: true},
        {command: "/captures", title: "Panel: Toggle Captures", enabled: true},
        {command: "/document", title: "Panel: Toggle Document Outline and Thumbnails", enabled: true},
        {command: "/split right", title: "Split: Duplicate Tab Right", enabled: hasDocument},
        {command: "/split down", title: "Split: Duplicate Tab Below", enabled: hasDocument},
        {command: "/split off", title: "Split: Join All Groups", enabled: hasDocument},
        {command: "/move right", title: "Split: Move Tab Right", enabled: hasDocument},
        {command: "/move down", title: "Split: Move Tab Below", enabled: hasDocument},
        {command: "/next split", title: "Split: Focus Next", enabled: hasDocument},
        {command: "/previous split", title: "Split: Focus Previous", enabled: hasDocument},
        {command: "/capture", title: "Capture: Select a Region", enabled: hasDocument},
        {command: "/capture text", title: "Capture: Save Selected Text", enabled: hasDocument && hasSelection},
        {command: "/highlight", title: "PDF: Highlight Selected Text", enabled: hasDocument && hasSelection},
        {command: "/fit width", title: "PDF: Fit Page Width", enabled: hasDocument}
    ]
    readonly property var results: commands.filter(function(c) { return Match.matches(c.title, query.text) })
    signal commandChosen(string command)
    function move(direction) {
        if (!results.length) return
        list.currentIndex = (list.currentIndex + direction + results.length) % results.length
        list.positionViewAtIndex(list.currentIndex, ListView.Contain)
    }
    function choose(index) {
        if (index < 0 || index >= results.length || !results[index].enabled) return
        const command = results[index].command
        close()
        Qt.callLater(function() { root.commandChosen(command) })
    }
    onResultsChanged: if (list) list.currentIndex = results.length ? 0 : -1
    onAboutToShow: { query.clear(); list.currentIndex = results.length ? 0 : -1 }
    onOpened: query.forceActiveFocus()
    background: Rectangle { color: Theme.surface; border.color: Theme.borderPopup; radius: Theme.cornerRadius }
    contentItem: ColumnLayout {
        spacing: 8
        UiControls.TextField {
            id: query
            objectName: "paletteQuery"
            Layout.fillWidth: true
            placeholderText: "Search commands"
            selectByMouse: true
            onAccepted: root.choose(list.currentIndex)
            Keys.onDownPressed: root.move(1)
            Keys.onUpPressed: root.move(-1)
            Keys.onEscapePressed: root.close()
        }
        ListView {
            id: list
            objectName: "paletteResults"
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(9, Math.max(1, count)) * 36
            model: root.results
            clip: true
            ScrollBar.vertical: ScrollBar {}
            delegate: UiControls.ItemDelegate {
                required property int index
                required property var modelData
                width: list.width; height: 36
                highlighted: list.currentIndex === index
                enabled: modelData.enabled
                onClicked: root.choose(index)
                background: Rectangle { color: highlighted ? Theme.surfaceChrome : "transparent" }
                contentItem: Label {
                    objectName: "commandTitle-" + index
                    text: Match.highlight(modelData.title, query.text)
                    textFormat: Text.StyledText
                    color: Theme.textBody
                    opacity: modelData.enabled ? 1 : .45
                    elide: Text.ElideRight
                    verticalAlignment: Text.AlignVCenter
                }
            }
            Label { visible: list.count === 0; anchors.centerIn: parent; text: "No matching commands"; color: Theme.textMuted }
        }
        Label { text: "↑↓ Navigate · Enter Run · Esc Close"; color: Theme.textMuted; font.pixelSize: 11 }
    }
}
