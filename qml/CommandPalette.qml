import Owelk.Ui
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
    property bool hasSelection: false
    property bool canReopenTab: false
    property bool canCloseTab: hasDocument
    readonly property var commands: [
        {command: "/open paper", title: qsTr("File: Open PDF"), enabled: true},
        {command: "/new tab", title: qsTr("Tab: New Home Tab"), enabled: true},
        {command: "/close tab", title: qsTr("Tab: Close Active Tab"), enabled: canCloseTab},
        {command: "/reopen tab", title: qsTr("Tab: Reopen Closed Tab"), enabled: canReopenTab},
        {command: "/home", title: qsTr("View: Go to Home"), enabled: true},
        {command: "/web", title: qsTr("Web: Open Address or Search"), enabled: true},
        {command: "/new note", title: qsTr("Note: New Note"), enabled: true},
        {command: "/library", title: qsTr("Library: All Papers, Collections and Tags"), enabled: true},
        {command: "/settings", title: qsTr("App: Settings"), enabled: true},
        {command: "/find", title: qsTr("Search: Find in Current PDF"), enabled: hasDocument},
        {command: "/files", title: qsTr("Panel: Toggle Files"), enabled: true},
        {command: "/organize tabs", title: qsTr("Tabs: Organize with AI…"), enabled: hasDocument},
        {command: "/ask library", title: qsTr("AI: Ask Your Library…"), enabled: true},
        {command: "/document", title: qsTr("Panel: Toggle Document"), enabled: true},
        {command: "/threads", title: qsTr("Panel: Toggle Threads"), enabled: true},
        {command: "/annotations", title: qsTr("Panel: Annotations of This Paper"), enabled: hasDocument},
        {command: "/paper note", title: qsTr("Note: New Note about This Paper"), enabled: hasDocument},
        {command: "/split right", title: qsTr("Split: Duplicate Tab Right"), enabled: hasDocument},
        {command: "/split down", title: qsTr("Split: Duplicate Tab Below"), enabled: hasDocument},
        {command: "/split off", title: qsTr("Split: Join All Groups"), enabled: hasDocument},
        {command: "/move right", title: qsTr("Split: Move Tab Right"), enabled: hasDocument},
        {command: "/move down", title: qsTr("Split: Move Tab Below"), enabled: hasDocument},
        {command: "/next split", title: qsTr("Split: Focus Next"), enabled: hasDocument},
        {command: "/previous split", title: qsTr("Split: Focus Previous"), enabled: hasDocument},
        {command: "/mark region", title: qsTr("PDF: Mark a Region"), enabled: hasDocument},
        {command: "/highlight", title: qsTr("PDF: Highlight Selected Text"), enabled: hasDocument && hasSelection},
        {command: "/fit width", title: qsTr("PDF: Fit Width"), enabled: hasDocument},
        {command: "/fit page", title: qsTr("PDF: Fit Page"), enabled: hasDocument}
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
    contentItem: ColumnLayout {
        spacing: 8
        TextField {
            id: query
            objectName: "paletteQuery"
            Layout.fillWidth: true
            placeholderText: qsTr("Search commands")
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
            Layout.preferredHeight: Math.min(9, Math.max(1, count)) * (Theme.rowHeight + 4)
            model: root.results
            clip: true
            ScrollBar.vertical: ScrollBar {}
            delegate: ItemDelegate {
                required property int index
                required property var modelData
                width: list.width; height: Theme.rowHeight + 4
                highlighted: list.currentIndex === index
                enabled: modelData.enabled
                onClicked: root.choose(index)
                contentItem: Label {
                    objectName: "commandTitle-" + index
                    text: Match.highlight(modelData.title, query.text, Theme.accent)
                    textFormat: Text.StyledText
                    color: modelData.enabled ? Theme.text : Theme.textDisabled
                    elide: Text.ElideRight
                    verticalAlignment: Text.AlignVCenter
                }
            }
            Label { visible: list.count === 0; anchors.centerIn: parent; text: qsTr("No matching commands"); color: Theme.textTertiary }
        }
        Label { text: qsTr("↑↓ Navigate · Enter Run · Esc Close"); color: Theme.textTertiary; font.pixelSize: Theme.fontCaption }
    }
}
