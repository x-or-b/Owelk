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
    width: !parent ? 600 : attached ? Math.max(parent.width, 420) : Math.min(600, parent.width - 32)
    x: !parent ? 0 : attached ? (parent.width - width) / 2 : (parent.width - width) / 2
    y: !parent ? 0 : attached ? parent.height - 1 : Math.min(100, parent.height * .12)
    padding: attached ? 8 : 12
    topPadding: attached ? 6 : 12
    modal: !attached
    dim: !attached
    focus: !attached
    closePolicy: attached ? Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent : Popup.CloseOnEscape | Popup.CloseOnPressOutside
    // One card with the field: square top corners when attached, a soft shadow below.
    background: Item {
        Rectangle {
            anchors.fill: parent; anchors.topMargin: 3; anchors.leftMargin: -1; anchors.rightMargin: -1; anchors.bottomMargin: -4
            radius: Theme.radiusLarge; color: Theme.shadow; opacity: .35
        }
        Rectangle {
            anchors.fill: parent
            radius: Theme.radiusLarge
            color: Theme.raised
            border.color: Theme.border
            Rectangle {
                visible: root.attached
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                anchors.leftMargin: 1; anchors.rightMargin: 1; anchors.topMargin: 1
                height: parent.radius; color: parent.color
            }
        }
    }
    enter: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 110; easing.type: Easing.OutCubic } }
    // Keys typed in the attached field: the arrows choose, Return opens, Cmd+Return goes to the web, Tab on
    // the web row picks the next engine, Esc closes. True when the key was used.
    function handleKey(event) {
        if (!opened && (event.key === Qt.Key_Down || event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) { open(); return event.key === Qt.Key_Down }
        if (!opened) return false
        if (event.key === Qt.Key_Down) { move(1); return true }
        if (event.key === Qt.Key_Up) { move(-1); return true }
        if (event.key === Qt.Key_Escape) { close(); return true }
        if (event.key === Qt.Key_Tab && webSelected && webRow.visible && !webRow.isAddress) { webRow.nextEngine(); return true }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (event.modifiers & Qt.ControlModifier) chooseWeb(); else accept()
            return true
        }
        return false
    }
    function accept() {
        if (webSelected) { chooseWeb(); return }
        let at = list.currentIndex
        if (search.delay.running) { refresh(); at = list.currentIndex }
        choose(Math.max(0, at))
    }
    // Opened from Cmd+K or Home: the field takes the keys, its text chosen so typing replaces it.
    function begin() {
        if (attached) { inputField.forceActiveFocus(); inputField.selectAll() }
        open()
    }
    onClosed: if (attached) inputField.clear()
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
    onQueryChanged: updateWebChoice()
    onHasResultsChanged: updateWebChoice()
    function refresh() {
        search.refresh()
        list.currentIndex = search.selectionIndex()
    }
    Connections { target: search; function onWaitingChanged() { root.updateWebChoice() } }
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
