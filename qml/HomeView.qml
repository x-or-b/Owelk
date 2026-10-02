import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "UiTheme.js" as Theme
import "WorkspaceTree.js" as Tree

Rectangle {
    id: root
    objectName: "homeView"
    color: Theme.surfacePanel
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
    UiControls.Dialog {
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
            Label { Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: 12; color: Theme.textTertiary; text: "Deleting a workspace only hides it. Restore brings back its papers, captures and layout." }
            Repeater {
                model: root.deletedWorkspaces
                delegate: RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    Label { Layout.fillWidth: true; text: modelData.name + "  ·  " + modelData.papers + " papers"; elide: Text.ElideRight; textFormat: Text.PlainText }
                    UiControls.Button {
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
                Label { text: "Search your research"; font.pixelSize: 22; font.weight: Font.Medium; color: Theme.textBody }
                UiControls.TextField {
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
                UiControls.TextField {
                    id: webInput
                    objectName: "homeWebSearch"
                    Layout.fillWidth: true
                    implicitHeight: 34
                    leftPadding: 30
                    placeholderText: "Search the web or enter an address  ·  " + (researchStore.setting("searchEngine", "").indexOf("google.com/search") >= 0 ? "Google" : researchStore.setting("searchEngine", "").indexOf("duckduckgo") >= 0 ? "DuckDuckGo" : researchStore.setting("searchEngine", "").indexOf("arxiv") >= 0 ? "arXiv" : "Google Scholar")
                    selectByMouse: true
                    font.pixelSize: 13
                    onAccepted: if (root.searchWeb(text)) clear()
                    Keys.onEscapePressed: clear()
                    // A globe: the web, not the library.
                    Canvas {
                        x: 9; anchors.verticalCenter: parent.verticalCenter
                        width: 14; height: 14
                        onPaint: {
                            const c = getContext("2d"); c.reset()
                            c.strokeStyle = Theme.icon; c.lineWidth = 1.1
                            c.beginPath(); c.arc(7, 7, 6, 0, Math.PI * 2)
                            c.moveTo(1, 7); c.lineTo(13, 7)
                            c.moveTo(7, 1); c.bezierCurveTo(3, 4, 3, 10, 7, 13); c.moveTo(7, 1); c.bezierCurveTo(11, 4, 11, 10, 7, 13)
                            c.stroke()
                        }
                    }
                }
                IndexStatus { Layout.fillWidth: true }
                Label { Layout.fillWidth: true; visible: searchModel.error.length > 0; text: "PDF text search failed: " + searchModel.error; textFormat: Text.PlainText; wrapMode: Text.Wrap; font.pixelSize: 11; color: Theme.textMuted }
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
                    Label { anchors.centerIn: parent; visible: searchResults.count === 0; text: searchModel.waiting ? "Searching PDF text…" : searchModel.error.length ? "Text search failed. Try again." : "No matching saved items"; color: Theme.textMuted }
                }
            }
            Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 8
                Label { text: "Continue Reading"; font.pixelSize: 14; font.weight: Font.DemiBold }
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
                            color: Theme.textMuted
                            font.pixelSize: 11
                        }
                    }
                    UiControls.Button {
                        objectName: "continueReading"
                        text: root.continuation.source ? "Continue →" : "Open PDF…"
                        onClicked: {
                            if (root.continuation.source) root.documentChosen(root.continuation.source, root.continuation.position)
                            else root.openRequested()
                        }
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }
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
                        Label { text: "Recent Workspaces"; font.pixelSize: 14; font.weight: Font.DemiBold }
                        Item { Layout.fillWidth: true }
                        UiControls.ToolButton {
                            objectName: "deletedWorkspacesButton"
                            visible: root.deletedWorkspaces.length > 0
                            text: "Deleted (" + root.deletedWorkspaces.length + ")"
                            font.pixelSize: 12
                            ToolTip.visible: hovered; ToolTip.delay: 450; ToolTip.text: "Restore a deleted workspace"
                            onClicked: deletedDialog.open()
                        }
                        UiControls.ToolButton { text: "+"; onClicked: workspaceDialog.open(); Accessible.name: "New workspace"; ToolTip.visible: hovered; ToolTip.text: "New workspace" }
                    }
                    Repeater {
                        model: researchStore.recentWorkspaces
                        delegate: UiControls.ItemDelegate {
                            id: workspaceItem
                            required property var modelData
                            Layout.fillWidth: true
                            implicitHeight: 44
                            text: modelData.name + "  ·  " + modelData.papers + " papers"
                            rightPadding: 36
                            UiControls.ToolButton {
                                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                width: 32; text: "…"; Accessible.name: "Manage workspace"
                                onClicked: root.workspaceManageRequested(workspaceItem.modelData.id)
                                ToolTip.visible: hovered; ToolTip.text: "Open workspace and manage links"
                            }
                            onClicked: root.workspaceChosen(modelData.id)
                        }
                    }
                    Label { visible: researchStore.recentWorkspaces.length === 0; text: "No workspaces yet"; color: Theme.textMuted }
                    Label { Layout.fillWidth: true; text: "Keep papers, tabs and reading state together by topic."; wrapMode: Text.Wrap; font.pixelSize: 11; color: Theme.textMuted }
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Layout.alignment: Qt.AlignTop
                    spacing: 6
                    RowLayout {
                        Layout.fillWidth: true
                        Label { text: "Recent Papers"; font.pixelSize: 14; font.weight: Font.DemiBold; Layout.preferredHeight: 32; Layout.fillWidth: true }
                        UiControls.ToolButton {
                            objectName: "openLibraryButton"; text: "Library"
                            ToolTip.visible: hovered; ToolTip.delay: 450
                            ToolTip.text: "All papers, collections and tags (" + (Qt.platform.os === "osx" ? "⇧⌘L" : "Ctrl+Shift+L") + ")"
                            onClicked: root.libraryRequested()
                        }
                    }
                    Repeater {
                        model: researchStore.recentDocuments
                        delegate: RecentPaperDelegate {
                            Layout.fillWidth: true
                            implicitHeight: 44
                            onDocumentChosen: function(source, position) { root.documentChosen(source, position) }
                        }
                    }
                    Label { visible: researchStore.recentDocuments.length === 0; text: "No recent papers"; color: Theme.textMuted }
                    UiControls.Button { text: "Open PDF…"; onClicked: root.openRequested() }
                }
            }
        }
    }
    UiControls.Dialog {
        id: workspaceDialog
        parent: Overlay.overlay
        anchors.centerIn: parent
        title: "New workspace"
        modal: true
        standardButtons: Dialog.Ok | Dialog.Cancel
        onOpened: { workspaceName.clear(); workspaceName.forceActiveFocus() }
        UiControls.TextField { id: workspaceName; placeholderText: "Workspace name"; maximumLength: 120; onAccepted: workspaceDialog.accept() }
        onAccepted: root.workspaceCreated(workspaceName.text)
    }
}
