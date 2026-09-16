import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Popup {
    id: root
    objectName: "commandPalette"
    width: Math.min(560, parent ? parent.width - 32 : 560)
    x: parent ? (parent.width - width) / 2 : 0
    y: parent ? Math.min(100, parent.height * .12) : 0
    padding: 12
    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    property var recentDocuments: []
    readonly property var commands: [
        {kind: "command", command: "/home", title: "Go to Home"},
        {kind: "command", command: "/open paper", title: "Open PDF…"},
        {kind: "command", command: "/find", title: "Find in current document"},
        {kind: "command", command: "/files", title: "Show files", description: "Browse recent PDFs or open a paper folder"},
        {kind: "command", command: "/split right", title: "Split right"},
        {kind: "command", command: "/split off", title: "Single pane"},
        {kind: "command", command: "/capture", title: "Toggle region capture", description: "Save a figure, table or equation with its source"},
        {kind: "command", command: "/captures", title: "Show saved captures", description: "Select a saved capture to return to its source"}
    ]
    readonly property var results: filtered(query.text, recentDocuments)
    signal documentChosen(url source)
    signal commandChosen(string command)

    function filtered(text, documents) {
        const input = text.replace(/^\s+/, "").toLowerCase().replace(/^\/caputres(?=\s|$)/, "/captures")
        const openArgument = input.startsWith("/open paper ")
        const needle = (openArgument ? input.slice(12) : input).trim()
        const matches = []
        if (!input.startsWith("/") || openArgument || input === "/open paper") {
            for (let i = 0; i < documents.length; ++i) {
                const doc = documents[i]
                if (input === "/open paper" || !needle || doc.name.toLowerCase().includes(needle))
                    matches.push({kind: "document", title: doc.name, source: doc.url})
            }
        }
        if ((!input || input.startsWith("/")) && !openArgument) {
            for (let i = 0; i < commands.length; ++i) {
                if (!input || commands[i].command.includes(input)) matches.push(commands[i])
            }
        }
        return matches
    }

    function move(direction) {
        if (!results.length) return
        resultsView.currentIndex = (resultsView.currentIndex + direction + results.length) % results.length
        resultsView.positionViewAtIndex(resultsView.currentIndex, ListView.Contain)
    }

    function choose(index) {
        if (index < 0 || index >= results.length) return
        const result = results[index]
        close()
        // Run after the popup restores keyboard focus to the reader.
        Qt.callLater(function() {
            if (result.kind === "document") root.documentChosen(result.source)
            else root.commandChosen(result.command)
        })
    }

    onResultsChanged: if (resultsView) resultsView.currentIndex = results.length ? 0 : -1
    onAboutToShow: {
        query.clear()
        resultsView.currentIndex = results.length ? 0 : -1
    }
    onOpened: query.forceActiveFocus()

    background: Rectangle { color: "#ffffff"; border.color: "#bcbcbc"; radius: 4 }
    contentItem: ColumnLayout {
        spacing: 8
        TextField {
            id: query
            objectName: "paletteQuery"
            Layout.fillWidth: true
            placeholderText: "Recent PDF name or /command"
            selectByMouse: true
            onAccepted: root.choose(resultsView.currentIndex)
            Keys.onDownPressed: root.move(1)
            Keys.onUpPressed: root.move(-1)
            Keys.onEscapePressed: root.close()
            Keys.onTabPressed: {
                const result = root.results[resultsView.currentIndex]
                if (result && result.kind === "command") text = result.command + " "
            }
        }
        ListView {
            id: resultsView
            objectName: "paletteResults"
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(6, Math.max(1, count)) * 54
            model: root.results
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}
            delegate: ItemDelegate {
                required property int index
                required property var modelData
                width: resultsView.width
                height: 54
                highlighted: resultsView.currentIndex === index
                onClicked: root.choose(index)
                background: Rectangle { color: highlighted ? "#eeeeee" : "transparent" }
                contentItem: Column {
                    spacing: 3
                    Label { width: parent.width; text: modelData.title; color: "#242424"; elide: Text.ElideMiddle }
                    Label {
                        width: parent.width
                        text: modelData.kind === "document" ? modelData.source.toString()
                              : modelData.command + (modelData.description ? " · " + modelData.description : "")
                        color: "#737373"
                        font.pixelSize: 11
                        elide: Text.ElideMiddle
                    }
                }
            }
            Label {
                visible: resultsView.count === 0
                anchors.centerIn: parent
                text: "No matching recent files or commands."
                color: "#737373"
            }
        }
        Label {
            text: "↑↓ Navigate · Enter Run · Tab Complete · Esc Close"
            color: "#737373"
            font.pixelSize: 11
        }
    }
}
