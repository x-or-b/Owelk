import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    objectName: "homeView"
    color: "#fafafa"
    property var results: []
    readonly property var continuation: researchStore.continueReading
    signal openRequested()
    signal documentChosen(url source, var position)
    signal workspaceChosen(string id)
    signal workspaceCreated(string name)
    signal resultChosen(var result)
    function search() { results = researchStore.searchKnowledge(query.text); searchResults.currentIndex = results.length ? 0 : -1 }
    function focusSearch() { query.forceActiveFocus(); query.selectAll() }
    Timer { id: searchDelay; interval: 150; onTriggered: root.search() }
    Connections { target: researchStore; function onHomeChanged() { if (query.text.length) searchDelay.restart() } }
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
                    id: query
                    objectName: "homeSearch"
                    Layout.fillWidth: true
                    implicitHeight: 40
                    placeholderText: "Find papers, captures or workspaces"
                    selectByMouse: true
                    onTextChanged: searchDelay.restart()
                    onAccepted: {
                        const chosenIndex = searchResults.currentIndex
                        searchDelay.stop()
                        root.search()
                        if (root.results.length) root.resultChosen(root.results[Math.max(0, Math.min(chosenIndex, root.results.length - 1))])
                    }
                    Keys.onDownPressed: searchResults.currentIndex = Math.min(root.results.length - 1, searchResults.currentIndex + 1)
                    Keys.onUpPressed: searchResults.currentIndex = Math.max(0, searchResults.currentIndex - 1)
                    Keys.onEscapePressed: clear()
                }
                Label { text: "Paper names · Capture sources · Workspace names"; font.pixelSize: 11; color: "#777777" }
                ListView {
                    id: searchResults
                    objectName: "homeResults"
                    visible: query.text.trim().length > 0
                    Layout.fillWidth: true
                    Layout.preferredHeight: visible ? Math.max(1, Math.min(count, 5)) * 44 : 0
                    clip: true
                    model: root.results
                    ScrollBar.vertical: ScrollBar {}
                    delegate: ItemDelegate {
                        required property int index
                        required property var modelData
                        width: searchResults.width
                        height: 44
                        highlighted: searchResults.currentIndex === index
                        text: modelData.kind.toUpperCase() + "   " + modelData.title
                        onClicked: root.resultChosen(modelData)
                    }
                    Label { anchors.centerIn: parent; visible: searchResults.count === 0; text: "No matching saved items"; color: "#777777" }
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
                    Label { Layout.fillWidth: true; text: "Keep papers and reading state together by topic."; wrapMode: Text.Wrap; font.pixelSize: 11; color: "#777777" }
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Layout.alignment: Qt.AlignTop
                    spacing: 6
                    Label { text: "Recent Papers"; font.pixelSize: 14; font.weight: Font.DemiBold; Layout.preferredHeight: 32 }
                    Repeater {
                        model: researchStore.recentDocuments
                        delegate: ItemDelegate {
                            required property var modelData
                            Layout.fillWidth: true
                            implicitHeight: 44
                            text: modelData.name
                            onClicked: root.documentChosen(modelData.url, modelData.position)
                            ToolTip.visible: hovered
                            ToolTip.text: modelData.url.toString()
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
