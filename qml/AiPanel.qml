import Owelk.Ui
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs as Native
import "Platform.js" as Platform

// Dock panel for the AI: the open chat and the composer with the model menu. Saved chats are in the
// Threads panel (ThreadsPanel.qml), which the button at the top opens.
Item {
    id: root
    objectName: "aiPanel"
    property var controller: null
    readonly property var c: controller
    property bool threadsOpen: false
    signal threadsToggled()
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
            icon.name: "close"; description: qsTr("Remove")
            onClicked: chipBox.removed()
        }
    }
    // What went with an earlier question, as chips: from the attachments kept with it.
    function sentAttachments(message) {
        const context = message.context || {}, list = []
        const flat = function(text) { const t = (text || "").replace(/\s+/g, " ").trim(); return t.slice(0, 60) + (t.length > 60 ? "…" : "") }
        const paper = root.c && root.c.thread.source && root.c.thread.source.toString().length ? researchStore.displayName(root.c.thread.source) : ""
        ;(context.attachments || []).forEach(function(kind) {
            if (kind === "paper") list.push({kind: kind, label: qsTr("Paper") + (paper.length ? " · " + paper : "")})
            else if (kind.indexOf("page ") === 0) list.push({kind: "page", label: qsTr("Page ") + kind.slice(5) + qsTr(" text")})
            else if (kind === "selection") list.push({kind: kind, label: qsTr("Selection · ") + flat(context.selection), detail: context.selection || ""})
            else if (kind === "quote") list.push({kind: kind, label: qsTr("Quote · ") + flat(context.quote), detail: context.quote || ""})
            else if (kind === "papers") (context.papers || []).forEach(function(name) { list.push({kind: "paper", label: qsTr("Paper · ") + name}) })
            else if (kind === "library")
                list.push({kind: kind, label: context.collectionName ? qsTr("Collection · ") + context.collectionName
                                             : !context.wholeLibrary && (context.searched || []).length > 1 ? qsTr("Passages from ") + context.searched.length + qsTr(" papers")
                                             : qsTr("Library passages")})
            else if (kind === "notes") (context.notes || []).forEach(function(title) { list.push({kind: "note", label: qsTr("Note · ") + title}) })
            else if (kind === "image") {
                const names = context.images || [], files = context.imageFiles || []
                for (let i = 0; i < Math.max(1, names.length, files.length); ++i)
                    list.push({kind: "image", label: names[i] || qsTr("Image"), url: files[i] || ""})
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
            text: fold.shown ? qsTr("Thinking · ") + root.c.thinkingHeadline(fold.summary) : qsTr("Thinking…")
            elide: Text.ElideRight; textFormat: Text.PlainText
            color: Theme.textSecondary; font.pixelSize: Theme.fontSmall
        }
        Label {
            objectName: "aiThoughtToggle"
            visible: !fold.live && fold.shown
            text: qsTr("Thought for ") + fold.seconds + qsTr("s ") + (fold.expanded ? "\u2304" : "\u203a")
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
    // A note an answer proposes: its title, the start of it, and Apply (a note given to the AI) or Create
    // (a new one). Nothing is written before that click; afterwards Open, and Undo for a rewritten note.
    component NoteCard: Rectangle {
        id: card
        property var block: ({})
        property int messageIndex: -1
        property int blockIndex: 0
        readonly property var applied: root.c ? root.c.appliedNotes[root.c.noteKey(messageIndex, blockIndex)] : undefined
        property int notesRevision: 0
        Connections { target: researchStore; function onNotesChanged() { card.notesRevision++ } }
        readonly property var target: block.kind === "update" && block.id ? (notesRevision, researchStore.note(block.id)) : ({})
        readonly property bool updates: !!target.id && !target.deleted
        implicitHeight: cardColumn.implicitHeight + 20
        radius: Theme.radius
        color: Theme.raised
        border.width: 1; border.color: Theme.separator
        ColumnLayout {
            id: cardColumn
            x: 10; y: 10; width: parent.width - 20
            spacing: 4
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Icon { name: "note"; size: Theme.fontBody; color: Theme.icon }
                // A rewritten note is named as it is now (the one that will change), with its new title after.
                Label {
                    objectName: "aiNoteTitle"
                    Layout.fillWidth: true
                    text: card.updates ? card.target.title + (card.block.title && card.block.title !== card.target.title ? " \u2192 " + card.block.title : "")
                                       : card.block.title || qsTr("New note")
                    elide: Text.ElideRight; textFormat: Text.PlainText
                    font.weight: Font.DemiBold; color: Theme.text
                }
                Label {
                    text: card.updates ? qsTr("Changes") : qsTr("New")
                    font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
                }
            }
            Label {
                Layout.fillWidth: true
                text: (card.block.body || "").replace(/[#*_`>]/g, "").replace(/\n{2,}/g, "\n").trim()
                maximumLineCount: 4; elide: Text.ElideRight; wrapMode: Text.Wrap; textFormat: Text.PlainText
                font.pixelSize: Theme.fontSmall; color: Theme.textSecondary
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 2
                spacing: 4
                Button {
                    objectName: "aiNoteApply"
                    visible: !card.applied
                    highlighted: true
                    implicitHeight: Theme.controlHeightSmall; font.pixelSize: Theme.fontSmall
                    text: card.updates ? qsTr("Apply to Note") : qsTr("Create Note")
                    onClicked: root.c.applyNote(card.messageIndex, card.blockIndex)
                }
                Label {
                    visible: !!card.applied
                    text: card.applied && card.applied.created ? qsTr("Created") : qsTr("Applied")
                    font.pixelSize: Theme.fontSmall; color: Theme.textSecondary
                }
                Item { Layout.fillWidth: true }
                Button {
                    objectName: "aiNoteUndo"
                    visible: !!card.applied && !!card.applied.before
                    flat: true; implicitHeight: Theme.controlHeightSmall; font.pixelSize: Theme.fontSmall
                    text: qsTr("Undo")
                    onClicked: root.c.undoNote(card.messageIndex, card.blockIndex)
                }
                Button {
                    objectName: "aiNoteOpen"
                    visible: !!card.applied || card.updates
                    flat: true; implicitHeight: Theme.controlHeightSmall; font.pixelSize: Theme.fontSmall
                    text: qsTr("Open")
                    onClicked: root.linkActivated("owelk://note/" + (card.applied ? card.applied.noteId : card.block.id))
                }
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
        MenuItem { objectName: "aiTextCopy"; text: qsTr("Copy"); enabled: textMenu.selected; onTriggered: researchStore.copyText(root.selectionText(textMenu.target)) }
        MenuItem {
            objectName: "aiTextSelectAll"; text: qsTr("Select All")
            enabled: textMenu.target !== null && textMenu.target.length > 0
            onTriggered: textMenu.target.selectAll()
        }
        MenuSeparator {}
        MenuItem {
            objectName: "aiTextAsk"; text: qsTr("Ask About This"); enabled: textMenu.selected
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
                icon.name: "threads"; description: root.threadsOpen ? qsTr("Hide Threads") : qsTr("Show Threads")
                tint: root.threadsOpen ? Theme.accent : Theme.icon
                onClicked: root.threadsToggled()
            }
            Label {
                objectName: "aiThreadTitle"
                Layout.fillWidth: true; Layout.minimumWidth: 0
                text: root.c && root.c.threadId.length ? (root.c.thread.title || qsTr("Chat")) : qsTr("New Chat")
                elide: Text.ElideRight; textFormat: Text.PlainText
                font.pixelSize: Theme.fontBody; font.weight: Font.DemiBold; color: Theme.text
            }
            IconButton { objectName: "aiNewThread"; icon.name: "add"; description: qsTr("New chat"); onClicked: { root.c.newThread(); root.focusQuestion() } }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.separator }
        // A conversation opened from a note while it is in the Trash: readable, continued once restored.
        RowLayout {
            objectName: "aiTrashedBanner"
            visible: !!root.c && !!root.c.thread.trashed
            Layout.fillWidth: true
            Layout.leftMargin: 10; Layout.rightMargin: 6; Layout.topMargin: 6
            Label {
                Layout.fillWidth: true
                text: qsTr("This conversation is in the Trash.")
                wrapMode: Text.Wrap; font.pixelSize: Theme.fontSmall; color: Theme.textSecondary
            }
            Button {
                objectName: "aiRestoreThread"
                text: qsTr("Restore")
                implicitHeight: Theme.controlHeightSmall; font.pixelSize: Theme.fontSmall
                onClicked: root.c.restoreThread()
            }
        }
        // The conversation: earlier turns, then the streaming answer. Mouse drags select text (the
        // wheel and trackpad scroll); the view follows a streaming answer only while at the bottom.
        ListView {
            id: conversation
            objectName: "aiConversation"
            Layout.minimumWidth: 0
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
                // An answer's text and the notes it proposes.
                readonly property var parts: modelData.role === "assistant" && root.c ? root.c.noteBlocks(modelData.content) : ({text: "", notes: [], plain: ""})
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
                    visible: message.modelData.role === "assistant" && message.parts.text.length > 0
                    objectName: "aiMessage-" + message.index
                    Layout.fillWidth: true
                    text: visible ? researchStore.markdownHtml(message.parts.text, Theme.accent, Theme.text, Theme.fontBody) : ""
                }
                Repeater {
                    model: message.modelData.role === "assistant" ? message.parts.notes : []
                    delegate: NoteCard {
                        required property var modelData
                        required property int index
                        Layout.fillWidth: true
                        objectName: "aiNoteCard-" + message.index + "-" + index
                        block: modelData
                        messageIndex: message.index
                        blockIndex: index
                    }
                }
                Label {
                    objectName: "aiCutOff-" + message.index
                    readonly property var context: message.modelData.context || ({})
                    visible: message.modelData.role === "assistant" && !!(context.cutOff || context.stopped || context.interrupted)
                    text: context.closed ? (message.modelData.content.length ? qsTr("Owelk was closed before the answer finished.") : qsTr("Owelk was closed before the answer came."))
                        : context.stopped ? qsTr("Stopped.") : context.interrupted ? qsTr("The connection ended before the answer did.") : qsTr("Stopped at the length limit.")
                    textFormat: Text.PlainText; color: Theme.textTertiary; font.pixelSize: Theme.fontSmall
                }
                // Nothing to copy or keep when Owelk closed before the answer came.
                RowLayout {
                    visible: message.modelData.role === "assistant" && (message.modelData.content || "").length > 0
                    spacing: 0
                    IconButton { icon.name: "copy"; description: qsTr("Copy answer"); glyphSize: Theme.fontBody; onClicked: researchStore.copyText(message.parts.plain) }
                    // A new note, or one of the notes about this paper (a menu when there are some).
                    IconButton {
                        id: saveNoteButton
                        objectName: "aiSaveNote-" + message.index
                        icon.name: "note"; description: qsTr("Save as note"); glyphSize: Theme.fontBody
                        onClicked: {
                            const notes = root.c.paperNotes()
                            if (!notes.length) { root.c.saveAsNote(message.index); return }
                            saveNoteMenu.notes = notes
                            saveNoteMenu.popup(saveNoteButton, 0, saveNoteButton.height)
                        }
                        Menu {
                            id: saveNoteMenu
                            objectName: "aiSaveNoteMenu"
                            property var notes: []
                            MenuItem { objectName: "aiSaveNewNote"; text: qsTr("New Note"); onTriggered: root.c.saveAsNote(message.index) }
                            MenuSeparator {}
                            Instantiator {
                                model: saveNoteMenu.notes
                                delegate: MenuItem {
                                    required property var modelData
                                    text: qsTr("Add to \u201c") + modelData.title + "\u201d"
                                    onTriggered: root.c.saveAsNote(message.index, modelData.id)
                                }
                                onObjectAdded: function(index, item) { saveNoteMenu.insertItem(index + 2, item) }
                                onObjectRemoved: function(index, item) { saveNoteMenu.removeItem(item) }
                            }
                        }
                    }
                    IconButton {
                        objectName: "aiToQuestion-" + message.index
                        icon.name: "toQuestion"; description: qsTr("Back to the question"); glyphSize: Theme.fontBody
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
                    id: liveAnswer
                    objectName: "aiAnswer"
                    // The answer as drawn: while it streams, at most every 50 ms (each drawing converts the whole
                    // answer so far to rich text and lays it out again); emptied at once for a new question.
                    property string drawn: root.c ? root.c.answer : ""
                    Timer { id: liveRedraw; interval: 50; onTriggered: liveAnswer.drawn = root.c ? root.c.answer : "" }
                    Connections {
                        target: root.c
                        function onAnswerChanged() {
                            if (!root.c.answer.length) { liveRedraw.stop(); liveAnswer.drawn = "" }
                            else if (!liveRedraw.running) liveRedraw.start()
                        }
                    }
                    readonly property var parts: root.c && drawn.length ? root.c.noteBlocks(drawn) : ({text: "", notes: [], preparing: false})
                    visible: parts.text.length > 0
                    Layout.fillWidth: true
                    text: visible ? researchStore.markdownHtml(parts.text, Theme.accent, Theme.text, Theme.fontBody) : ""
                    onTextChanged: conversation.follow()
                }
                Label {
                    objectName: "aiPreparingNote"
                    visible: liveAnswer.parts.notes.length > 0 || liveAnswer.parts.preparing
                    text: qsTr("Writing a note…")
                    textFormat: Text.PlainText; color: Theme.textTertiary; font.pixelSize: Theme.fontSmall
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
                    text: root.c ? qsTr("Translate Page ") + (root.c.translatePage + 2) : ""
                    icon.name: "forward"
                    onClicked: root.c.translateNext()
                }
                Button {
                    objectName: "aiOpenSettings"
                    visible: root.c && root.c.error.indexOf("Settings") >= 0
                    text: qsTr("Open Settings…"); implicitHeight: Theme.rowHeight - 2
                    onClicked: root.settingsRequested()
                }
            }
            Label {
                objectName: "aiEmptyHint"
                anchors.centerIn: parent
                width: parent.width - 16
                visible: conversation.count === 0 && !!root.c && !root.c.streaming && !root.c.pendingQuestion.length && !root.c.error.length
                text: qsTr("Ask about the paper, or a selection, page or figure. Earlier chats are in Threads.")
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere; horizontalAlignment: Text.AlignHCenter
                color: Theme.textTertiary; font.pixelSize: Theme.fontSmall
            }
            // Scrolled up while newer text sits below: one click back to the latest.
            IconButton {
                id: toLatest
                objectName: "aiToLatest"
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom; anchors.bottomMargin: 8
                z: 2
                visible: !conversation.nearEnd && conversation.count > 0
                icon.name: "toLatest"; description: qsTr("Go to the latest")
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
            id: attachmentRow
            objectName: "aiAttachments"
            Layout.fillWidth: true; Layout.minimumWidth: 0
            spacing: 4
            visible: root.c && root.c.attachments.length > 0
            Repeater {
                model: root.c ? root.c.attachments : []
                delegate: AttachmentChip {
                    required property int index
                    objectName: "aiChip-" + modelData.kind + (modelData.kind === "image" || modelData.kind === "extra" ? "-" + modelData.index : "")
                    removable: !modelData.fixed
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
                    // A click elsewhere in the window takes the cursor out (Main.qml); the box, its
                    // attachments and the bar under it (send, model, attach) keep it.
                    property bool releaseFocusOnOutsidePress: true
                    property var keepFocusWithin: [composer, attachmentRow, bar]
                    placeholderText: root.c && root.c.spec.scope === "library" ? (root.c.spec.collection ? qsTr("Ask this collection…") : qsTr("Ask your library…")) : root.c && root.c.threadId.length ? qsTr("Ask a follow-up…") : qsTr("Ask about the paper…")
                    wrapMode: TextEdit.Wrap
                    font.pixelSize: Theme.fontSmall
                    rightPadding: composer.tall ? 28 : 8
                    // Typing with nothing open starts a chat about the paper in the reader (its chip shows).
                    onActiveFocusChanged: if (activeFocus && root.c) root.c.ensureConversation()
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
                description: composer.expanded ? qsTr("Smaller question box") : qsTr("Larger question box")
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
                description: qsTr("Add context")
                onClicked: attachMenu.popup(attachButton, 0, -attachMenu.implicitHeight)
                Menu {
                    id: attachMenu
                    MenuItem { objectName: "aiAttachPaper"; text: qsTr("This Paper"); enabled: root.c && root.c.reader !== null && root.c.reader.source.toString().length > 0; onTriggered: root.c.attachPaper() }
                    MenuItem { objectName: "aiAttachPapers"; text: qsTr("Papers…"); onTriggered: picker.begin("papers") }
                    MenuItem { objectName: "aiAttachCollection"; text: qsTr("Collection…"); onTriggered: picker.begin("collection") }
                    MenuItem { objectName: "aiAttachLibrary"; text: qsTr("Whole Library"); onTriggered: root.c.attachCollection("", "") }
                    MenuItem { objectName: "aiAttachNote"; text: qsTr("Note…"); onTriggered: picker.begin("notes") }
                    MenuSeparator {}
                    MenuItem { objectName: "aiAttachRegion"; text: qsTr("Region of the PDF…"); enabled: root.c && root.c.reader !== null; onTriggered: root.c.captureRegion() }
                    MenuItem { objectName: "aiAttachImage"; text: qsTr("Image…"); onTriggered: imageDialog.open() }
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
                ToolTip.text: qsTr("Model")
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
                ToolTip.text: qsTr("Reasoning effort")
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
                description: qsTr("Fast mode")
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
                description: stopping ? qsTr("Stop") : qsTr("Send · ") + Platform.keys("Return")
                enabled: stopping || question.text.trim().length > 0 || (root.c && root.c.attachments.length > 0)
                onClicked: {
                    if (root.c.streaming) { root.c.stop(); return }
                    Qt.inputMethod.commit() // the last Korean character may still be composing
                    if (root.c.send(question.text)) question.text = ""
                }
            }
        }
    }
    // Images, PDFs and papers dragged from the Library are attached to the next question: an outline while
    // something is over the panel, and the attachments row lights up once it is dropped.
    DropArea {
        id: drops
        objectName: "aiDrop"
        anchors.fill: parent
        keys: ["text/uri-list", "owelk/paper"]
        onDropped: function(drop) {
            const before = root.c.attachments.length
            if (drop.source && drop.source.paperUrls) root.c.attachPapers(drop.source.paperUrls)
            else {
                const pdfs = drop.urls.filter(function(url) { return /\.pdf$/i.test(url.toString()) })
                if (pdfs.length) root.c.attachPapers(pdfs)
                for (const url of drop.urls) root.c.attachImage(url)
            }
            drop.accept()
            root.attached(root.c.attachments.length > before)
        }
        Rectangle {
            objectName: "aiDropHint"
            anchors.fill: parent; anchors.margins: 4
            visible: drops.containsDrag
            z: 10
            radius: Theme.radiusLarge
            color: "transparent"
            border.width: 2; border.color: Theme.accent
            Label { anchors.centerIn: parent; text: qsTr("Attach"); font.pixelSize: Theme.fontSmall; color: Theme.textSecondary }
        }
    }
    // The attachments row lights up after a drop (once laid out); nothing new (already attached, not a
    // picture or PDF) says so.
    function attached(added) {
        if (added) { flashLater.restart(); return }
        researchStore.notify(qsTr("Nothing new to attach: pictures and PDFs only, each once."))
    }
    Timer {
        id: flashLater
        interval: 30
        onTriggered: {
            const at = attachmentRow.mapToItem(root, 0, 0)
            attachedFlash.x = at.x - 3; attachedFlash.y = at.y - 3
            attachedFlash.width = attachmentRow.width + 6; attachedFlash.height = attachmentRow.height + 6
            flashFade.restart()
        }
    }
    Rectangle {
        id: attachedFlash
        objectName: "aiAttachedFlash"
        z: 5
        radius: Theme.radius
        color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, .14)
        border.color: Theme.accent; border.width: 2
        opacity: 0
        NumberAnimation on opacity { id: flashFade; running: false; from: 1; to: 0; duration: 1000; easing.type: Easing.InQuad }
    }
    // Papers (open tabs first, then the Library; several can be chosen) or a collection, to ask about.
    Popup {
        id: picker
        objectName: "aiPicker"
        property string mode: "papers"
        property var chosen: []
        function begin(what) { mode = what; chosen = []; pickerFilter.text = ""; open() }
        function toggle(url) { chosen = chosen.indexOf(url) >= 0 ? chosen.filter(function(u) { return u !== url }) : chosen.concat([url]) }
        function attach() {
            if (!chosen.length) return
            const urls = chosen.slice()
            close()
            root.c.attachPapers(urls)
        }
        function choose(row) {
            if (mode === "papers") toggle(row.url)
            else if (mode === "notes") { close(); root.c.attachNote(row.id) }
            else { close(); root.c.attachCollection(row.id, row.name) }
        }
        parent: attachButton
        y: -height - 4
        margins: 6
        width: Math.max(240, Math.min(320, root.width))
        padding: 8
        onOpened: pickerFilter.forceActiveFocus()
        readonly property string needle: pickerFilter.text.trim()
        readonly property var rows: {
            if (!visible || !root.c) return []
            const words = needle.toLowerCase()
            const match = function(name) { return !words.length || name.toLowerCase().indexOf(words) >= 0 }
            if (mode === "notes")
                return researchStore.notes(false).filter(function(n) { return match(n.title || "") && (root.c.spec.noteIds || []).indexOf(n.id) < 0 })
                    .map(function(n) { return {type: "note", id: n.id, name: n.title || qsTr("Untitled note")} })
            if (mode === "collection")
                return researchStore.collections().filter(function(c) { return match(c.name) })
                    .map(function(c) { return {type: "collection", id: c.id, name: c.name, count: c.count} })
            const current = root.c.spec, list = [], seen = {}
            const taken = function(url) {
                return (!!current.source && researchStore.sameSource(current.source, url)) || (current.papers || []).some(function(p) { return researchStore.sameSource(p, url) })
            }
            const tabs = root.c.openTabPapers().filter(function(url) { return !taken(url) })
                .map(function(url) { return {type: "paper", url: url, name: researchStore.displayName(url)} }).filter(function(r) { return match(r.name) })
            if (tabs.length) list.push({type: "section", name: qsTr("Open Tabs")})
            tabs.forEach(function(r) { seen[r.url] = true; list.push(r) })
            const library = researchStore.libraryDocuments({text: needle, limit: 40})
                .map(function(d) { return {type: "paper", url: d.url.toString(), name: d.name} })
                .filter(function(r) { return !seen[r.url] && !taken(r.url) })
            if (library.length) list.push({type: "section", name: qsTr("Library")})
            library.forEach(function(r) { list.push(r) })
            return list
        }
        contentItem: ColumnLayout {
            spacing: 4
            TextField {
                id: pickerFilter
                objectName: "aiPickerFilter"
                Layout.fillWidth: true
                implicitHeight: Theme.controlHeight
                font.pixelSize: Theme.fontSmall
                placeholderText: picker.mode === "papers" ? qsTr("Search papers") : picker.mode === "notes" ? qsTr("Search notes") : qsTr("Search collections")
                Keys.onEscapePressed: picker.close()
                Keys.onReturnPressed: {
                    if (picker.mode === "papers") picker.attach()
                    else { const first = picker.rows.find(function(r) { return r.type === "collection" || r.type === "note" }); if (first) picker.choose(first) }
                }
            }
            ListView {
                id: pickerList
                objectName: "aiPickerList"
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(300, Math.max(contentHeight, Theme.rowHeight))
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: picker.rows
                delegate: ItemDelegate {
                    id: pick
                    required property var modelData
                    required property int index
                    readonly property bool section: modelData.type === "section"
                    readonly property bool picked: modelData.type === "paper" && picker.chosen.indexOf(modelData.url) >= 0
                    objectName: "aiPick-" + index
                    width: ListView.view.width
                    implicitHeight: Theme.rowHeight - 2
                    enabled: !section
                    highlighted: picked
                    leftPadding: section ? 4 : 26
                    contentItem: Label {
                        text: pick.modelData.name
                        elide: Text.ElideRight; textFormat: Text.PlainText
                        font.pixelSize: pick.section ? Theme.fontCaption : Theme.fontSmall
                        font.weight: pick.section ? Font.DemiBold : Font.Normal
                        color: pick.section ? Theme.textTertiary : pick.picked ? Theme.selectedText : Theme.text
                    }
                    Icon {
                        visible: !pick.section
                        x: 6; anchors.verticalCenter: parent.verticalCenter
                        name: pick.modelData.type === "collection" ? "folder" : pick.modelData.type === "note" ? "note" : pick.picked ? "check" : "document"
                        size: Theme.fontBody; color: pick.picked ? Theme.selectedText : Theme.textTertiary
                    }
                    onClicked: picker.choose(modelData)
                }
                Label {
                    anchors.centerIn: parent
                    visible: pickerList.count === 0
                    text: picker.mode === "papers" ? qsTr("No paper found.") : picker.mode === "notes" ? qsTr("No note found.") : qsTr("No collection found.")
                    color: Theme.textTertiary; font.pixelSize: Theme.fontSmall
                }
            }
            RowLayout {
                visible: picker.mode === "papers"
                Layout.fillWidth: true
                Label {
                    Layout.fillWidth: true
                    text: picker.chosen.length ? picker.chosen.length + qsTr(" chosen") : qsTr("Up to 3 are read whole; more are searched.")
                    elide: Text.ElideRight; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
                }
                Button {
                    objectName: "aiPickerAttach"
                    text: qsTr("Attach")
                    highlighted: true
                    enabled: picker.chosen.length > 0
                    implicitHeight: Theme.controlHeightSmall; font.pixelSize: Theme.fontSmall
                    onClicked: picker.attach()
                }
            }
        }
    }
    Native.FileDialog {
        id: imageDialog
        title: qsTr("Attach images")
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
                placeholderText: qsTr("Search models")
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
                                text: qsTr("Loading…")
                                font.pixelSize: Theme.fontCaption; color: Theme.textTertiary; Layout.leftMargin: 10
                            }
                            // A provider that lists no models (or is signed out) still runs its own default.
                            ItemDelegate {
                                objectName: "aiModel-" + providerSection.modelData.id + "-default"
                                visible: providerSection.loaded && (root.c.models[providerSection.modelData.id] || []).length === 0 && !providerSection.needle.length
                                Layout.fillWidth: true
                                implicitHeight: Theme.rowHeight - 2
                                highlighted: root.c.ai.provider === providerSection.modelData.id && !root.c.model
                                contentItem: Label { text: qsTr("Default model"); font.pixelSize: Theme.fontSmall; color: Theme.text }
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
                            text: qsTr("Set up ") + parent.missing.map(function(p) { return root.c.companyName(p.id) }).join(", ") + "…"
                            elide: Text.ElideRight; font.pixelSize: Theme.fontCaption; color: Theme.textTertiary
                        }
                        onClicked: { modelMenu.close(); root.settingsRequested() }
                    }
                }
            }
        }
    }
}
