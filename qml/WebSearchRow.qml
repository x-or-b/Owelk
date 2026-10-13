import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui
import "WebSearch.js" as WebSearch
import "WorkspaceTree.js" as Tree

// The last row of a search (Cmd+K, Home): the words on the web with an engine to pick, or an address to
// open. Its page opens in a new tab. Starts on the default engine (Settings › Web).
ItemDelegate {
    id: root
    objectName: "webSearchRow"
    property string query: ""
    // The engines shown in the chooser (Settings › Web can hide some).
    property var engines: WebSearch.shown(researchStore)
    property string engine: WebSearch.template(researchStore)
    property string defaultEngine: engine
    signal opened(string url)
    readonly property string words: query.trim()
    readonly property bool isAddress: words.length > 0 && Tree.addressToUrl(words, "search:%s").indexOf("search:") !== 0
    readonly property string url: Tree.addressToUrl(words, engine)
    readonly property string engineName: (engines.find(function(e) { return e.template === root.engine }) || WebSearch.current(researchStore)).name
    function open() { if (url.length) opened(url) }
    // Tab on the row: the next engine.
    function nextEngine() {
        const at = engines.findIndex(function(e) { return e.template === root.engine })
        engine = engines[(at + 1) % engines.length].template
    }
    Connections {
        target: researchStore
        function onSettingsChanged() {
            root.engines = WebSearch.shown(researchStore)
            const chosen = WebSearch.template(researchStore)
            if (chosen !== root.defaultEngine) { root.defaultEngine = chosen; root.engine = chosen }
        }
    }
    visible: words.length > 0
    height: visible ? Theme.rowHeight + 10 : 0
    leftPadding: 10; rightPadding: 10
    onClicked: open()
    // A band of its own under the results: a hairline above and the window's shade, so it reads as another
    // way to go rather than one more result. Chosen, it takes the usual selection colour.
    background: Rectangle {
        color: root.highlighted ? Theme.selected : root.hovered ? Theme.hover : Theme.window
        radius: Theme.radius
        Rectangle { width: parent.width; height: 1; color: Theme.separator; visible: !root.highlighted }
    }
    contentItem: RowLayout {
        spacing: 8
        Rectangle {
            implicitWidth: 22; implicitHeight: 22; radius: 6
            color: root.highlighted ? Theme.mix(Theme.selected, Theme.selectedText, .12) : Theme.field
            border.color: Theme.separator
            Icon { anchors.centerIn: parent; name: "globe"; size: Theme.fontSmall + 1; color: root.highlighted ? Theme.selectedText : Theme.textSecondary }
        }
        Label {
            objectName: "webSearchText"
            Layout.fillWidth: true
            text: root.isAddress ? qsTr("Open ") + root.words : qsTr("Search “") + root.words + "”"
            elide: Text.ElideMiddle; textFormat: Text.PlainText
            color: root.highlighted ? Theme.selectedText : Theme.text
        }
        Chip {
            id: engineChip
            objectName: "webSearchEngine"
            visible: !root.isAddress
            text: root.engineName
            trailingIcon: "down"
            ToolTip.text: qsTr("Search engine · Tab for the next")
            onClicked: engineMenu.popup(engineChip, 0, engineChip.height)
            Menu {
                id: engineMenu
                Instantiator {
                    model: root.engines
                    delegate: MenuItem {
                        required property var modelData
                        text: modelData.name
                        checkable: true
                        checked: root.engine === modelData.template
                        onTriggered: root.engine = modelData.template
                    }
                    onObjectAdded: function(index, item) { engineMenu.insertItem(index, item) }
                    onObjectRemoved: function(index, item) { engineMenu.removeItem(item) }
                }
            }
        }
        Label { text: Qt.platform.os === "osx" ? "⌘↩" : "Ctrl+↵"; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary }
    }
}
