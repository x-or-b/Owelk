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
    // The reader's turn: an accent bubble that hugs its text, with room on the left like a messenger.
    component Bubble: Rectangle {
        property alias text: bubbleText.text
        readonly property real room: conversation.width - Math.min(40, conversation.width * 0.12)
        Layout.alignment: Qt.AlignRight
        Layout.preferredWidth: Math.min(room, bubbleText.implicitWidth + 18)
        implicitHeight: bubbleText.contentHeight + 14
        radius: Theme.radiusLarge; color: Theme.accent
        TextEdit {
            id: bubbleText
            anchors.fill: parent; anchors.leftMargin: 9; anchors.rightMargin: 9; anchors.topMargin: 7; anchors.bottomMargin: 7
            readOnly: true; selectByMouse: true
            textFormat: TextEdit.PlainText; wrapMode: TextEdit.WrapAtWordBoundaryOrAnywhere
            color: Theme.onAccent; font.pixelSize: Theme.fontSmall
            selectionColor: Theme.onAccent; selectedTextColor: Theme.accent
            TapHandler { acceptedButtons: Qt.RightButton; onTapped: function(point) { root.openTextMenu(bubbleText, point.position) } }
        }
    }
    // The model's reasoning summary above an answer. While it thinks: "Thinking · <latest step>" in a
    // lighter colour; once the answer starts: "Thought for 12s ›", which unfolds the whole summary.
    component ThinkingFold: ColumnLayout {
        id: fold
        property string summary: ""
        property int seconds: 0
        property bool live: false
        property bool expanded: false
        readonly property bool shown: root.c && root.c.showThinking && summary.length > 0
        visible: live || shown
        spacing: 4
        Label {
            objectName: "aiThinkingNow"
            visible: fold.live
            Layout.fillWidth: true
            text: fold.shown ? "Thinking · " + root.c.thinkingHeadline(fold.summary) : "Thinking…"
            elide: Text.ElideRight; textFormat: Text.PlainText
            color: Theme.textSecondary; font.pixelSize: Theme.fontSmall
        }
        Label {
            objectName: "aiThoughtToggle"
            visible: !fold.live && fold.shown
            text: "Thought for " + fold.seconds + "s " + (fold.expanded ? "\u2304" : "\u203a")
            textFormat: Text.PlainText
            color: toggleHover.hovered ? Theme.text : Theme.textSecondary; font.pixelSize: Theme.fontSmall
            HoverHandler { id: toggleHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: fold.expanded = !fold.expanded }
        }
        Item {
            visible: !fold.live && fold.shown && fold.expanded
            Layout.fillWidth: true
            implicitHeight: summaryText.implicitHeight
            Rectangle { width: 2; height: parent.height; radius: 1; color: Theme.separator }
            AnswerText {
                id: summaryText
                objectName: "aiThoughtText"
                x: 10; width: parent.width - 10
                text: parent.visible ? researchStore.markdownHtml(fold.summary, Theme.accent, Theme.textSecondary, Theme.fontSmall) : ""
                color: Theme.textSecondary; font.pixelSize: Theme.fontSmall
            }
        }
    }
    // An answer: Markdown as rich text that can be selected and copied; links open in Owelk.
    component AnswerText: TextEdit {
        readOnly: true; selectByMouse: true
        textFormat: TextEdit.RichText; wrapMode: TextEdit.WrapAtWordBoundaryOrAnywhere
        color: Theme.text; font.pixelSize: Theme.fontBody
        selectionColor: Theme.mix(Theme.accent, Theme.field, .65); selectedTextColor: Theme.text
        onLinkActivated: function(link) { root.linkActivated(link) }
        HoverHandler { cursorShape: parent.hoveredLink.length > 0 ? Qt.PointingHandCursor : Qt.IBeamCursor }
        TapHandler { acceptedButtons: Qt.RightButton; onTapped: function(point) { root.openTextMenu(parent, point.position) } }
        Keys.onPressed: function(event) {
            if (event.matches(StandardKey.Copy) && selectedText.length) { researchStore.copyText(root.selectionText(this)); event.accepted = true }
        }
    }
    // The selected text of a message; formulas come back as their LaTeX rather than vanishing.
    function selectionText(target) {
        if (target.textFormat !== TextEdit.RichText) return target.selectedText
        return researchStore.plainTextWithMath(target.getFormattedText(target.selectionStart, target.selectionEnd))
    }
    // Right-click on a question or an answer: Copy, Select All, and Ask About This, which quotes the
    // selection at the top of the question box. One menu serves every message.
    function openTextMenu(target, at) {
        textMenu.target = target
        textMenu.kept = target.persistentSelection
        target.persistentSelection = true // The menu takes focus; the selection stays.
        textMenu.popup(target, at.x, at.y)
    }
    // Ask About This: the passage joins the next question as an attachment chip above the box.
    function quote(text) {
        textMenu.target = null // The question box keeps the focus once the menu closes.
        root.c.quote(text)
        question.forceActiveFocus()
    }
    Menu {
        id: textMenu
        objectName: "aiTextMenu"
        property Item target: null
        property bool kept: false
        readonly property bool selected: target !== null && target.selectedText.length > 0
        onClosed: if (target) { target.persistentSelection = kept; if (selected) target.forceActiveFocus() }
        MenuItem { objectName: "aiTextCopy"; text: "Copy"; enabled: textMenu.selected; onTriggered: researchStore.copyText(root.selectionText(textMenu.target)) }
        MenuItem {
            objectName: "aiTextSelectAll"; text: "Select All"
            enabled: textMenu.target !== null && textMenu.target.length > 0
            onTriggered: textMenu.target.selectAll()
        }
        MenuSeparator {}
        MenuItem {
            objectName: "aiTextAsk"; text: "Ask About This"; enabled: textMenu.selected
            onTriggered: { const target = textMenu.target; target.persistentSelection = textMenu.kept; root.quote(root.selectionText(target)) }
        }
    }
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
        // The conversation: earlier turns, then the streaming answer. Mouse drags select text (the
        // wheel and trackpad scroll); the view follows a streaming answer only while at the bottom.
        ListView {
            id: conversation
            objectName: "aiConversation"
            Layout.minimumWidth: 0
            visible: !root.showingThreads
            Layout.fillWidth: true; Layout.fillHeight: true
            clip: true
            spacing: 10
            acceptedButtons: Qt.NoButton
            ScrollBar.vertical: ScrollBar {}
            model: root.c ? root.c.messages : []
            property bool following: true
            property bool settling: false
            readonly property bool nearEnd: contentHeight <= height || contentY + height >= contentHeight + originY - 24
            function toEnd() { following = true; settling = true; positionViewAtEnd(); settling = false }
            function follow() { if (following) Qt.callLater(toEnd) }
            // The question an answer replies to: the nearest user turn above it.
            function toQuestion(index) {
                const list = root.c ? root.c.messages : []
                let at = index
                while (at > 0 && list[at].role !== "user") --at
                following = false
                positionViewAtIndex(at, ListView.Beginning)
            }
            onContentYChanged: if (!settling) following = nearEnd
            onCountChanged: follow()
            delegate: ColumnLayout {
                id: message
                required property var modelData
                required property int index
                width: ListView.view.width
                spacing: 4
                Label {
                    readonly property string quoted: message.modelData.role === "user" ? ((message.modelData.context || {}).quote || "") : ""
                    objectName: "aiQuoted-" + message.index
                    visible: quoted.length > 0
                    Layout.alignment: Qt.AlignRight
                    Layout.maximumWidth: conversation.width - Math.min(40, conversation.width * 0.12)
                    text: "\u201c" + quoted.replace(/\s+/g, " ").trim() + "\u201d"
                    wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight; textFormat: Text.PlainText
                    color: Theme.textSecondary; font.pixelSize: Theme.fontSmall
                }
                Bubble {
                    visible: message.modelData.role === "user"
                    objectName: "aiQuestion-" + message.index
                    text: message.modelData.display || ""
                }
                ThinkingFold {
                    readonly property var context: message.modelData.context || ({})
                    objectName: "aiThought-" + message.index
                    Layout.fillWidth: true
                    summary: message.modelData.role === "assistant" ? (context.thinking || "") : ""
                    seconds: context.thinkingSeconds || 0
                }
                AnswerText {
                    visible: message.modelData.role === "assistant"
                    objectName: "aiMessage-" + message.index
                    Layout.fillWidth: true
                    text: visible ? researchStore.markdownHtml(message.modelData.content, Theme.accent, Theme.text, Theme.fontBody) : ""
                }
                Label {
                    objectName: "aiCutOff-" + message.index
                    readonly property var context: message.modelData.context || ({})
                    visible: message.modelData.role === "assistant" && !!(context.cutOff || context.stopped)
                    text: context.stopped ? "Stopped." : "Stopped at the length limit."
                    textFormat: Text.PlainText; color: Theme.textTertiary; font.pixelSize: Theme.fontSmall
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
                    IconButton {
                        objectName: "aiToQuestion-" + message.index
                        icon.name: "toQuestion"; description: "Back to the question"; glyphSize: Theme.fontBody
                        onClicked: conversation.toQuestion(message.index)
                    }
                }
            }
            footer: ColumnLayout {
                width: conversation.width
                spacing: 4
                Bubble {
                    visible: root.c && root.c.pendingQuestion.length > 0
                    objectName: "aiPendingQuestion"
                    Layout.topMargin: 10
                    text: root.c ? root.c.pendingQuestion : ""
                }
                ThinkingFold {
                    objectName: "aiThinking"
                    Layout.fillWidth: true
                    live: root.c && root.c.streaming && root.c.answer.length === 0
                    visible: root.c && root.c.streaming && (live || shown)
                    summary: root.c ? root.c.thinkingText : ""
                    seconds: root.c ? root.c.thinkingSeconds : 0
                    onSummaryChanged: conversation.follow()
                }
                AnswerText {
                    objectName: "aiAnswer"
                    visible: root.c && root.c.answer.length > 0
                    Layout.fillWidth: true
                    text: root.c && root.c.answer.length ? researchStore.markdownHtml(root.c.answer, Theme.accent, Theme.text, Theme.fontBody) : ""
                    onTextChanged: conversation.follow()
                }
                Label {
                    objectName: "aiError"
                    visible: root.c && root.c.error.length > 0
                    Layout.fillWidth: true; Layout.topMargin: 6
                    text: root.c ? root.c.error : ""; wrapMode: Text.WrapAtWordBoundaryOrAnywhere; textFormat: Text.PlainText
                    color: Theme.danger; font.pixelSize: Theme.fontSmall
                }
                // A paper translated a page at a time: the next page, in the same thread.
                Button {
                    objectName: "aiTranslateNext"
                    visible: root.c && root.c.canTranslateNext
                    Layout.topMargin: 4
                    text: root.c ? "Translate Page " + (root.c.translatePage + 2) : ""
                    icon.name: "forward"
                    onClicked: root.c.translateNext()
                }
                Button {
                    objectName: "aiOpenSettings"
                    visible: root.c && root.c.error.indexOf("Settings") >= 0
                    text: "Open Settings…"; implicitHeight: Theme.rowHeight - 2
                    onClicked: root.settingsRequested()
                }
            }
            // Scrolled up while newer text sits below: one click back to the latest.
            IconButton {
                id: toLatest
                objectName: "aiToLatest"
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom; anchors.bottomMargin: 8
                z: 2
                visible: !conversation.nearEnd && conversation.count > 0
                icon.name: "toLatest"; description: "Go to the latest"
                background: Rectangle {
                    implicitWidth: Theme.controlHeight; implicitHeight: Theme.controlHeight
                    radius: height / 2
                    color: toLatest.hovered ? Theme.hover : Theme.raised
                    border.color: Theme.border
                }
                onClicked: conversation.toEnd()
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
                    readonly property bool removable: true
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
        // The question box grows with its text up to a limit, then scrolls (the scroll bar shows only
        // while scrolling). From three lines on, the corner button makes it taller or back.
        Item {
            id: composer
            objectName: "aiComposer"
            property bool expanded: false
            readonly property bool tall: question.lineCount >= 3
            readonly property real limit: expanded ? Math.max(140, root.height * 0.5) : 140
            Layout.minimumWidth: 0
            Layout.fillWidth: true
            // Expanded, the box keeps its larger height (like Zed or ChatGPT) until collapsed or sent.
            Layout.preferredHeight: expanded ? limit : Math.min(limit, Math.max(56, question.implicitHeight))
            onTallChanged: if (!tall) expanded = false
            ScrollView {
                id: questionScroll
                objectName: "aiQuestionScroll"
                anchors.fill: parent
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                TextArea {
                    id: question
                    objectName: "aiQuestion"
                    placeholderText: root.c && root.c.spec.scope === "library" ? (root.c.spec.collection ? "Ask this collection…" : "Ask your library…") : root.c && root.c.threadId.length ? "Ask a follow-up…" : "Ask about the paper…"
                    wrapMode: TextEdit.Wrap
                    font.pixelSize: Theme.fontSmall
                    rightPadding: composer.tall ? 28 : 8
                    // Return sends, Shift+Return adds a line; pasting an image attaches it.
                    Keys.onPressed: function(event) {
                        if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !(event.modifiers & Qt.ShiftModifier)) {
                            if (!root.c.streaming && root.c.send(text)) { text = ""; composer.expanded = false }
                            event.accepted = true
                        } else if (event.matches(StandardKey.Paste) && root.c.pasteImage()) {
                            event.accepted = true
                        }
                    }
                }
            }
            IconButton {
                objectName: "aiComposerSize"
                visible: composer.tall
                anchors.top: parent.top; anchors.right: parent.right; anchors.margins: 3
                implicitWidth: 22; implicitHeight: 22; glyphSize: Theme.fontSmall
                icon.name: composer.expanded ? "collapse" : "expand"
                description: composer.expanded ? "Smaller question box" : "Larger question box"
                onClicked: { composer.expanded = !composer.expanded; question.forceActiveFocus() }
            }
        }
        // Composer bar, one row: context, model, reasoning effort, fast mode, Send. When the panel is
        // narrow the model name is shortened first; every control stays visible.
        RowLayout {
            id: bar
            Layout.fillWidth: true; Layout.minimumWidth: 0
            spacing: width < Theme.fontBody * 16 ? 2 : 4
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
                    MenuItem { objectName: "aiAttachLibrary"; text: "Whole Library"; onTriggered: root.c.attach("library") }
                    MenuSeparator {}
                    MenuItem { objectName: "aiAttachCapture"; text: "Capture a Region"; enabled: root.c && root.c.reader !== null; onTriggered: root.c.captureRegion() }
                    MenuItem { objectName: "aiAttachImage"; text: "Image…"; onTriggered: imageDialog.open() }
                    MenuItem { objectName: "aiPasteImage"; text: "Paste Image"; enabled: attachMenu.opened && root.c.ai.clipboardHasImage(); onTriggered: root.c.pasteImage() }
                }
            }
            Chip {
                id: modelButton
                trailingIcon: "down"
                Layout.fillWidth: true
                Layout.minimumWidth: Theme.iconButton
                Layout.maximumWidth: implicitWidth
                objectName: "aiModelButton"
                text: root.c ? root.c.modelLabel : ""
                ToolTip.text: root.c ? root.c.providerInfo.name + " · " + (root.c.providerInfo.kind === "local" ? "stays on this computer" : "sent to " + (root.c.providerInfo.sends || "")) : ""
                onClicked: { root.c.loadModels(); modelFilter.text = ""; modelMenu.open() }
            }
            Chip {
                id: effortButton
                trailingIcon: "down"
                objectName: "aiEffortButton"
                Layout.maximumWidth: Theme.fontBody * 7
                visible: root.c && root.c.efforts.length > 0
                // A narrow panel shows a gauge instead of the effort's name.
                compact: bar.width < Theme.fontBody * 22
                icon.name: "effort"
                text: root.c ? root.c.effortName(root.c.effectiveEffort) : ""
                ToolTip.text: (compact ? "Reasoning effort: " + text + " · " : "Reasoning effort · ") + "higher thinks longer and costs more"
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
            Item { Layout.fillWidth: true; Layout.minimumWidth: 0 }
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
                    if (root.c.streaming) { root.c.stop(); return }
                    Qt.inputMethod.commit() // the last Korean character may still be composing
                    if (root.c.send(question.text)) question.text = ""
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
        // Stays inside the window, however narrow the panel.
        margins: 6
        width: Math.max(220, Math.min(300, root.width))
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
                                    // The name, then a small bolt when the model has a fast mode; a check marks the one in use.
                                    contentItem: RowLayout {
                                        spacing: 4
                                        Label { Layout.maximumWidth: modelRow.availableWidth - 40; text: modelRow.modelData.name; elide: Text.ElideRight; font.pixelSize: Theme.fontSmall; color: modelRow.current ? Theme.selectedText : Theme.text }
                                        Icon { visible: !!modelRow.modelData.fast; name: "fast"; size: Theme.fontCaption; color: Theme.textTertiary }
                                        Item { Layout.fillWidth: true }
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
