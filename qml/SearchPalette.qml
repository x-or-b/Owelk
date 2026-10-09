import Owelk.Ui
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Popup {
    id: root
    objectName: "searchPalette"
    width: Math.min(600, parent ? parent.width - 32 : 600)
    x: parent ? (parent.width - width) / 2 : 0
    y: parent ? Math.min(100, parent.height * .12) : 0
    padding: 12
    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    property alias results: search.results
    property alias searchController: search
    property url currentSource: ""
    ResearchSearch { id: search; query: searchInput.text; active: root.visible; showRecent: true; onRewrite: function(text) { searchInput.text = text; searchInput.cursorPosition = text.length; searchInput.forceActiveFocus() } }
    signal resultChosen(var result)
    function refresh() {
        search.refresh()
        list.currentIndex = search.selectionIndex()
    }
    onResultsChanged: {
        list.currentIndex = search.selectionIndex()
        if (list.currentIndex >= 0) list.positionViewAtIndex(list.currentIndex, ListView.Contain)
    }
    function move(direction) {
        if (!results.length) return
        list.currentIndex = (list.currentIndex + direction + results.length) % results.length
        if ((results[list.currentIndex].kind === "paperGroup" || results[list.currentIndex].kind === "section") && results.length > 1)
            list.currentIndex = (list.currentIndex + direction + results.length) % results.length
        list.positionViewAtIndex(list.currentIndex, ListView.Contain)
    }
    function choose(index) {
        if (index < 0 || index >= results.length) return
        const result = results[index]
        if (search.choose(result)) return
        close()
        Qt.callLater(function() { root.resultChosen(result) })
    }
    onAboutToShow: { searchInput.clear(); refresh() }
    onOpened: searchInput.forceActiveFocus()
    contentItem: ColumnLayout {
        spacing: 8
        TextField {
            id: searchInput
            objectName: "searchPaletteQuery"
            Layout.fillWidth: true
            placeholderText: "Search PDF text, papers, notes, AI  ·  narrow with tag: collection: state: year:"
            selectByMouse: true
            onAccepted: {
                let at = list.currentIndex
                if (search.delay.running) { root.refresh(); at = list.currentIndex }
                root.choose(Math.max(0, at))
            }
            Keys.onDownPressed: root.move(1)
            Keys.onUpPressed: root.move(-1)
            Keys.onEscapePressed: root.close()
        }
        SearchFilters { Layout.fillWidth: true; controller: search; currentSource: root.currentSource }
        ListView {
            id: list
            objectName: "searchPaletteResults"
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(360, Math.max(44, contentHeight))
            model: root.results
            // A new model resets the current row to 0, which can be a heading; choose again afterwards.
            onModelChanged: currentIndex = search.selectionIndex()
            clip: true
            ScrollBar.vertical: ScrollBar {}
            delegate: SearchResultDelegate {
                required property int index
                queryText: searchInput.text
                width: list.width
                highlighted: list.currentIndex === index
                onClicked: root.choose(index)
            }
            Label { visible: list.count === 0; anchors.centerIn: parent; text: search.waiting ? "Searching PDF text…" : search.error.length ? "Text search failed. Try again." : "No matching saved items"; color: Theme.textTertiary }
        }
        Label { text: search.sourceFilter.toString().length ? "Matching pages in this paper · 40 per page" : "PDF text grouped by paper · 3 previews each"; color: Theme.textTertiary; font.pixelSize: Theme.fontCaption }
        Label { Layout.fillWidth: true; visible: search.error.length > 0; text: "PDF text search failed: " + search.error; textFormat: Text.PlainText; wrapMode: Text.Wrap; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary }
        IndexStatus { Layout.fillWidth: true }
    }
}
