import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "PaletteMatch.js" as Match

Popup {
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
    property bool canReopenTab: false
    readonly property var commands: [
        {command: "/open paper", title: "File: Open PDF", enabled: true},
        {command: "/close tab", title: "Tab: Close Active Tab", enabled: hasDocument},
        {command: "/reopen tab", title: "Tab: Reopen Closed Tab", enabled: canReopenTab},
        {command: "/home", title: "View: Go to Home", enabled: true},
        {command: "/find", title: "Search: Find in Current PDF", enabled: hasDocument},
        {command: "/files", title: "Panel: Toggle Files", enabled: true},
        {command: "/captures", title: "Panel: Toggle Captures", enabled: true},
        {command: "/document", title: "Panel: Toggle Document Outline and Thumbnails", enabled: true},
        {command: "/split right", title: "Split: Duplicate Tab Right", enabled: hasDocument},
        {command: "/split down", title: "Split: Duplicate Tab Below", enabled: hasDocument},
        {command: "/split off", title: "Split: Join All Groups", enabled: hasDocument},
        {command: "/capture", title: "Capture: Select a Region", enabled: hasDocument},
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
    background: Rectangle { color: "#ffffff"; border.color: "#bcbcbc"; radius: 4 }
    contentItem: ColumnLayout {
        spacing: 8
        TextField {
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
            delegate: ItemDelegate {
                required property int index
                required property var modelData
                width: list.width; height: 36
                highlighted: list.currentIndex === index
                enabled: modelData.enabled
                onClicked: root.choose(index)
                background: Rectangle { color: highlighted ? "#eeeeee" : "transparent" }
                contentItem: Label {
                    objectName: "commandTitle-" + index
                    text: Match.highlight(modelData.title, query.text)
                    textFormat: Text.StyledText
                    color: "#333333"
                    opacity: modelData.enabled ? 1 : .45
                    elide: Text.ElideRight
                    verticalAlignment: Text.AlignVCenter
                }
            }
            Label { visible: list.count === 0; anchors.centerIn: parent; text: "No matching commands"; color: "#777777" }
        }
        Label { text: "↑↓ Navigate · Enter Run · Esc Close"; color: "#777777"; font.pixelSize: 11 }
    }
}
