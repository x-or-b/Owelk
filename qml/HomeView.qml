import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    objectName: "homeView"
    color: "#fafafa"
    property alias results: searchModel.results
    ResearchSearch { id: searchModel; query: searchInput.text; active: root.visible }
    readonly property var continuation: researchStore.continueReading
    signal openRequested()
    signal documentChosen(url source, var position)
    signal workspaceChosen(string id)
    signal workspaceCreated(string name)
    signal resultChosen(var result)
    function search() { searchModel.refresh(); searchResults.currentIndex = results.length ? 0 : -1 }
    onResultsChanged: searchResults.currentIndex = results.length ? 0 : -1
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
                Label { text: "Search your research"; font.pixelSize: 22; font.weight: Font.Medium; color: "#333333" }
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
                        if (root.results.length) root.resultChosen(root.results[Math.max(0, Math.min(chosenIndex, root.results.length - 1))])
                    }
                    Keys.onDownPressed: searchResults.currentIndex = Math.min(root.results.length - 1, searchResults.currentIndex + 1)
                    Keys.onUpPressed: searchResults.currentIndex = Math.max(0, searchResults.currentIndex - 1)
                    Keys.onEscapePressed: clear()
                }
                Label { text: "PDF text · Paper names · Capture sources · Workspace names"; font.pixelSize: 11; color: "#777777" }
                IndexStatus { Layout.fillWidth: true }
                Label { Layout.fillWidth: true; visible: searchModel.error.length > 0; text: "PDF text search failed: " + searchModel.error; textFormat: Text.PlainText; wrapMode: Text.Wrap; font.pixelSize: 11; color: "#777777" }
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
                        onClicked: root.resultChosen(modelData)
                    }
                    Label { anchors.centerIn: parent; visible: searchResults.count === 0; text: searchModel.waiting ? "Searching PDF text…" : searchModel.error.length ? "Text search failed. Try again." : "No matching saved items"; color: "#777777" }
                }
            }
            Rectangle { Layout.fillWidth: true; height: 1; color: "#dddddd" }
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
                            color: "#777777"
                            font.pixelSize: 11
                        }
                    }
                    Button {
                        objectName: "continueReading"
                        text: root.continuation.source ? "Continue →" : "Open PDF…"
                        onClicked: {
                            if (root.continuation.source) root.documentChosen(root.continuation.source, root.continuation.position)
                            else root.openRequested()
                        }
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; height: 1; color: "#dddddd" }
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
                        ToolButton { text: "+"; onClicked: workspaceDialog.open(); Accessible.name: "New workspace"; ToolTip.visible: hovered; ToolTip.text: "New workspace" }
                    }
                    Repeater {
                        model: researchStore.recentWorkspaces
                        delegate: ItemDelegate {
                            required property var modelData
                            Layout.fillWidth: true
                            implicitHeight: 44
                            text: modelData.name + "  ·  " + modelData.papers + " papers"
                            onClicked: root.workspaceChosen(modelData.id)
                        }
                    }
                    Label { visible: researchStore.recentWorkspaces.length === 0; text: "No workspaces yet"; color: "#777777" }
                    Label { Layout.fillWidth: true; text: "Keep papers, tabs and reading state together by topic."; wrapMode: Text.Wrap; font.pixelSize: 11; color: "#777777" }
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Layout.alignment: Qt.AlignTop
                    spacing: 6
                    Label { text: "Recent Papers"; font.pixelSize: 14; font.weight: Font.DemiBold; Layout.preferredHeight: 32 }
                    Repeater {
                        model: researchStore.recentDocuments
                        delegate: RecentPaperDelegate {
                            Layout.fillWidth: true
                            implicitHeight: 44
                            onDocumentChosen: function(source, position) { root.documentChosen(source, position) }
                        }
                    }
                    Label { visible: researchStore.recentDocuments.length === 0; text: "No recent papers"; color: "#777777" }
                    Button { text: "Open PDF…"; onClicked: root.openRequested() }
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
