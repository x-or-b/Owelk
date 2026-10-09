import Owelk.Ui
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs as Native
import "Platform.js" as Platform

// Dock panel for the AI: saved threads, the open conversation, and the composer with the model menu.
Item {
    id: root
    objectName: "aiPanel"
    property var controller: null
    readonly property var c: controller
    readonly property bool showingThreads: !c || !c.conversationOpen
    property bool showingTrash: false
    // Threads chosen in the list (Cmd/Ctrl-click, Shift-click), and where a Shift range starts.
    property var selectedThreads: []
    property int selectionAnchor: -1
    function toggleThread(id, index) {
        selectedThreads = selectedThreads.indexOf(id) >= 0 ? selectedThreads.filter(function(t) { return t !== id }) : selectedThreads.concat([id])
        selectionAnchor = index
    }
    function selectThreadRange(index) {
        const from = selectionAnchor < 0 ? index : selectionAnchor
        const rows = threadList.model.slice(Math.min(from, index), Math.max(from, index) + 1)
        selectedThreads = rows.map(function(t) { return t.id })
    }
    function trashThreads(ids) {
        if (!ids.length) return
        if (ids.indexOf(c.threadId) >= 0) c.showThreads()
        selectedThreads = []
        researchStore.trashAiThreads(ids)
    }
    signal linkActivated(string link)
    signal settingsRequested()
    function focusQuestion() { question.forceActiveFocus() }
    Connections { target: root.c; function onFocusRequested() { root.focusQuestion() } }
    // Opened to ask about something just attached (or a new thread): the question box is ready.
    Component.onCompleted: if (c && c.conversationOpen && !c.streaming) question.forceActiveFocus()
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
    // An attachment: what goes with a question (× removes it) or went with an earlier one. Images show a
    // thumbnail.
    component AttachmentChip: Rectangle {
        id: chipBox
        required property var modelData
        property bool removable: false
        signal removed()
        readonly property bool thumbnail: modelData.kind === "image" && !!modelData.url
        readonly property real lead: thumbnail ? 26 : 6
        height: 22; width: Math.min(chipLabel.implicitWidth + lead + (removable ? 22 : 6), root.width - 16)
        radius: Theme.radius; color: Theme.window; border.color: Theme.separator
        Image {
            visible: chipBox.thumbnail && status !== Image.Error
            x: 3; anchors.verticalCenter: parent.verticalCenter
            width: 18; height: 16; fillMode: Image.PreserveAspectCrop
            source: chipBox.thumbnail ? chipBox.modelData.url : ""
            sourceSize.width: 36; sourceSize.height: 32; asynchronous: true
        }
        // Plain text: the hover preview below shows the whole attachment instead of the cut label.
        Text {
            id: chipLabel
            x: chipBox.lead; anchors.verticalCenter: parent.verticalCenter
            width: parent.width - chipBox.lead - (chipBox.removable ? 20 : 6)
            text: chipBox.modelData.label || ""
            elide: Text.ElideRight; maximumLineCount: 1; textFormat: Text.PlainText
            font.pixelSize: Theme.fontCaption; color: Theme.textSecondary
        }
        // Hover: the attachment itself, larger (an image) or in full (a selection or quote).
        readonly property string detail: modelData.detail || ""
        HoverHandler { id: chipHover }
        ToolTip {
            objectName: "aiChipPreview"
            visible: chipHover.hovered && (chipBox.thumbnail || chipBox.detail.length > 0)
            delay: 300
            contentItem: Item {
                implicitWidth: chipBox.thumbnail ? large.width : fullText.width
                implicitHeight: chipBox.thumbnail ? large.height : fullText.height
                Image {
                    id: large
                    visible: chipBox.thumbnail
                    source: visible && chipHover.hovered ? chipBox.modelData.url : ""
                    asynchronous: true
                    sourceSize.width: 640
                    width: Math.min(320, implicitWidth); height: implicitWidth > 0 ? width * implicitHeight / implicitWidth : 0
                    fillMode: Image.PreserveAspectFit
                }
                Text {
                    id: fullText
                    visible: !chipBox.thumbnail
                    width: Math.min(340, implicitWidth)
                    text: chipBox.detail
                    wrapMode: Text.Wrap; textFormat: Text.PlainText; maximumLineCount: 16; elide: Text.ElideRight
                    font.pixelSize: Theme.fontSmall; color: Theme.text
                }
            }
        }
        IconButton {
            visible: chipBox.removable
            objectName: "aiChipRemove"
            anchors.right: parent.right; anchors.rightMargin: 2; anchors.verticalCenter: parent.verticalCenter
            width: 18; height: 18; glyphSize: Theme.fontSmall
            icon.name: "close"; description: "Remove"
            onClicked: chipBox.removed()
        }
    }
    // What went with an earlier question, as chips: from the attachments kept with it.
    function sentAttachments(message) {
        const context = message.context || {}, list = []
        const flat = function(text) { const t = (text || "").replace(/\s+/g, " ").trim(); return t.slice(0, 60) + (t.length > 60 ? "…" : "") }
        const paper = root.c && root.c.thread.source && root.c.thread.source.toString().length ? researchStore.displayName(root.c.thread.source) : ""
        ;(context.attachments || []).forEach(function(kind) {
            if (kind === "paper") list.push({kind: kind, label: "Paper" + (paper.length ? " · " + paper : "")})
            else if (kind.indexOf("page ") === 0) list.push({kind: "page", label: "Page " + kind.slice(5) + " text"})
            else if (kind === "selection") list.push({kind: kind, label: "Selection · " + flat(context.selection), detail: context.selection || ""})
            else if (kind === "quote") list.push({kind: kind, label: "Quote · " + flat(context.quote), detail: context.quote || ""})
            else if (kind === "library") list.push({kind: kind, label: "Library passages"})
            else if (kind === "image") {
                const names = context.images || [], files = context.imageFiles || []
                for (let i = 0; i < Math.max(1, names.length, files.length); ++i)
                    list.push({kind: "image", label: names[i] || "Image", url: files[i] || ""})
            }
        })
        return list
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
                text: root.showingThreads ? (root.showingTrash ? "Trash" : "Threads") : (root.c.thread.title || "New thread")
                elide: Text.ElideRight; textFormat: Text.PlainText
                font.pixelSize: Theme.fontBody; font.weight: Font.DemiBold; color: Theme.text
            }
            IconButton {
                objectName: "aiTrashButton"
                visible: root.showingThreads
                checked: root.showingTrash
                icon.name: "trash"; description: root.showingTrash ? "Back to threads" : "Trash"
                onClicked: { root.showingTrash = !root.showingTrash; root.selectedThreads = [] }
            }
            IconButton { objectName: "aiNewThread"; icon.name: "add"; description: "New thread"; onClicked: { root.showingTrash = false; root.c.newThread(); root.focusQuestion() } }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.separator }
        // Saved threads, newest first (or the Trash). Click opens; Cmd/Ctrl-click and Shift-click select
        // several; Delete or the right-click menu moves them to the Trash.
        ListView {
            id: threadList
            objectName: "aiThreadList"
            Layout.minimumWidth: 0
            visible: root.showingThreads
            Layout.fillWidth: true; Layout.fillHeight: true
            clip: true
            spacing: 0
            focus: visible
            model: root.showingTrash ? researchStore.trashedAiThreads() : researchStore.aiThreads()
            Connections {
                target: researchStore
                function onAiThreadsChanged() {
                    threadList.model = root.showingTrash ? researchStore.trashedAiThreads() : researchStore.aiThreads()
                    const ids = threadList.model.map(function(t) { return t.id })
                    root.selectedThreads = root.selectedThreads.filter(function(id) { return ids.indexOf(id) >= 0 })
                }
            }
            Keys.onDeletePressed: if (root.selectedThreads.length && !root.showingTrash) root.trashThreads(root.selectedThreads)
            Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Backspace && root.selectedThreads.length && !root.showingTrash) { root.trashThreads(root.selectedThreads); event.accepted = true }
            }
            delegate: ItemDelegate {
                id: row
                required property var modelData
                required property int index
                readonly property bool chosen: root.selectedThreads.indexOf(modelData.id) >= 0
                objectName: "aiThread-" + index
                width: ListView.view.width
                height: Theme.rowHeightTall
                highlighted: chosen
                separator: index < threadList.count - 1
                onClicked: {
                    threadList.forceActiveFocus()
                    const mods = threadList.clickModifiers
                    if (mods & (Qt.ControlModifier | Qt.MetaModifier)) root.toggleThread(row.modelData.id, row.index)
                    else if (mods & Qt.ShiftModifier) root.selectThreadRange(row.index)
                    else if (root.showingTrash) root.selectedThreads = [row.modelData.id]
                    else { root.selectedThreads = []; const id = row.modelData.id; Qt.callLater(function() { root.c.openThread(id) }) }
                }
                TapHandler {
                    acceptedButtons: Qt.LeftButton
                    acceptedModifiers: Qt.KeyboardModifierMask
                    // Only notes the keys held; the click itself goes to the row.
                    onPressedChanged: if (pressed) threadList.clickModifiers = point.modifiers
                }
                TapHandler {
                    acceptedButtons: Qt.RightButton
                    onTapped: {
                        if (!row.chosen) root.selectedThreads = [row.modelData.id]
                        threadMenu.ids = root.selectedThreads.slice()
                        threadMenu.row = row.modelData
                        threadMenu.popup()
                    }
                }
                contentItem: ColumnLayout {
                    spacing: 1
                    Label { Layout.fillWidth: true; text: row.modelData.title; elide: Text.ElideRight; textFormat: Text.PlainText; color: row.chosen ? Theme.selectedText : Theme.text }
                    Label {
                        Layout.fillWidth: true
                        text: root.showingTrash
                              ? (row.modelData.daysLeft >= 0 ? "Deleted for good in " + row.modelData.daysLeft + (row.modelData.daysLeft === 1 ? " day" : " days") : "In the Trash")
                              : Math.ceil(row.modelData.messages / 2) + (row.modelData.messages > 2 ? " turns" : " turn") + " · " + row.modelData.model
                        elide: Text.ElideRight; textFormat: Text.PlainText; color: Theme.textTertiary; font.pixelSize: Theme.fontCaption
                    }
                }
            }
            property int clickModifiers: 0
            Label {
                anchors.centerIn: parent
                width: parent.width - 16
                visible: threadList.count === 0
                text: root.showingTrash ? "The Trash is empty." : "Ask about a selection, page or figure, or start a new thread with +."
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere; horizontalAlignment: Text.AlignHCenter
                color: Theme.textTertiary; font.pixelSize: Theme.fontSmall
            }
        }
        RowLayout {
            visible: root.showingThreads && root.showingTrash && threadList.count > 0
            Layout.fillWidth: true
            Label {
                Layout.fillWidth: true
                text: researchStore.trashDays() > 0 ? "Deleted for good after " + researchStore.trashDays() + " days." : ""
                elide: Text.ElideRight; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
            }
            Button {
                objectName: "aiEmptyTrash"
                text: "Empty Trash"
                palette.buttonText: Theme.danger
                onClicked: { purgeDialog.ids = []; purgeDialog.open() }
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
                // What went with the question, above it.
                Flow {
                    readonly property var sent: message.modelData.role === "user" ? root.sentAttachments(message.modelData) : []
                    objectName: "aiSent-" + message.index
                    visible: sent.length > 0
                    Layout.fillWidth: true
                    Layout.leftMargin: Math.min(40, conversation.width * 0.12)
                    // Right-aligned like the question; filled from the right, so the list is reversed.
                    layoutDirection: Qt.RightToLeft
                    spacing: 4
                    Repeater {
                        model: parent.sent.slice().reverse()
                        delegate: AttachmentChip {
                            required property int index
                            objectName: "aiSentChip-" + message.index + "-" + index
                        }
                    }
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
                delegate: AttachmentChip {
                    required property int index
                    objectName: "aiChip-" + modelData.kind + (modelData.kind === "image" ? "-" + modelData.index : "")
                    removable: true
                    onRemoved: { const kind = modelData.kind, at = modelData.index; Qt.callLater(function() { root.c.detach(kind, at) }) }
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
                description: "Add context"
                onClicked: attachMenu.popup(attachButton, 0, -attachMenu.implicitHeight)
                Menu {
                    id: attachMenu
                    MenuItem { objectName: "aiAttachPaper"; text: "This Paper"; enabled: root.c && root.c.reader !== null && root.c.reader.source.toString().length > 0; onTriggered: root.c.attachPaper() }
                    MenuItem { objectName: "aiAttachCapture"; text: "Region of the PDF…"; enabled: root.c && root.c.reader !== null; onTriggered: root.c.captureRegion() }
                    MenuItem { objectName: "aiAttachImage"; text: "Image…"; onTriggered: imageDialog.open() }
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
                ToolTip.text: "Model"
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
                ToolTip.text: "Reasoning effort"
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
                description: "Fast mode"
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
                description: stopping ? "Stop" : "Send · " + Platform.keys("Return")
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
    // One menu for the thread list: what it offers depends on the list (threads or Trash) and on how
    // many are selected.
    Menu {
        id: threadMenu
        objectName: "aiThreadMenu"
        property var ids: []
        property var row: ({})
        MenuItem {
            visible: !root.showingTrash && threadMenu.ids.length === 1
            height: visible ? implicitHeight : 0
            text: "Rename…"
            onTriggered: { renameDialog.threadId = threadMenu.row.id; renameField.text = threadMenu.row.title; renameDialog.open() }
        }
        MenuItem {
            objectName: "trashThreadOption"
            visible: !root.showingTrash
            height: visible ? implicitHeight : 0
            text: threadMenu.ids.length > 1 ? "Move " + threadMenu.ids.length + " to Trash" : "Move to Trash"
            onTriggered: root.trashThreads(threadMenu.ids)
        }
        MenuItem {
            objectName: "restoreThreadOption"
            visible: root.showingTrash
            height: visible ? implicitHeight : 0
            text: threadMenu.ids.length > 1 ? "Restore " + threadMenu.ids.length : "Restore"
            onTriggered: { const ids = threadMenu.ids; root.selectedThreads = []; researchStore.trashAiThreads(ids, false) }
        }
        MenuItem {
            objectName: "purgeThreadOption"
            visible: root.showingTrash
            height: visible ? implicitHeight : 0
            text: "Delete Forever…"
            palette.windowText: Theme.danger
            onTriggered: { purgeDialog.ids = threadMenu.ids; purgeDialog.open() }
        }
    }
    Dialog {
        id: purgeDialog
        objectName: "purgeThreadsDialog"
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: 360
        modal: true
        // Empty: the whole Trash.
        property var ids: []
        title: ids.length ? (ids.length === 1 ? "Delete this conversation for good?" : "Delete " + ids.length + " conversations for good?")
                          : "Empty the AI Trash?"
        Label { width: parent.width; text: "Their questions and answers are removed. Notes saved from them stay."; wrapMode: Text.Wrap; color: Theme.textSecondary }
        footer: DialogButtonBox {
            Button { text: "Cancel"; DialogButtonBox.buttonRole: DialogButtonBox.RejectRole }
            Button { objectName: "confirmPurgeThreads"; text: "Delete"; palette.buttonText: Theme.danger; DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole }
        }
        onAccepted: {
            const chosen = ids
            root.selectedThreads = []
            Qt.callLater(function() { if (chosen.length) researchStore.purgeAiThreads(chosen); else researchStore.emptyAiTrash() })
        }
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
