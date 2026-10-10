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
    // What Home lists, last opened first; read again when papers, notes or conversations change (and when shown).
    property var recentCollections: []
    property var recentNotes: []
    property var recentThreads: []
    function refreshLists() {
        if (!visible) return
        recentCollections = researchStore.recentItems("collection", 50)
        recentNotes = researchStore.recentItems("note", 50)
        recentThreads = researchStore.recentItems("ai", 50)
    }
    signal newNoteRequested()
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
    // A list in a slot of fixed height (rows rows): the rounded box grows with its rows up to the slot,
    // then scrolls, so the page keeps its layout however long each list is.
    readonly property real rowStep: Theme.rowHeight + 4
    component ListBox: Item {
        id: slot
        property alias model: boxList.model
        property alias delegate: boxList.delegate
        property string empty: ""
        property int rows: 7
        Layout.fillWidth: true
        Layout.preferredHeight: rows * root.rowStep + rows - 1 + 8
        Rectangle {
            width: parent.width
            height: boxList.count ? Math.min(slot.height, boxList.contentHeight + 8) : root.rowStep + 8
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
            Label { anchors.centerIn: parent; visible: boxList.count === 0; text: slot.empty; color: Theme.textTertiary }
        }
    }
    // A box heading, with an optional + on the right.
    component BoxHeading: RowLayout {
        property alias text: heading.text
        property alias adding: add.visible
        property alias addDescription: add.description
        signal added()
        Layout.fillWidth: true
        Label { id: heading; font.pixelSize: Theme.fontHeadline; font.weight: Font.DemiBold; Layout.preferredHeight: 32; Layout.fillWidth: true }
        IconButton { id: add; visible: false; icon.name: "add"; onClicked: parent.added() }
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
                SearchFilters { Layout.fillWidth: true; controller: searchModel }
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
                // Only while PDFs are being indexed or some cannot be read (details in Settings › Search).
                IndexStatus { Layout.fillWidth: true; quiet: true }
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
                // Starting points: a PDF from disk, or the Library for the whole collection.
                RowLayout {
                    spacing: 6
                    Button { objectName: "homeOpenPdf"; flat: true; text: "Open PDF…"; onClicked: root.openRequested() }
                    Button { objectName: "homeOpenLibrary"; flat: true; text: "Library"; onClicked: root.libraryRequested() }
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
            // Collections and recent papers, then notes and AI conversations; all last opened first.
            GridLayout {
                Layout.fillWidth: true
                columns: 2
                columnSpacing: 28
                rowSpacing: 18
                ColumnLayout {
                    objectName: "homeCollections"
                    Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.alignment: Qt.AlignTop
                    spacing: 6
                    BoxHeading { text: "Collections" }
                    ListBox {
                        model: root.recentCollections
                        empty: "No collections yet"
                        delegate: ItemDelegate {
                            required property var modelData
                            required property int index
                            objectName: "homeCollection-" + index
                            width: ListView.view.width
                            height: root.rowStep
                            separator: index < root.recentCollections.length - 1
                            rightPadding: 40
                            text: modelData.name
                            onClicked: root.libraryFilterRequested({collection: modelData.id})
                            Label {
                                anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                                text: parent.modelData.count; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
                            }
                        }
                    }
                }
                ColumnLayout {
                    Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.alignment: Qt.AlignTop
                    spacing: 6
                    BoxHeading { text: "Recent Papers" }
                    ListBox {
                        model: researchStore.recentDocuments
                        empty: "No recent papers"
                        delegate: RecentPaperDelegate {
                            required property int index
                            width: ListView.view.width
                            height: root.rowStep
                            separator: index < researchStore.recentDocuments.length - 1
                            onDocumentChosen: function(source, position) { root.documentChosen(source, position) }
                            onMenuRequested: function(row) { recentMenu.show(row) }
                        }
                    }
                }
                ColumnLayout {
                    objectName: "homeNotes"
                    Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.alignment: Qt.AlignTop
                    spacing: 6
                    BoxHeading { objectName: "homeNotesHeading"; text: "Notes"; adding: true; addDescription: "New note"; onAdded: root.newNoteRequested() }
                    ListBox {
                        rows: 5
                        model: root.recentNotes
                        empty: "No notes yet"
                        delegate: ItemDelegate {
                            required property var modelData
                            required property int index
                            objectName: "homeNote-" + index
                            width: ListView.view.width
                            height: root.rowStep
                            separator: index < root.recentNotes.length - 1
                            text: modelData.title
                            onClicked: root.resultChosen({kind: "note", id: modelData.id})
                        }
                    }
                }
                ColumnLayout {
                    objectName: "homeThreads"
                    Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.alignment: Qt.AlignTop
                    spacing: 6
                    BoxHeading { text: "AI Conversations" }
                    ListBox {
                        rows: 5
                        model: root.recentThreads
                        empty: "No conversations yet"
                        // The question, and the paper it was about.
                        delegate: ItemDelegate {
                            id: threadRow
                            required property var modelData
                            required property int index
                            objectName: "homeThread-" + index
                            width: ListView.view.width
                            height: root.rowStep
                            separator: index < root.recentThreads.length - 1
                            text: modelData.title
                            onClicked: root.resultChosen({kind: "ai", id: modelData.id})
                            contentItem: RowLayout {
                                spacing: 8
                                Label { Layout.fillWidth: true; text: threadRow.modelData.title; elide: Text.ElideRight; textFormat: Text.PlainText; color: Theme.text }
                                Label {
                                    visible: text.length > 0
                                    Layout.maximumWidth: threadRow.width * .4
                                    text: threadRow.modelData.paper || ""
                                    elide: Text.ElideRight; textFormat: Text.PlainText; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
                                }
                            }
                        }
                    }
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
