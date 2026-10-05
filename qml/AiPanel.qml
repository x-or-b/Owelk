import Owelk.Ui
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs as Native

// Dock panel for the AI: saved threads, the open conversation, and the composer with the model menu.
Item {
    id: root
    objectName: "aiPanel"
    property var controller: null
    readonly property var c: controller
    readonly property bool showingThreads: !c || !c.conversationOpen
    signal linkActivated(string link)
    signal settingsRequested()
    function focusQuestion() { question.forceActiveFocus() }
    Connections { target: root.c; function onFocusRequested() { root.focusQuestion() } }
    Component.onCompleted: if (c && c.spec.action === "ask" && !c.streaming) question.forceActiveFocus()
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 8
        spacing: 6
        RowLayout {
            Layout.fillWidth: true; Layout.minimumWidth: 0
            spacing: 2
            IconButton {
                objectName: "aiThreadsButton"
                icon.name: "back"; description: "All threads"
                visible: !root.showingThreads
                onClicked: root.c.showThreads()
            }
            Label {
                objectName: "aiThreadTitle"
                Layout.fillWidth: true; Layout.minimumWidth: 0
                text: root.showingThreads ? "Threads" : (root.c.thread.title || "New thread")
                elide: Text.ElideRight; textFormat: Text.PlainText
                font.pixelSize: Theme.fontBody; font.weight: Font.DemiBold; color: Theme.text
            }
            IconButton { objectName: "aiNewThread"; icon.name: "add"; description: "New thread"; onClicked: { root.c.newThread(); root.focusQuestion() } }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.separator }
        // Saved threads, newest first.
        ListView {
            id: threadList
            objectName: "aiThreadList"
            Layout.minimumWidth: 0
            visible: root.showingThreads
            Layout.fillWidth: true; Layout.fillHeight: true
            clip: true
            spacing: 0
            model: researchStore.aiThreads()
            Connections { target: researchStore; function onAiThreadsChanged() { threadList.model = researchStore.aiThreads() } }
            delegate: ItemDelegate {
                id: row
                required property var modelData
                required property int index
                objectName: "aiThread-" + index
                width: ListView.view.width
                height: Theme.rowHeightTall
                separator: index < threadList.count - 1
                onClicked: { const id = row.modelData.id; Qt.callLater(function() { root.c.openThread(id) }) }
                TapHandler { acceptedButtons: Qt.RightButton; onTapped: threadMenu.popup() }
                contentItem: ColumnLayout {
                    spacing: 1
                    Label { Layout.fillWidth: true; text: row.modelData.title; elide: Text.ElideRight; textFormat: Text.PlainText; color: Theme.text }
                    Label {
                        Layout.fillWidth: true
                        text: Math.ceil(row.modelData.messages / 2) + (row.modelData.messages > 2 ? " turns" : " turn") + " · " + row.modelData.model
                        elide: Text.ElideRight; textFormat: Text.PlainText; color: Theme.textTertiary; font.pixelSize: Theme.fontCaption
                    }
                }
                Menu {
                    id: threadMenu
                    MenuItem { text: "Rename…"; onTriggered: { renameDialog.threadId = row.modelData.id; renameField.text = row.modelData.title; renameDialog.open() } }
                    MenuSeparator {}
                    MenuItem {
                        objectName: "deleteThreadOption"
                        text: "Delete Thread…"
                        palette.windowText: Theme.danger
                        onTriggered: { deleteDialog.threadId = row.modelData.id; deleteDialog.open() }
                    }
                }
            }
            Label {
                anchors.centerIn: parent
                width: parent.width - 16
                visible: threadList.count === 0
                text: "Ask about a selection, page or figure, or start a new thread with +."
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere; horizontalAlignment: Text.AlignHCenter
                color: Theme.textTertiary; font.pixelSize: Theme.fontSmall
            }
        }
        // The conversation: earlier turns, then the streaming answer.
        ListView {
            id: conversation
            objectName: "aiConversation"
            Layout.minimumWidth: 0
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
                    radius: Theme.radius; color: Theme.window
                    Label {
                        id: userText
                        anchors.fill: parent; anchors.margins: 6
                        text: message.modelData.display || ""; wrapMode: Text.WrapAtWordBoundaryOrAnywhere; textFormat: Text.PlainText
                        color: Theme.text; font.pixelSize: Theme.fontSmall
                    }
                }
                Text {
                    visible: message.modelData.role === "assistant"
                    objectName: "aiMessage-" + message.index
                    Layout.fillWidth: true
                    text: visible ? researchStore.markdownHtml(message.modelData.content, Theme.accent) : ""
                    textFormat: Text.RichText; wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    color: Theme.text; font.pixelSize: Theme.fontBody
                    onLinkActivated: function(link) { root.linkActivated(link) }
                }
                RowLayout {
                    visible: message.modelData.role === "assistant"
                    spacing: 0
                    IconButton { icon.name: "copy"; description: "Copy answer"; glyphSize: Theme.fontBody; onClicked: researchStore.copyText(message.modelData.content) }
                    IconButton {
                        objectName: "aiSaveNote-" + message.index
                        icon.name: "note"; description: "Save as note"; glyphSize: Theme.fontBody
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
                    radius: Theme.radius; color: Theme.window
                    Label { id: pendingText; anchors.fill: parent; anchors.margins: 6; text: root.c ? root.c.pendingQuestion : ""; wrapMode: Text.WrapAtWordBoundaryOrAnywhere; textFormat: Text.PlainText; color: Theme.text; font.pixelSize: Theme.fontSmall }
                }
                Text {
                    objectName: "aiAnswer"
                    visible: root.c && (root.c.streaming || root.c.answer.length > 0)
                    Layout.fillWidth: true
                    text: !root.c ? "" : root.c.answer.length ? researchStore.markdownHtml(root.c.answer, Theme.accent) : "<i>Thinking…</i>"
                    textFormat: Text.RichText; wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    color: Theme.text; font.pixelSize: Theme.fontBody
                    onTextChanged: Qt.callLater(conversation.positionViewAtEnd)
                }
                Label {
                    objectName: "aiError"
                    visible: root.c && root.c.error.length > 0
                    Layout.fillWidth: true; Layout.topMargin: 6
                    text: root.c ? root.c.error : ""; wrapMode: Text.WrapAtWordBoundaryOrAnywhere; textFormat: Text.PlainText
                    color: Theme.danger; font.pixelSize: Theme.fontSmall
                }
                Button {
                    objectName: "aiOpenSettings"
                    visible: root.c && root.c.error.indexOf("Settings") >= 0
                    text: "Open Settings…"; implicitHeight: Theme.rowHeight - 2
                    onClicked: root.settingsRequested()
                }
            }
        }
        // Attachments for the next turn; × removes one. Images show a thumbnail.
        Flow {
            Layout.fillWidth: true; Layout.minimumWidth: 0
            spacing: 4
            visible: root.c && root.c.attachments.length > 0
            Repeater {
                model: root.c ? root.c.attachments : []
                delegate: Rectangle {
                    id: chipBox
                    required property var modelData
                    required property int index
                    objectName: "aiChip-" + modelData.kind + (modelData.kind === "image" ? "-" + modelData.index : "")
                    readonly property bool removable: modelData.kind !== "paper"
                    readonly property real lead: modelData.kind === "image" ? 26 : 6
                    height: 22; width: Math.min(chip.implicitWidth + lead + (removable ? 22 : 6), root.width - 16)
                    radius: Theme.radius; color: Theme.window; border.color: Theme.separator
                    Image {
                        visible: chipBox.modelData.kind === "image"
                        x: 3; anchors.verticalCenter: parent.verticalCenter
                        width: 18; height: 16; fillMode: Image.PreserveAspectCrop
                        source: visible ? chipBox.modelData.url : ""
                        sourceSize.width: 36; sourceSize.height: 32; asynchronous: true
                    }
                    Label { id: chip; x: chipBox.lead; anchors.verticalCenter: parent.verticalCenter; width: parent.width - chipBox.lead - (chipBox.removable ? 20 : 6); text: chipBox.modelData.label; elide: Text.ElideRight; maximumLineCount: 1; textFormat: Text.PlainText; font.pixelSize: Theme.fontCaption; color: Theme.textSecondary }
                    IconButton {
                        visible: chipBox.removable
                        objectName: "aiChipRemove-" + chipBox.index
                        anchors.right: parent.right; anchors.rightMargin: 2; anchors.verticalCenter: parent.verticalCenter
                        width: 18; height: 18; glyphSize: Theme.fontSmall
                        icon.name: "close"; description: "Remove"
                        onClicked: { const kind = chipBox.modelData.kind, at = chipBox.modelData.index; Qt.callLater(function() { root.c.detach(kind, at) }) }
                    }
                }
            }
        }
        TextArea {
            id: question
            objectName: "aiQuestion"
            Layout.minimumWidth: 0
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(140, Math.max(56, implicitHeight))
            placeholderText: root.c && root.c.threadId.length ? "Ask a follow-up…" : "Ask about the paper…"
            wrapMode: TextEdit.Wrap
            font.pixelSize: Theme.fontSmall
            // Return sends, Shift+Return adds a line; pasting an image attaches it.
            Keys.onPressed: function(event) {
                if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !(event.modifiers & Qt.ShiftModifier)) {
                    if (!root.c.streaming && root.c.send(text)) text = ""
                    event.accepted = true
                } else if (event.matches(StandardKey.Paste) && root.c.pasteImage()) {
                    event.accepted = true
                }
            }
        }
        // Composer bar: context, model, reasoning effort and fast mode wrap on the left; Send stays right.
        RowLayout {
            Layout.fillWidth: true; Layout.minimumWidth: 0
            spacing: 4
        Flow {
            id: bar
            Layout.fillWidth: true; Layout.minimumWidth: 0
            Layout.alignment: Qt.AlignBottom
            spacing: 4
            IconButton {
                id: attachButton
                objectName: "aiAttachButton"
                icon.name: "attach"
                description: "Add context · page, selection, paper, a captured region or an image"
                onClicked: attachMenu.popup(attachButton, 0, -attachMenu.implicitHeight)
                Menu {
                    id: attachMenu
                    MenuItem { objectName: "aiAttachPage"; text: "Current Page"; enabled: root.c && root.c.reader !== null; onTriggered: root.c.attach("page") }
                    MenuItem { text: "Selection"; enabled: root.c && root.c.reader && root.c.reader.selectedText.length > 0; onTriggered: root.c.attach("selection") }
                    MenuItem { text: "Whole Paper"; enabled: root.c && root.c.reader !== null; onTriggered: root.c.attach("paper") }
                    MenuSeparator {}
                    MenuItem { objectName: "aiAttachCapture"; text: "Capture a Region"; enabled: root.c && root.c.reader !== null; onTriggered: root.c.captureRegion() }
                    MenuItem { objectName: "aiAttachImage"; text: "Image…"; onTriggered: imageDialog.open() }
                    MenuItem { objectName: "aiPasteImage"; text: "Paste Image"; enabled: attachMenu.opened && root.c.ai.clipboardHasImage(); onTriggered: root.c.pasteImage() }
                }
            }
            Chip {
                id: modelButton
                trailingIcon: "down"
                width: Math.min(implicitWidth, bar.width)
                objectName: "aiModelButton"
                text: root.c ? root.c.modelLabel : ""
                ToolTip.text: root.c ? root.c.providerInfo.name + " · " + (root.c.providerInfo.kind === "local" ? "stays on this computer" : "sent to " + (root.c.providerInfo.sends || "")) : ""
                onClicked: { root.c.loadModels(); modelFilter.text = ""; modelMenu.open() }
            }
            Chip {
                id: effortButton
                trailingIcon: "down"
                objectName: "aiEffortButton"
                visible: root.c && root.c.efforts.length > 0
                text: root.c ? root.c.effortName(root.c.effectiveEffort) : ""
                ToolTip.text: "Reasoning effort: higher thinks longer and costs more"
                onClicked: effortMenu.popup(effortButton, 0, -effortMenu.implicitHeight)
                Menu {
                    id: effortMenu
                    objectName: "aiEffortMenu"
                    Instantiator {
                        model: root.c ? root.c.efforts : []
                        delegate: MenuItem {
                            required property string modelData
                            objectName: "aiEffort-" + modelData
                            text: root.c.effortName(modelData)
                            checkable: true; checked: root.c.effectiveEffort === modelData
                            onTriggered: root.c.setEffort(modelData)
                        }
                        onObjectAdded: function(index, item) { effortMenu.insertItem(index, item) }
                        onObjectRemoved: function(index, item) { effortMenu.removeItem(item) }
                    }
                }
            }
            IconButton {
                objectName: "aiFastButton"
                visible: root.c && root.c.fastAvailable
                icon.name: "fast"
                checkable: true
                checked: root.c && root.c.effectiveFast
                description: "Fast mode · faster answers at a higher price"
                onClicked: root.c.setFast(checked)
            }
        }
            IconButton {
                id: sendButton
                objectName: "aiSend"
                Layout.alignment: Qt.AlignBottom
                primary: true
                readonly property bool stopping: root.c && root.c.streaming
                icon.name: stopping ? "stop" : "send"
                glyphSize: stopping ? Theme.fontSmall : Theme.iconSize
                description: stopping ? "Stop" : "Send · Return"
                enabled: stopping || question.text.trim().length > 0 || (root.c && root.c.attachments.length > 0)
                onClicked: {
                    if (root.c.streaming) root.c.stop()
                    else if (root.c.send(question.text)) question.text = ""
                }
            }
        }
    }
    // Images dropped on the panel are attached to the next question.
    DropArea {
        anchors.fill: parent
        keys: ["text/uri-list"]
        onDropped: function(drop) {
            for (const url of drop.urls) root.c.attachImage(url)
            drop.accept()
        }
    }
    Native.FileDialog {
        id: imageDialog
        title: "Attach images"
        fileMode: Native.FileDialog.OpenFiles
        nameFilters: ["Images (*.png *.jpg *.jpeg *.gif *.webp *.heic)"]
        onAccepted: { for (const url of selectedFiles) root.c.attachImage(url) }
    }
    // Model picker: every set-up provider's models, grouped by company, with a filter.
    Popup {
        id: modelMenu
        objectName: "aiModelMenu"
        parent: modelButton
        y: -height - 4
        width: Math.max(240, Math.min(320, root.width))
        height: Math.min(440, pickerColumn.implicitHeight + 16)
        padding: 8
        onOpened: modelFilter.forceActiveFocus()
        contentItem: ColumnLayout {
            id: pickerColumn
            spacing: 4
            TextField {
                id: modelFilter
                objectName: "aiModelFilter"
                Layout.fillWidth: true
                implicitHeight: Theme.controlHeight
                font.pixelSize: Theme.fontSmall
                placeholderText: "Search models"
                Keys.onEscapePressed: modelMenu.close()
            }
            Flickable {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(360, modelColumn.implicitHeight)
                clip: true
                contentHeight: modelColumn.implicitHeight
                ColumnLayout {
                    id: modelColumn
                    width: parent.width
                    spacing: 1
                    Repeater {
                        model: root.c ? root.c.ai.providers.filter(function(p) { return p.configured || p.id === "ollama" }) : []
                        delegate: ColumnLayout {
                            id: providerSection
                            required property var modelData
                            readonly property string needle: modelFilter.text.trim().toLowerCase()
                            readonly property var list: (root.c.models[modelData.id] || []).filter(function(m) {
                                return !needle.length || (m.name + " " + m.id + " " + providerSection.modelData.name).toLowerCase().indexOf(needle) >= 0
                            })
                            visible: !needle.length || list.length > 0
                            Layout.fillWidth: true
                            spacing: 1
                            Label { text: root.c.companyName(providerSection.modelData.id); font.pixelSize: Theme.fontCaption; font.weight: Font.DemiBold; color: Theme.textTertiary; Layout.topMargin: 4; Layout.leftMargin: 4 }
                            readonly property bool loaded: root.c.models[modelData.id] !== undefined
                            Label {
                                visible: !providerSection.loaded && !providerSection.needle.length
                                text: "Loading…"
                                font.pixelSize: Theme.fontCaption; color: Theme.textTertiary; Layout.leftMargin: 10
                            }
                            // A provider that lists no models (or is signed out) still runs its own default.
                            ItemDelegate {
                                objectName: "aiModel-" + providerSection.modelData.id + "-default"
                                visible: providerSection.loaded && (root.c.models[providerSection.modelData.id] || []).length === 0 && !providerSection.needle.length
                                Layout.fillWidth: true
                                implicitHeight: Theme.rowHeight - 2
                                highlighted: root.c.ai.provider === providerSection.modelData.id && !root.c.model
                                contentItem: Label { text: "Default model"; font.pixelSize: Theme.fontSmall; color: Theme.text }
                                onClicked: {
                                    const provider = providerSection.modelData.id, controller = root.c
                                    modelMenu.close()
                                    Qt.callLater(function() { controller.chooseModel(provider, "") })
                                }
                            }
                            Repeater {
                                model: providerSection.list
                                delegate: ItemDelegate {
                                    id: modelRow
                                    required property var modelData
                                    readonly property bool current: root.c.ai.provider === providerSection.modelData.id && root.c.model === modelData.id
                                    objectName: "aiModel-" + providerSection.modelData.id + "-" + modelData.id
                                    Layout.fillWidth: true
                                    implicitHeight: Theme.rowHeight - 2
                                    highlighted: current
                                    contentItem: RowLayout {
                                        spacing: 6
                                        Label { Layout.fillWidth: true; text: modelRow.modelData.name; elide: Text.ElideRight; font.pixelSize: Theme.fontSmall; color: modelRow.current ? Theme.selectedText : Theme.text }
                                        Label { visible: !!modelRow.modelData.fast; text: "Fast"; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary }
                                        Icon { visible: modelRow.current; name: "check"; size: Theme.fontBody; color: Theme.selectedText }
                                    }
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
                    // Providers that are not set up yet, in one line.
                    ItemDelegate {
                        objectName: "aiModelSetup"
                        readonly property var missing: root.c ? root.c.ai.providers.filter(function(p) { return !p.configured && p.id !== "ollama" }) : []
                        visible: missing.length > 0 && !modelFilter.text.length
                        Layout.fillWidth: true; Layout.topMargin: 4
                        implicitHeight: Theme.rowHeight - 2
                        contentItem: Label {
                            text: "Set up " + parent.missing.map(function(p) { return root.c.companyName(p.id) }).join(", ") + "…"
                            elide: Text.ElideRight; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
                        }
                        onClicked: { modelMenu.close(); root.settingsRequested() }
                    }
                }
            }
        }
    }
    Dialog {
        id: deleteDialog
        objectName: "deleteThreadDialog"
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: 360
        modal: true
        title: "Delete this thread?"
        property string threadId: ""
        Label { width: parent.width; text: "Its questions and answers are removed. Notes saved from it stay."; wrapMode: Text.Wrap; color: Theme.textSecondary }
        footer: DialogButtonBox {
            Button { text: "Cancel"; DialogButtonBox.buttonRole: DialogButtonBox.RejectRole }
            Button { objectName: "confirmDeleteThread"; text: "Delete"; palette.buttonText: Theme.danger; DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole }
        }
        onAccepted: { const id = threadId; Qt.callLater(function() { root.c.deleteThread(id) }) }
    }
    Dialog {
        id: renameDialog
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: 360
        modal: true
        title: "Rename Thread"
        property string threadId: ""
        standardButtons: Dialog.Ok | Dialog.Cancel
        TextField { id: renameField; objectName: "aiRenameField"; width: parent.width; onAccepted: renameDialog.accept() }
        onAccepted: root.c.renameThread(threadId, renameField.text)
    }
}
