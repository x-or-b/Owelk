import QtQuick

// An AI conversation in a tab: the AI panel's view with a controller of its own, bound to the tab's conversation.
// Answers and waiting questions are shared with every other view of it (AiRuns), so the panel and the tab show the
// same conversation as it goes; what is typed but not sent, and what is attached to it, stay in each.
Item {
    id: root
    property var workspace: null
    property string threadId: ""
    readonly property alias controller: chat
    signal activated()
    AiController {
        id: chat
        workspace: root.workspace
        runs: root.workspace ? root.workspace.aiRuns : null
    }
    // Another chat tab of the strip in front reuses this view.
    function show() { if (threadId.length && chat.threadId !== threadId) chat.openThread(threadId) }
    onThreadIdChanged: show()
    Component.onCompleted: show()
    AiPanel {
        objectName: "aiTabPanel"
        anchors.fill: parent
        controller: chat
        inTab: true
        onLinkActivated: function(link) { if (root.workspace) root.workspace.openLink(link) }
        onSettingsRequested: if (root.workspace) root.workspace.settingsRequested("ai")
    }
    TapHandler { onPressedChanged: if (pressed) root.activated() }
}
