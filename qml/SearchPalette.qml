import Owelk.Ui
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Popup {
    id: root
    objectName: "searchPalette"
    // Attached to a search field (the top bar's): typing stays in that field and the results hang from its
    // bottom edge as one card, as a browser's address bar does (parent: the field's box). Without one, a box
    // of its own floats near the top.
    property TextField inputField: null
    readonly property bool attached: inputField !== null
    readonly property string query: attached ? inputField.displayText : searchInput.text
    // The box typed in: the attached field, or the palette's own.
    readonly property Item queryField: attached ? inputField : searchInput
    width: !parent ? 600 : attached ? parent.width : Math.min(600, parent.width - 32)
    x: !parent ? 0 : attached ? 0 : (parent.width - width) / 2
    y: !parent ? 0 : attached ? parent.height : Math.min(100, parent.height * .12)
    padding: attached ? 8 : 12
    topPadding: attached ? 6 : 12
    modal: !attached
    dim: !attached
    focus: !attached
    closePolicy: attached ? Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent : Popup.CloseOnEscape | Popup.CloseOnPressOutside
    // One card with the field: attached, its top (corners and edge) is cut off so its sides continue the
    // field's, with one hairline between them; a soft shadow below.
    background: Item {
        Rectangle {
            anchors.fill: parent; anchors.topMargin: 3; anchors.leftMargin: -1; anchors.rightMargin: -1; anchors.bottomMargin: -4
            radius: Theme.radiusLarge; color: Theme.shadow; opacity: .35
        }
        Item {
            anchors.fill: parent
            clip: root.attached
            Rectangle {
                anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                height: parent.height + (root.attached ? radius : 0)
                radius: Theme.radiusLarge
                color: Theme.raised
                border.color: Theme.border
            }
        }
        Rectangle { visible: root.attached; x: 1; width: parent.width - 2; height: 1; color: Theme.separator }
    }
    enter: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 110; easing.type: Easing.OutCubic } }
    // Keys typed in the attached field: the arrows choose, Return opens, Cmd+Return goes to the web, Tab on
    // the web row picks the next engine, Esc closes. True when the key was used.
    function handleKey(event) {
        if (event.key === Qt.Key_Escape) { close(); release(); return true }
        if (!opened && (event.key === Qt.Key_Down || event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) { open(); return event.key === Qt.Key_Down }
        if (!opened) return false
        if (event.key === Qt.Key_Down) { move(1); return true }
        if (event.key === Qt.Key_Up) { move(-1); return true }
        if (event.key === Qt.Key_Tab && webSelected && webRow.visible && !webRow.isAddress) { webRow.nextEngine(); return true }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (event.modifiers & Qt.ControlModifier) chooseWeb(); else accept()
            return true
        }
        return false
    }
    // Return before the results are in (typing just stopped) is answered once they are: the first result,
    // or the web when nothing matches; never the web in the meantime.
    property bool acceptPending: false
    function accept() {
        // An address, or the web row chosen with the arrows while results were still coming (waiting never
        // chooses it by itself): the web at once.
        if (webRow.isAddress || (webSelected && search.waiting)) { chooseWeb(); return }
        if (search.delay.running) refresh()
        acceptPending = search.waiting
        if (acceptPending) return
        if (webSelected) { chooseWeb(); return }
        choose(Math.max(0, list.currentIndex))
    }
    // Opened from Cmd+K or Home: the field takes the keys, its text chosen so typing replaces it.
    function begin() {
        if (attached) { inputField.forceActiveFocus(); inputField.selectAll() }
        open()
    }
    // The field lets go of the keys (Esc, a result chosen): the cursor leaves the top bar.
    function release() { if (attached && inputField.activeFocus) inputField.Window.contentItem.forceActiveFocus() }
    onClosed: { acceptPending = false; if (attached) { inputField.clear(); release() } }
    property alias results: search.results
    property alias searchController: search
    property url currentSource: ""
    ResearchSearch {
        id: search; query: root.query; active: root.visible; showRecent: true
        onRewrite: function(text) {
            const input = root.attached ? root.inputField : searchInput
            input.text = text; input.cursorPosition = text.length; input.forceActiveFocus()
        }
    }
    signal resultChosen(var result)
    // An address, or the words on the web, opened in a new tab.
    signal webRequested(string url)
    // The web row at the bottom is the chosen row: when nothing saved matches, for an address, or by
    // going down past the last result.
    property bool webSelected: false
    readonly property bool hasResults: results.some(function(r) { return r.kind !== "section" && r.kind !== "paperGroup" })
    function chooseWeb() {
        if (!webRow.url.length) return
        const url = webRow.url
        close()
        Qt.callLater(function() { root.webRequested(url) })
    }
    function updateWebChoice() { webSelected = webRow.isAddress || (root.query.trim().length > 0 && !hasResults && !search.waiting) }
    onQueryChanged: { acceptPending = false; updateWebChoice() }
    onHasResultsChanged: updateWebChoice()
    function refresh() {
        search.refresh()
        list.currentIndex = search.selectionIndex()
    }
    Connections {
        target: search
        function onWaitingChanged() {
            root.updateWebChoice()
            // Later, once the results that ended the wait are published.
            if (!search.waiting && root.acceptPending) Qt.callLater(function() { if (root.acceptPending && !search.waiting) root.accept() })
        }
    }
    onResultsChanged: {
        root.updateWebChoice()
        list.currentIndex = search.selectionIndex()
        if (list.currentIndex >= 0) list.positionViewAtIndex(list.currentIndex, ListView.Contain)
    }
    function move(direction) {
        if (webSelected) { if (direction < 0 && hasResults) { webSelected = false; list.currentIndex = results.length - 1; if (results[list.currentIndex].kind === "section") move(-1) } return }
        if (direction > 0 && webRow.visible && (!hasResults || list.currentIndex >= results.length - 1)) { webSelected = true; return }
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
    onAboutToShow: { if (!attached) searchInput.clear(); refresh() }
    onOpened: if (!attached) searchInput.forceActiveFocus()
    contentItem: ColumnLayout {
        spacing: 8
        TextField {
            id: searchInput
            objectName: "searchPaletteQuery"
            visible: !root.attached
            Layout.fillWidth: true
            placeholderText: qsTr("Search papers, notes, AI and PDF text, or the web")
            selectByMouse: true
            Keys.onPressed: function(event) { if (root.handleKey(event)) event.accepted = true }
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
                queryText: root.query
                width: list.width
                highlighted: !root.webSelected && list.currentIndex === index
                onClicked: root.choose(index)
            }
            Label { visible: list.count === 0; anchors.centerIn: parent; text: search.waiting ? qsTr("Searching PDF text…") : search.error.length ? qsTr("Text search failed. Try again.") : qsTr("No matching saved items"); color: Theme.textTertiary }
        }
        WebSearchRow {
            id: webRow
            Layout.fillWidth: true
            query: root.query
            highlighted: root.webSelected
            onOpened: function(url) { root.close(); Qt.callLater(function() { root.webRequested(url) }) }
        }
        Label { text: search.sourceFilter.toString().length ? qsTr("Matching pages in this paper · 40 per page") : qsTr("PDF text grouped by paper · 3 previews each"); color: Theme.textTertiary; font.pixelSize: Theme.fontCaption }
        Label { Layout.fillWidth: true; visible: search.error.length > 0; text: qsTr("PDF text search failed: ") + search.error; textFormat: Text.PlainText; wrapMode: Text.Wrap; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary }
        IndexStatus { Layout.fillWidth: true }
    }
}
