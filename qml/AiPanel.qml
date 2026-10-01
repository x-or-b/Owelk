import "UiTheme.js" as Theme
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Dock panel for the AI: saved threads, the open conversation, and the composer with the model menu.
Item {
    id: root
    objectName: "aiPanel"
    property var controller: null
    readonly property var c: controller
    readonly property bool showingThreads: !c || !c.conversationOpen
    signal linkActivated(string link)
    function focusQuestion() { question.forceActiveFocus() }
    Connections { target: root.c; function onFocusRequested() { root.focusQuestion() } }
    Component.onCompleted: if (c && c.spec.action === "ask" && !c.streaming) question.forceActiveFocus()
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 8
        spacing: 6
        RowLayout {
            Layout.fillWidth: true
            spacing: 2
            ReaderIconButton {
                objectName: "aiThreadsButton"
                kind: "back"; description: "All threads"
                visible: !root.showingThreads
                onClicked: root.c.showThreads()
            }
            Label {
                objectName: "aiThreadTitle"
                Layout.fillWidth: true
                text: root.showingThreads ? "Threads" : (root.c.thread.title || "New thread")
                elide: Text.ElideRight; textFormat: Text.PlainText
                font.pixelSize: 13; font.weight: Font.DemiBold; color: Theme.text
            }
            ReaderIconButton { objectName: "aiNewThread"; kind: "plus"; description: "New thread"; onClicked: { root.c.newThread(); root.focusQuestion() } }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }
        // Saved threads, newest first.
        ListView {
            id: threadList
            objectName: "aiThreadList"
            visible: root.showingThreads
            Layout.fillWidth: true; Layout.fillHeight: true
            clip: true
            spacing: 2
            model: researchStore.aiThreads()
            Connections { target: researchStore; function onAiThreadsChanged() { threadList.model = researchStore.aiThreads() } }
            delegate: Rectangle {
                id: row
                required property var modelData
                required property int index
                objectName: "aiThread-" + index
                width: ListView.view.width
                height: 44
                radius: Theme.cornerRadius
                color: rowHover.hovered ? Theme.surfaceSelected : "transparent"
                HoverHandler { id: rowHover }
                TapHandler { acceptedButtons: Qt.LeftButton; onTapped: { const id = row.modelData.id; Qt.callLater(function() { root.c.openThread(id) }) } }
                TapHandler { acceptedButtons: Qt.RightButton; onTapped: threadMenu.popup() }
                ColumnLayout {
                    anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                    spacing: 1
                    Label { Layout.fillWidth: true; text: row.modelData.title; elide: Text.ElideRight; textFormat: Text.PlainText; color: Theme.text; font.pixelSize: 12 }
                    Label {
                        Layout.fillWidth: true
                        text: Math.ceil(row.modelData.messages / 2) + (row.modelData.messages > 2 ? " turns" : " turn") + " · " + row.modelData.model
                        elide: Text.ElideRight; textFormat: Text.PlainText; color: Theme.textTertiary; font.pixelSize: 11
                    }
                }
                UiControls.Menu {
                    id: threadMenu
                    UiControls.MenuItem { text: "Rename…"; onTriggered: { renameDialog.threadId = row.modelData.id; renameField.text = row.modelData.title; renameDialog.open() } }
                    UiControls.MenuItem { text: "Delete"; onTriggered: { const id = row.modelData.id; Qt.callLater(function() { root.c.deleteThread(id) }) } }
                }
            }
            Label {
                anchors.centerIn: parent
                width: parent.width - 16
                visible: threadList.count === 0
                text: "Ask about a selection, page or figure, or start a new thread with +."
                wrapMode: Text.Wrap; horizontalAlignment: Text.AlignHCenter
                color: Theme.textTertiary; font.pixelSize: 12
            }
        }
        // The conversation: earlier turns, then the streaming answer.
        ListView {
            id: conversation
            objectName: "aiConversation"
            visible: !root.showingThreads
            Layout.fillWidth: true; Layout.fillHeight: true
            clip: true
            spacing: 10
            model: root.c ? root.c.messages : []
            onCountChanged: Qt.callLater(positionViewAtEnd)
            delegate: ColumnLayout {
                id: message
                required property var modelData
                required property int index
                width: ListView.view.width
                spacing: 4
                Rectangle {
                    visible: message.modelData.role === "user"
                    Layout.fillWidth: true
                    implicitHeight: userText.implicitHeight + 12
                    radius: Theme.cornerRadius; color: Theme.surfaceAlt
                    Label {
                        id: userText
                        anchors.fill: parent; anchors.margins: 6
                        text: message.modelData.display; wrapMode: Text.Wrap; textFormat: Text.PlainText
                        color: Theme.text; font.pixelSize: 12
                    }
                }
                Text {
                    visible: message.modelData.role === "assistant"
                    objectName: "aiMessage-" + message.index
                    Layout.fillWidth: true
                    text: visible ? researchStore.markdownHtml(message.modelData.content, Theme.accent) : ""
                    textFormat: Text.RichText; wrapMode: Text.Wrap
                    color: Theme.textBody; font.pixelSize: 13
                    onLinkActivated: function(link) { root.linkActivated(link) }
                }
                RowLayout {
                    visible: message.modelData.role === "assistant"
                    spacing: 0
                    UiControls.ToolButton { text: "Copy"; font.pixelSize: 11; implicitHeight: 22; onClicked: researchStore.copyText(message.modelData.content) }
                    UiControls.ToolButton {
                        objectName: "aiSaveNote-" + message.index
                        text: "Save as Note"; font.pixelSize: 11; implicitHeight: 22
                        onClicked: root.c.saveAsNote(message.index)
                    }
                }
            }
            footer: ColumnLayout {
                width: conversation.width
                spacing: 4
                Rectangle {
                    visible: root.c && root.c.pendingQuestion.length > 0
                    Layout.fillWidth: true; Layout.topMargin: 10
                    implicitHeight: pendingText.implicitHeight + 12
                    radius: Theme.cornerRadius; color: Theme.surfaceAlt
                    Label { id: pendingText; anchors.fill: parent; anchors.margins: 6; text: root.c ? root.c.pendingQuestion : ""; wrapMode: Text.Wrap; textFormat: Text.PlainText; color: Theme.text; font.pixelSize: 12 }
                }
                Text {
                    objectName: "aiAnswer"
                    visible: root.c && (root.c.streaming || root.c.answer.length > 0)
                    Layout.fillWidth: true
                    text: !root.c ? "" : root.c.answer.length ? researchStore.markdownHtml(root.c.answer, Theme.accent) : "<i>Thinking…</i>"
                    textFormat: Text.RichText; wrapMode: Text.Wrap
                    color: Theme.textBody; font.pixelSize: 13
                    onTextChanged: Qt.callLater(conversation.positionViewAtEnd)
                }
                Label {
                    objectName: "aiError"
                    visible: root.c && root.c.error.length > 0
                    Layout.fillWidth: true; Layout.topMargin: 6
                    text: root.c ? root.c.error : ""; wrapMode: Text.Wrap; textFormat: Text.PlainText
                    color: Theme.danger; font.pixelSize: 12
                }
            }
        }
        // Attachments for the next turn; × removes one.
        Flow {
            Layout.fillWidth: true
            spacing: 4
            visible: root.c && root.c.attachments.length > 0
            Repeater {
                model: root.c ? root.c.attachments : []
                delegate: Rectangle {
                    required property var modelData
                    height: 22; width: Math.min(chip.implicitWidth + (modelData.kind === "paper" ? 12 : 30), root.width - 16)
                    radius: Theme.cornerRadius; color: Theme.surfaceAlt; border.color: Theme.border
                    Label { id: chip; x: 6; anchors.verticalCenter: parent.verticalCenter; width: parent.width - (modelData.kind === "paper" ? 12 : 28); text: modelData.label; elide: Text.ElideRight; maximumLineCount: 1; textFormat: Text.PlainText; font.pixelSize: 11; color: Theme.textSecondary }
                    Label {
                        visible: modelData.kind !== "paper"
                        anchors.right: parent.right; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter
                        text: "×"; color: Theme.textTertiary; font.pixelSize: 12
                        TapHandler { onTapped: root.c.detach(modelData.kind) }
                    }
                }
            }
        }
        UiControls.TextArea {
            id: question
            objectName: "aiQuestion"
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(140, Math.max(56, implicitHeight))
            placeholderText: root.c && root.c.threadId.length ? "Ask a follow-up…" : "Ask about the paper…"
            wrapMode: TextEdit.Wrap
            font.pixelSize: 12
            // Return sends, Shift+Return adds a line.
            Keys.onPressed: function(event) {
                if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !(event.modifiers & Qt.ShiftModifier)) {
                    if (!root.c.streaming && root.c.send(text)) text = ""
                    event.accepted = true
                }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 4
            UiControls.ToolButton {
                id: attachButton
                objectName: "aiAttachButton"
                text: "+ Context"; font.pixelSize: 11; implicitHeight: 24
                enabled: root.c && root.c.reader !== null
                onClicked: attachMenu.popup(attachButton, 0, -attachMenu.implicitHeight)
                UiControls.Menu {
                    id: attachMenu
                    UiControls.MenuItem { objectName: "aiAttachPage"; text: "Current Page"; onTriggered: root.c.attach("page") }
                    UiControls.MenuItem { text: "Selection"; enabled: root.c && root.c.reader && root.c.reader.selectedText.length > 0; onTriggered: root.c.attach("selection") }
                    UiControls.MenuItem { text: "Whole Paper"; onTriggered: root.c.attach("paper") }
                }
            }
            // Provider · model; opens the list of models each set-up provider offers.
            UiControls.ToolButton {
                id: modelButton
                objectName: "aiModelButton"
                Layout.fillWidth: true
                Layout.maximumWidth: implicitWidth
                implicitHeight: 24
                font.pixelSize: 11
                text: (root.c ? root.c.providerInfo.name || "" : "") + " · " + (root.c ? root.c.ai.model(root.c.ai.provider) : "") + " ▾"
                contentItem: Label { text: modelButton.text; elide: Text.ElideRight; font: modelButton.font; color: Theme.textSecondary; verticalAlignment: Text.AlignVCenter }
                hoverEnabled: true
                ToolTip.visible: hovered; ToolTip.delay: 450
                ToolTip.text: root.c && root.c.providerInfo.kind === "local" ? "Stays on this Mac" : "Sent to " + (root.c ? root.c.providerInfo.sends || "" : "")
                onClicked: { root.c.loadModels(); modelMenu.open() }
            }
            Item { Layout.fillWidth: true }
            UiControls.Button {
                objectName: "aiSend"
                text: root.c && root.c.streaming ? "Stop" : "Send"
                highlighted: !(root.c && root.c.streaming)
                implicitHeight: 26
                onClicked: {
                    if (root.c.streaming) root.c.stop()
                    else if (root.c.send(question.text)) question.text = ""
                }
            }
        }
    }
    UiControls.Popup {
        id: modelMenu
        objectName: "aiModelMenu"
        parent: modelButton
        y: -height - 4
        width: Math.max(220, Math.min(300, root.width))
        height: Math.min(420, modelColumn.implicitHeight + 16)
        padding: 8
        background: Rectangle { color: Theme.surfacePanel; border.color: Theme.borderPopup; radius: Theme.cornerRadius }
        contentItem: Flickable {
            clip: true
            contentHeight: modelColumn.implicitHeight
            ColumnLayout {
                id: modelColumn
                width: parent.width
                spacing: 1
                Repeater {
                    model: root.c ? root.c.ai.providers : []
                    delegate: ColumnLayout {
                        id: providerSection
                        required property var modelData
                        readonly property var list: root.c.models[modelData.id] || []
                        readonly property bool usable: modelData.configured || modelData.id === "ollama"
                        Layout.fillWidth: true
                        spacing: 1
                        Label { text: providerSection.modelData.name; font.pixelSize: 11; font.weight: Font.DemiBold; color: Theme.textTertiary; Layout.topMargin: 4 }
                        Label {
                            visible: !providerSection.usable || providerSection.list.length === 0
                            text: providerSection.usable ? "Loading…" : "Set up in Settings → AI"
                            font.pixelSize: 11; color: Theme.textMuted; Layout.leftMargin: 8
                        }
                        Repeater {
                            model: providerSection.usable ? providerSection.list : []
                            delegate: UiControls.ItemDelegate {
                                required property var modelData
                                readonly property bool current: root.c.ai.provider === providerSection.modelData.id && root.c.ai.model(providerSection.modelData.id) === modelData.id
                                objectName: "aiModel-" + providerSection.modelData.id + "-" + modelData.id
                                Layout.fillWidth: true
                                implicitHeight: 26
                                text: modelData.name
                                font.pixelSize: 12
                                highlighted: current
                                // Choosing rebuilds this list (the provider list changes), so act after the handler returns.
                                onClicked: {
                                    const provider = providerSection.modelData.id, model = modelData.id, controller = root.c
                                    modelMenu.close()
                                    Qt.callLater(function() { controller.chooseModel(provider, model) })
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    UiControls.Dialog {
        id: renameDialog
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: 360
        modal: true
        title: "Rename Thread"
        property string threadId: ""
        standardButtons: Dialog.Ok | Dialog.Cancel
        UiControls.TextField { id: renameField; objectName: "aiRenameField"; width: parent.width; onAccepted: renameDialog.accept() }
        onAccepted: root.c.renameThread(threadId, renameField.text)
    }
}
