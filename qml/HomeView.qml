import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Owelk.Ui
import "Platform.js" as Platform
import "WorkspaceTree.js" as Tree

Rectangle {
    id: root
    objectName: "homeView"
    color: Theme.sidebar
    property alias results: searchModel.results
    property alias searchController: searchModel
    ResearchSearch { id: searchModel; query: searchInput.text; active: root.visible; onRewrite: function(text) { searchInput.text = text; searchInput.cursorPosition = text.length; searchInput.forceActiveFocus() } }
    readonly property var continuation: researchStore.continueReading
    signal openRequested()
    signal libraryRequested()
    // Unsorted chosen on Home: the Library opens filtered to it.
    signal libraryFilterRequested(var filter)
    // What Home lists, read again when papers, notes or conversations change (and when shown).
    property var recentNotes: []
    property var recentThreads: []
    property var inbox: []
    property int unsorted: 0
    function refreshLists() {
        if (!visible) return
        recentNotes = researchStore.notes(false).slice(0, 5)
        recentThreads = researchStore.aiThreads().slice(0, 5)
        unsorted = researchStore.unsortedCount()
        inbox = unsorted ? researchStore.libraryDocuments({unsorted: true, sort: "added"}).slice(0, 30) : []
    }
    onVisibleChanged: refreshLists()
    Component.onCompleted: refreshLists()
    Timer { id: listsLater; interval: 150; onTriggered: root.refreshLists() }
    Connections {
        target: researchStore
        function onHomeChanged() { listsLater.restart() }
        function onNotesChanged() { listsLater.restart() }
        function onAiThreadsChanged() { listsLater.restart() }
        function onDocumentsChanged() { listsLater.restart() }
    }
    // An address or a web search typed on Home (opens a web tab).
    signal webRequested(string url)
    function searchWeb(text) {
        const url = Tree.addressToUrl(text, researchStore.setting("searchEngine", "https://scholar.google.com/scholar?q=%s"))
        if (url.length) webRequested(url)
        return url.length > 0
    }
    signal documentChosen(url source, var position)
    signal resultChosen(var result)
    function choose(result) { if (!searchModel.choose(result)) root.resultChosen(result) }
    function search() { searchModel.refresh(); searchResults.currentIndex = searchModel.selectionIndex() }
    onResultsChanged: {
        searchResults.currentIndex = searchModel.selectionIndex()
        if (searchResults.currentIndex >= 0) searchResults.positionViewAtIndex(searchResults.currentIndex, ListView.Contain)
    }
    function focusSearch() { searchInput.forceActiveFocus(); searchInput.selectAll() }
    // A rounded list box (like ListGroup) of a fixed height: seven recent-paper rows; longer lists scroll.
    component ListBox: Rectangle {
        property alias model: boxList.model
        property alias delegate: boxList.delegate
        property string empty: ""
        Layout.fillWidth: true
        Layout.preferredHeight: 7 * (Theme.rowHeight + 4) + 6 + 8
        radius: Theme.radiusLarge
        color: Theme.content
        border.color: Theme.separator
        ListView {
            id: boxList
            anchors.fill: parent; anchors.margins: 4
            clip: true
            spacing: 1
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}
        }
        Label { anchors.centerIn: parent; visible: boxList.count === 0; text: parent.empty; color: Theme.textTertiary }
    }
    Flickable {
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: body.height + 64
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar {}
        ColumnLayout {
            id: body
            x: (parent.width - width) / 2
            y: 32
            width: Math.min(780, parent.width - 48)
            spacing: 20
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 8
                Label { text: "Search your research"; font.pixelSize: Theme.fontTitle; font.weight: Font.Medium; color: Theme.text }
                TextField {
                    id: searchInput
                    objectName: "homeSearch"
                    Layout.fillWidth: true
                    implicitHeight: 40
                    placeholderText: "Find PDF text, papers, notes or AI conversations  ·  tag: collection:"
                    selectByMouse: true
                    onAccepted: {
                        let chosenIndex = searchResults.currentIndex
                        if (searchModel.delay.running) { root.search(); chosenIndex = searchResults.currentIndex }
                        if (root.results.length) root.choose(root.results[Math.max(0, Math.min(chosenIndex, root.results.length - 1))])
                    }
                    Keys.onDownPressed: searchResults.currentIndex = Math.min(root.results.length - 1, searchResults.currentIndex + 1)
                    Keys.onUpPressed: searchResults.currentIndex = Math.max(0, searchResults.currentIndex - 1)
                    Keys.onEscapePressed: clear()
                }
                SearchFilters { Layout.fillWidth: true; controller: searchModel }
                // The web, from the same page: an address opens it, words search with the chosen engine.
                TextField {
                    id: webInput
                    objectName: "homeWebSearch"
                    Layout.fillWidth: true
                    implicitHeight: Theme.controlHeight + 6
                    leftPadding: 30
                    placeholderText: "Search the web or enter an address  ·  " + (researchStore.setting("searchEngine", "").indexOf("google.com/search") >= 0 ? "Google" : researchStore.setting("searchEngine", "").indexOf("duckduckgo") >= 0 ? "DuckDuckGo" : researchStore.setting("searchEngine", "").indexOf("arxiv") >= 0 ? "arXiv" : "Google Scholar")
                    selectByMouse: true
                    font.pixelSize: Theme.fontBody
                    onAccepted: if (root.searchWeb(text)) clear()
                    Keys.onEscapePressed: clear()
                    // A globe: the web, not the library.
                    Icon { x: 9; anchors.verticalCenter: parent.verticalCenter; name: "globe"; size: Theme.fontBody + 1; color: Theme.textTertiary }
                }
                IndexStatus { Layout.fillWidth: true }
                Label { Layout.fillWidth: true; visible: searchModel.error.length > 0; text: "PDF text search failed: " + searchModel.error; textFormat: Text.PlainText; wrapMode: Text.Wrap; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary }
                ListView {
                    id: searchResults
                    objectName: "homeResults"
                    visible: searchInput.text.trim().length > 0
                    Layout.fillWidth: true
                    Layout.preferredHeight: visible ? Math.min(320, Math.max(44, contentHeight)) : 0
                    clip: true
                    model: root.results
                    ScrollBar.vertical: ScrollBar {}
                    delegate: SearchResultDelegate {
                        required property int index
                        queryText: searchInput.text
                        width: searchResults.width
                        highlighted: searchResults.currentIndex === index
                        onClicked: root.choose(modelData)
                    }
                    Label { anchors.centerIn: parent; visible: searchResults.count === 0; text: searchModel.waiting ? "Searching PDF text…" : searchModel.error.length ? "Text search failed. Try again." : "No matching saved items"; color: Theme.textTertiary }
                }
            }
            // The paper last read, as a card: click anywhere on it to go back to the page.
            ItemDelegate {
                id: continueCard
                objectName: "continueReading"
                Layout.fillWidth: true
                implicitHeight: continueColumn.implicitHeight + 32
                readonly property var details: root.continuation.source ? (researchStore.documentsRevision, researchStore.documentDetails(root.continuation.source)) : ({})
                onClicked: {
                    if (root.continuation.source) root.documentChosen(root.continuation.source, root.continuation.position)
                    else root.openRequested()
                }
                background: Rectangle {
                    radius: Theme.radiusLarge
                    color: continueCard.hovered ? Theme.hover : Theme.content
                    border.color: Theme.separator
                }
                contentItem: RowLayout {
                    spacing: 16
                    ColumnLayout {
                        id: continueColumn
                        Layout.fillWidth: true
                        spacing: 4
                        Label { text: "Continue Reading"; font.pixelSize: Theme.fontCaption; font.weight: Font.DemiBold; color: Theme.textTertiary }
                        Label {
                            Layout.fillWidth: true
                            text: root.continuation.name || "Start with a paper"
                            elide: Text.ElideRight; maximumLineCount: 2; wrapMode: Text.Wrap; textFormat: Text.PlainText
                            font.pixelSize: Theme.fontTitle; font.weight: Font.Medium; color: Theme.text
                        }
                        Label {
                            Layout.fillWidth: true
                            text: root.continuation.source
                                ? [continueCard.details.authors, continueCard.details.year, "Page " + (((root.continuation.position || {}).page || 0) + 1)].filter(function(t) { return t && String(t).length }).join("  ·  ")
                                : "Open a PDF. Your reading position is saved automatically."
                            elide: Text.ElideRight; textFormat: Text.PlainText
                            color: Theme.textTertiary; font.pixelSize: Theme.fontSmall
                        }
                    }
                    Button {
                        highlighted: true
                        text: root.continuation.source ? "Continue" : "Open PDF…"
                        onClicked: continueCard.clicked()
                    }
                }
            }
            // What is waiting and what was read: the papers still to file beside recent papers, each in a
            // box seven recent papers tall (scrolling past that).
            RowLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignTop
                spacing: 28
                // Inbox: papers in no collection yet, newest first, with where similar papers already are.
                ColumnLayout {
                    objectName: "homeInbox"
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Layout.alignment: Qt.AlignTop
                    spacing: 6
                    RowLayout {
                        Layout.fillWidth: true
                        Label { text: "Inbox"; font.pixelSize: Theme.fontHeadline; font.weight: Font.DemiBold; Layout.preferredHeight: 32; Layout.fillWidth: true }
                        Button {
                            objectName: "homeUnsorted"
                            visible: root.unsorted > 0
                            flat: true
                            text: "All Unsorted  " + root.unsorted
                            font.pixelSize: Theme.fontSmall
                            onClicked: root.libraryFilterRequested({unsorted: true})
                        }
                    }
                    ListBox {
                        model: root.inbox
                        empty: "Every paper is in a collection."
                        delegate: ItemDelegate {
                            id: waiting
                            required property var modelData
                            required property int index
                            objectName: "homeInbox-" + index
                            width: ListView.view.width
                            separator: index < root.inbox.length - 1
                            onClicked: root.documentChosen(modelData.url, modelData.position)
                            // Up to two collections where similar papers already are.
                            property var suggestions: []
                            property int request: -1
                            Component.onCompleted: request = researchStore.suggestCollections(modelData.url)
                            Connections {
                                target: researchStore
                                enabled: waiting.request >= 0
                                function onCollectionsSuggested(request, source, list) { if (request === waiting.request) waiting.suggestions = list }
                            }
                            contentItem: Column {
                                spacing: 4
                                Label { width: parent.width; text: waiting.modelData.name; elide: Text.ElideRight; textFormat: Text.PlainText; color: Theme.text }
                                Label {
                                    visible: !waiting.suggestions.length
                                    width: parent.width
                                    text: [waiting.modelData.authors, waiting.modelData.year].filter(function(t) { return t && String(t).length }).join("  ·  ") || " "
                                    elide: Text.ElideRight; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
                                }
                                Flow {
                                    visible: waiting.suggestions.length > 0
                                    width: parent.width
                                    spacing: 4
                                    Repeater {
                                        model: waiting.suggestions
                                        delegate: Chip {
                                            required property var modelData
                                            objectName: "homeSuggestion-" + modelData.name
                                            text: "+ " + modelData.name
                                            ToolTip.text: "Add to " + modelData.name
                                            onClicked: { const url = waiting.modelData.url, id = modelData.id; Qt.callLater(function() { researchStore.setDocumentCollection(url, id, true) }) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Layout.alignment: Qt.AlignTop
                    spacing: 6
                    RowLayout {
                        Layout.fillWidth: true
                        Label { text: "Recent Papers"; font.pixelSize: Theme.fontHeadline; font.weight: Font.DemiBold; Layout.preferredHeight: 32; Layout.fillWidth: true }
                        IconButton {
                            objectName: "openLibraryButton"; icon.name: "library"
                            description: "Library · " + Platform.keys("Ctrl+Shift+L")
                            onClicked: root.libraryRequested()
                        }
                    }
                    ListBox {
                        model: researchStore.recentDocuments
                        empty: "No recent papers"
                        delegate: RecentPaperDelegate {
                            required property int index
                            width: ListView.view.width
                            height: Theme.rowHeight + 4
                            separator: index < researchStore.recentDocuments.length - 1
                            onDocumentChosen: function(source, position) { root.documentChosen(source, position) }
                            onMenuRequested: function(row) { recentMenu.show(row) }
                        }
                    }
                }
            }
            // Recent notes and AI conversations.
            RowLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignTop
                spacing: 28
                ColumnLayout {
                    objectName: "homeNotes"
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Layout.alignment: Qt.AlignTop
                    spacing: 6
                    Label { text: "Recent Notes"; font.pixelSize: Theme.fontHeadline; font.weight: Font.DemiBold; Layout.preferredHeight: 32 }
                    ListGroup {
                        Layout.fillWidth: true
                        visible: root.recentNotes.length > 0
                        Repeater {
                            model: root.recentNotes
                            delegate: ItemDelegate {
                                required property var modelData
                                required property int index
                                objectName: "homeNote-" + index
                                width: parent.width
                                height: Theme.rowHeight + 4
                                separator: index < root.recentNotes.length - 1
                                text: modelData.title
                                onClicked: root.resultChosen({kind: "note", id: modelData.id})
                            }
                        }
                    }
                    Label { visible: root.recentNotes.length === 0; text: "No notes yet"; color: Theme.textTertiary }
                }
                ColumnLayout {
                    objectName: "homeThreads"
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Layout.alignment: Qt.AlignTop
                    spacing: 6
                    Label { text: "Recent AI Conversations"; font.pixelSize: Theme.fontHeadline; font.weight: Font.DemiBold; Layout.preferredHeight: 32 }
                    ListGroup {
                        Layout.fillWidth: true
                        visible: root.recentThreads.length > 0
                        Repeater {
                            model: root.recentThreads
                            delegate: ItemDelegate {
                                required property var modelData
                                required property int index
                                objectName: "homeThread-" + index
                                width: parent.width
                                height: Theme.rowHeight + 4
                                separator: index < root.recentThreads.length - 1
                                text: modelData.title
                                onClicked: root.resultChosen({kind: "ai", id: modelData.id})
                            }
                        }
                    }
                    Label { visible: root.recentThreads.length === 0; text: "No conversations yet"; color: Theme.textTertiary }
                }
            }
        }
    }
    PaperMenu {
        id: recentMenu
        objectName: "recentPaperMenu"
        recent: true
        onOpenRequested: function(source, position) { root.documentChosen(source, position) }
    }
}
