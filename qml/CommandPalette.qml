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
    property bool canSwitchTabs: false
    property bool canGoBack: false
    property bool canGoForward: false
    property bool canMinimize: true
    property bool canDarkPages: false
    property bool hasVerticalTabs: false
    property bool hasCodeLinks: false
    property bool canExportAnnotated: false
    // By kind, as the palette lists them with nothing typed.
    readonly property var commands: [
        {command: "/open paper", title: qsTr("File: Open PDF…"), enabled: true},
        {command: "/new tab", title: qsTr("Tab: New Home Tab"), enabled: true},
        {command: "/close tab", title: qsTr("Tab: Close Active Tab"), enabled: canCloseTab},
        {command: "/reopen tab", title: qsTr("Tab: Reopen Closed Tab"), enabled: canReopenTab},
        {command: "/next tab", title: qsTr("Tab: Next Tab"), enabled: canSwitchTabs},
        {command: "/previous tab", title: qsTr("Tab: Previous Tab"), enabled: canSwitchTabs},
        {command: "/organize tabs", title: qsTr("Tab: Organize with AI…"), enabled: hasDocument},
        {command: "/split right", title: qsTr("Split: Duplicate Tab Right"), enabled: hasDocument},
        {command: "/split down", title: qsTr("Split: Duplicate Tab Below"), enabled: hasDocument},
        {command: "/move right", title: qsTr("Split: Move Tab Right"), enabled: hasDocument},
        {command: "/move down", title: qsTr("Split: Move Tab Below"), enabled: hasDocument},
        {command: "/next split", title: qsTr("Split: Focus Next"), enabled: hasDocument},
        {command: "/previous split", title: qsTr("Split: Focus Previous"), enabled: hasDocument},
        {command: "/split off", title: qsTr("Split: Join All Groups"), enabled: hasDocument},
        {command: "/home", title: qsTr("View: Go to Home"), enabled: true},
        {command: "/back", title: qsTr("View: Back"), enabled: canGoBack},
        {command: "/forward", title: qsTr("View: Forward"), enabled: canGoForward},
        {command: "/focus", title: qsTr("View: Toggle Focus Mode"), enabled: true},
        {command: "/dark pages", title: qsTr("View: Toggle Dark Pages"), enabled: canDarkPages},
        {command: "/minimize", title: qsTr("Window: Minimize"), enabled: canMinimize},
        {command: "/files", title: qsTr("Panel: Toggle Library Panel"), enabled: true},
        {command: "/document", title: qsTr("Panel: Toggle Document Panel"), enabled: true},
        {command: "/ai", title: qsTr("Panel: Toggle AI Chat"), enabled: true},
        {command: "/threads", title: qsTr("Panel: Toggle Threads"), enabled: true},
        {command: "/vertical tabs", title: qsTr("Panel: Toggle Vertical Tabs"), enabled: hasVerticalTabs},
        {command: "/contents", title: qsTr("Panel: Contents of This Paper"), enabled: hasDocument},
        {command: "/annotations", title: qsTr("Panel: Annotations of This Paper"), enabled: hasDocument},
        {command: "/symbols", title: qsTr("Panel: Symbols of This Paper"), enabled: hasDocument},
        {command: "/related", title: qsTr("Panel: Related Papers"), enabled: hasDocument},
        {command: "/figures", title: qsTr("Panel: Figures and Tables of This Paper"), enabled: hasDocument},
        {command: "/library", title: qsTr("Library: All Papers, Collections and Tags"), enabled: true},
        {command: "/for you", title: qsTr("Library: For You"), enabled: true},
        {command: "/notes", title: qsTr("Library: Notes"), enabled: true},
        {command: "/words", title: qsTr("Library: Words Kept from Gloss"), enabled: true},
        {command: "/trash", title: qsTr("Library: Trash"), enabled: true},
        {command: "/search", title: qsTr("Search: Papers, Notes and Annotations"), enabled: true},
        {command: "/find", title: qsTr("Search: Find in Current PDF"), enabled: hasDocument},
        {command: "/web", title: qsTr("Web: Open Address or Search"), enabled: true},
        {command: "/zoom in", title: qsTr("PDF: Zoom In"), enabled: hasDocument},
        {command: "/zoom out", title: qsTr("PDF: Zoom Out"), enabled: hasDocument},
        {command: "/fit width", title: qsTr("PDF: Fit Width"), enabled: hasDocument},
        {command: "/fit page", title: qsTr("PDF: Fit Page"), enabled: hasDocument},
        {command: "/mark region", title: qsTr("PDF: Mark a Region"), enabled: hasDocument},
        {command: "/highlight", title: qsTr("PDF: Highlight Selected Text"), enabled: hasDocument && hasSelection},
        {command: "/comment", title: qsTr("PDF: Comment on the Selection"), enabled: hasDocument && hasSelection},
        {command: "/draw", title: qsTr("PDF: Draw"), enabled: hasDocument},
        {command: "/text box", title: qsTr("PDF: Add a Text Box"), enabled: hasDocument},
        {command: "/code links", title: qsTr("PDF: Code Links"), enabled: hasCodeLinks},
        {command: "/print", title: qsTr("PDF: Print…"), enabled: hasDocument},
        {command: "/export annotated", title: qsTr("PDF: Export Annotated PDF…"), enabled: hasDocument && canExportAnnotated},
        {command: "/export markdown", title: qsTr("PDF: Export Annotations as Markdown…"), enabled: hasDocument},
        {command: "/mark read", title: qsTr("Paper: Mark as Read"), enabled: hasDocument},
        {command: "/paper details", title: qsTr("Paper: Details…"), enabled: hasDocument},
        {command: "/new note", title: qsTr("Note: New Note"), enabled: true},
        {command: "/paper note", title: qsTr("Note: New Note about This Paper"), enabled: hasDocument},
        {command: "/ask ai", title: qsTr("AI: Ask about the Selection or This Paper"), enabled: true},
        {command: "/gloss", title: qsTr("AI: Gloss the Selection"), enabled: hasDocument && hasSelection},
        {command: "/translate page", title: qsTr("AI: Translate This Page"), enabled: hasDocument},
        {command: "/ask library", title: qsTr("AI: Ask Your Library…"), enabled: true},
        {command: "/settings", title: qsTr("Settings: Open"), enabled: true},
        {command: "/customize home", title: qsTr("Settings: Customize Home"), enabled: true},
        {command: "/settings appearance", title: qsTr("Settings: Appearance"), enabled: true},
        {command: "/settings shortcuts", title: qsTr("Settings: Shortcuts"), enabled: true},
        {command: "/settings foryou", title: qsTr("Settings: For You"), enabled: true},
        {command: "/settings ai", title: qsTr("Settings: AI"), enabled: true},
        {command: "/settings sync", title: qsTr("Settings: Sync & Backup"), enabled: true}
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
