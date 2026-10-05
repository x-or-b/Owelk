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
    ResearchSearch { id: searchModel; query: searchInput.text; active: root.visible }
    readonly property var continuation: researchStore.continueReading
    signal openRequested()
    signal libraryRequested()
    // An address or a web search typed on Home (opens a web tab).
    signal webRequested(string url)
    function searchWeb(text) {
        const url = Tree.addressToUrl(text, researchStore.setting("searchEngine", "https://scholar.google.com/scholar?q=%s"))
        if (url.length) webRequested(url)
        return url.length > 0
    }
    readonly property var deletedWorkspaces: (researchStore.recentWorkspaces, researchStore.deletedWorkspaces())
    Dialog {
        id: deletedDialog
        objectName: "deletedWorkspacesDialog"
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: 420
        modal: true
        title: "Deleted workspaces"
        standardButtons: Dialog.Close
        ColumnLayout {
            width: parent.width
            Label { Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: Theme.fontSmall; color: Theme.textTertiary; text: "Deleting a workspace only hides it. Restore brings back its papers, captures and layout." }
            Repeater {
                model: root.deletedWorkspaces
                delegate: RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    Label { Layout.fillWidth: true; text: modelData.name + "  ·  " + modelData.papers + " papers"; elide: Text.ElideRight; textFormat: Text.PlainText }
                    Button {
                        objectName: "restoreWorkspace-" + modelData.id
                        text: "Restore"
                        // Restoring removes this row; finish with the delegate before the list changes.
                        onClicked: {
                            const id = modelData.id
                            if (root.deletedWorkspaces.length === 1) deletedDialog.close()
                            Qt.callLater(function() { researchStore.restoreWorkspace(id) })
                        }
                    }
                }
            }
        }
    }
    signal documentChosen(url source, var position)
    signal workspaceChosen(string id)
    signal workspaceManageRequested(string id)
    signal workspaceCreated(string name)
    signal resultChosen(var result)
    function choose(result) { if (!searchModel.choose(result)) root.resultChosen(result) }
    function search() { searchModel.refresh(); searchResults.currentIndex = searchModel.selectionIndex() }
    onResultsChanged: {
        searchResults.currentIndex = searchModel.selectionIndex()
        if (searchResults.currentIndex >= 0) searchResults.positionViewAtIndex(searchResults.currentIndex, ListView.Contain)
    }
    function focusSearch() { searchInput.forceActiveFocus(); searchInput.selectAll() }
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
                    placeholderText: "Find PDF text, papers, captures or workspaces"
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
            Rectangle { Layout.fillWidth: true; height: 1; color: Theme.separator }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 8
                Label { text: "Continue Reading"; font.pixelSize: Theme.fontHeadline; font.weight: Font.DemiBold }
                RowLayout {
                    Layout.fillWidth: true
                    ColumnLayout {
                        Layout.fillWidth: true
                        Label {
                            Layout.fillWidth: true
                            text: root.continuation.name || "Start with a paper"
                            elide: Text.ElideMiddle
                        }
                        Label {
                            text: root.continuation.source ? "Page " + (((root.continuation.position || {}).page || 0) + 1) : "Open a PDF. Your reading position is saved automatically."
                            color: Theme.textTertiary
                            font.pixelSize: Theme.fontCaption
                        }
                    }
                    Button {
                        objectName: "continueReading"
                        text: root.continuation.source ? "Continue" : "Open PDF…"
                        onClicked: {
                            if (root.continuation.source) root.documentChosen(root.continuation.source, root.continuation.position)
                            else root.openRequested()
                        }
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; height: 1; color: Theme.separator }
            RowLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignTop
                spacing: 28
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Layout.alignment: Qt.AlignTop
                    spacing: 6
                    RowLayout {
                        Layout.fillWidth: true
                        Label { text: "Recent Workspaces"; font.pixelSize: Theme.fontHeadline; font.weight: Font.DemiBold }
                        Item { Layout.fillWidth: true }
                        IconButton {
                            objectName: "deletedWorkspacesButton"
                            visible: root.deletedWorkspaces.length > 0
                            icon.name: "trash"
                            description: "Deleted workspaces (" + root.deletedWorkspaces.length + ") · Restore"
                            onClicked: deletedDialog.open()
                        }
                        IconButton { icon.name: "add"; description: "New workspace"; onClicked: workspaceDialog.open() }
                    }
                    ListGroup {
                        Layout.fillWidth: true
                        visible: researchStore.recentWorkspaces.length > 0
                        Repeater {
                            model: researchStore.recentWorkspaces
                            delegate: ItemDelegate {
                                id: workspaceItem
                                required property var modelData
                                required property int index
                                width: parent.width
                                height: Theme.rowHeight + 4
                                separator: index < researchStore.recentWorkspaces.length - 1
                                text: modelData.name + "  ·  " + modelData.papers + " papers"
                                onClicked: root.workspaceChosen(modelData.id)
                                // Right-click for the workspace's actions.
                                TapHandler { acceptedButtons: Qt.RightButton; onTapped: workspaceMenu.popup() }
                                Menu {
                                    id: workspaceMenu
                                    objectName: "workspaceMenu"
                                    MenuItem { text: "Open"; onTriggered: root.workspaceChosen(workspaceItem.modelData.id) }
                                    MenuItem { objectName: "manageWorkspaceOption"; text: "Manage Links…"; onTriggered: root.workspaceManageRequested(workspaceItem.modelData.id) }
                                }
                            }
                        }
                    }
                    Label { visible: researchStore.recentWorkspaces.length === 0; text: "No workspaces yet"; color: Theme.textTertiary }
                    Label { Layout.fillWidth: true; text: "Keep papers, tabs and reading state together by topic."; wrapMode: Text.Wrap; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary }
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
                            description: "Library · All papers, collections and tags · " + Platform.keys("Ctrl+Shift+L")
                            onClicked: root.libraryRequested()
                        }
                    }
                    ListGroup {
                        Layout.fillWidth: true
                        visible: researchStore.recentDocuments.length > 0
                        Repeater {
                            model: researchStore.recentDocuments
                            delegate: RecentPaperDelegate {
                                required property int index
                                width: parent.width
                                height: Theme.rowHeight + 4
                                separator: index < researchStore.recentDocuments.length - 1
                                onDocumentChosen: function(source, position) { root.documentChosen(source, position) }
                            }
                        }
                    }
                    Label { visible: researchStore.recentDocuments.length === 0; text: "No recent papers"; color: Theme.textTertiary }
                }
            }
        }
    }
    Dialog {
        id: workspaceDialog
        parent: Overlay.overlay
        anchors.centerIn: parent
        title: "New workspace"
        modal: true
        standardButtons: Dialog.Ok | Dialog.Cancel
        onOpened: { workspaceName.clear(); workspaceName.forceActiveFocus() }
        TextField { id: workspaceName; placeholderText: "Workspace name"; maximumLength: 120; onAccepted: workspaceDialog.accept() }
        onAccepted: root.workspaceCreated(workspaceName.text)
    }
}
