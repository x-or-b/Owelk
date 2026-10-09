import Owelk.Ui
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Explain: a short explanation of a figure, table, algorithm, equation, selection or the paper's symbols,
// in a card beside it. The answer is kept per paper, place and level (AiService::explain), so opening it
// again is instant and free; Continue in AI turns it into a thread in the AI panel.
Rectangle {
    id: card
    objectName: "explainCard"
    visible: false
    z: 70
    readonly property var ai: researchStore.ai
    // {source, kind, label, page, region, caption, selection}
    property var spec: ({})
    property string level: "easy"
    property int request: -1
    property bool streaming: false
    property string answer: ""
    property string error: ""
    property string key: ""
    property string model: ""
    property bool cached: false
    property bool stopped: false
    // Where the card was opened from, in the parent's coordinates, to sit beside it.
    property rect anchorRect: Qt.rect(0, 0, 0, 0)
    readonly property var providerInfo: ai.providers.find(function(p) { return p.id === ai.provider }) || ({})
    readonly property bool needsConsent: (ai.providers, !ai.consented(ai.provider))
    readonly property string title: spec.kind === "notation" ? "Symbols in This Paper"
                                   : spec.kind === "selection" ? "Selection" : (spec.label || "Explain")
    signal continueRequested(string threadId, string image, string label)
    signal linkActivated(string link)
    signal goRequested(int page, real top)

    function open(next, anchor) {
        stop()
        spec = next
        anchorRect = anchor || Qt.rect(0, 0, 0, 0)
        level = researchStore.setting("ai.explainLevel", "easy") === "brief" ? "brief" : "easy"
        visible = true
        place()
        start(false)
    }
    function close() { stop(); visible = false }
    function stop() { if (streaming) ai.cancel(request); streaming = false }
    function start(refresh) {
        stop()
        answer = ""; error = ""; key = ""; model = ""; cached = false; stopped = false
        if (!providerInfo.configured && ai.provider !== "ollama") {
            error = ai.provider === "codex" ? "Sign in with ChatGPT in Settings → AI." : "Add an API key in Settings → AI."
            return
        }
        if (needsConsent) return
        streaming = true
        request = ai.explain(Object.assign({}, spec, {level: level, refresh: !!refresh}))
    }
    function setLevel(next) {
        if (level === next) return
        level = next
        researchStore.setSetting("ai.explainLevel", next)
        start(false)
    }
    // Beside what it explains: right of it, else left; else below or above it. Always inside the view.
    function place() {
        if (!parent) return
        const a = anchorRect, gap = 12, w = parent.width, h = parent.height
        let x = a.x + a.width + gap, y = a.y
        if (x + width > w - 8) x = a.x - width - gap
        if (x < 8) {
            x = a.x
            y = a.y + a.height + gap + height < h ? a.y + a.height + gap : a.y - height - gap
        }
        card.x = Math.max(8, Math.min(w - width - 8, x))
        card.y = Math.max(8, Math.min(h - height - 8, y))
    }
    function saveAsNote() {
        const lines = [answer, "", "---"]
        const paper = researchStore.documentLinkId(spec.source)
        if (paper.length) lines.push("- " + researchStore.markdownLink("document", paper) + " · p. " + (Number(spec.page) + 1))
        const note = researchStore.createNote(title + " · " + researchStore.displayName(spec.source), lines.join("\n") + "\n")
        if (note.length) researchStore.notify("Saved as a note.")
    }
    function continueInAi() {
        const thread = ai.continueExplanation(key)
        if (!thread.length) { error = "This explanation is no longer kept. Explain it again."; return }
        continueRequested(thread, spec.kind === "selection" || spec.kind === "notation" ? "" : (spec.imageUrl || ""), title)
        close()
    }

    width: Math.min(440, (parent ? parent.width : 440) - 16)
    height: Math.min(column.implicitHeight, (parent ? parent.height : 600) * .72)
    radius: Theme.radiusLarge
    color: Theme.raised
    border.color: Theme.border
    clip: true
    // The card keeps the pointer: clicks, wheels, drags and pinches never reach the page underneath.
    HoverHandler { onHoveredChanged: if (card.parent && card.parent.overCard !== undefined) card.parent.overCard = hovered && card.visible }
    onVisibleChanged: if (!visible && parent && parent.overCard !== undefined) parent.overCard = false
    MouseArea { anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.AllButtons; onWheel: function(wheel) { wheel.accepted = true } }
    Connections {
        target: card.ai
        function onStarted(id, thread, provider, model) { if (id === card.request) card.model = model }
        function onDelta(id, text) { if (id === card.request) card.answer += text }
        function onFinished(id, text, details) {
            if (id !== card.request) return
            card.streaming = false
            card.answer = text
            card.key = details.key || ""
            card.model = details.model || card.model
            card.cached = !!details.cached
            card.stopped = !!details.stopped
            if (details.image) card.spec = Object.assign({}, card.spec, {imageUrl: details.image})
        }
        function onFailed(id, message) {
            if (id !== card.request) return
            card.streaming = false
            if (message !== "Stopped.") card.error = message
        }
    }
    ColumnLayout {
        id: column
        anchors.left: parent.left; anchors.right: parent.right
        spacing: 0
        // Header: what is explained (click: go there), the level, close. Dragging it moves the card.
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.barHeight
            Layout.leftMargin: 10; Layout.rightMargin: 4
            spacing: 4
            DragHandler { target: card; xAxis.minimum: 0; yAxis.minimum: 0; xAxis.maximum: card.parent ? card.parent.width - card.width : 0; yAxis.maximum: card.parent ? card.parent.height - card.height : 0 }
            Icon { name: "ai" }
            Label {
                objectName: "explainTitle"
                Layout.fillWidth: true
                text: card.title + (card.spec.kind === "notation" ? "" : " · p. " + (Number(card.spec.page) + 1))
                elide: Text.ElideRight
                font.weight: Font.Medium
                HoverHandler { cursorShape: Qt.PointingHandCursor }
                TapHandler {
                    onTapped: if (card.spec.region) card.goRequested(card.spec.page, Math.max(0, card.spec.region.y - .03))
                }
            }
            Repeater {
                model: card.spec.kind === "notation" ? [] : [{id: "easy", name: "Easy"}, {id: "brief", name: "Brief"}]
                delegate: ToolButton {
                    required property var modelData
                    objectName: "explainLevel-" + modelData.id
                    text: modelData.name
                    checkable: true
                    checked: card.level === modelData.id
                    font.pixelSize: Theme.fontSmall
                    ToolTip.visible: hovered; ToolTip.delay: 500
                    ToolTip.text: modelData.id === "easy" ? "Plain words, every symbol defined, with examples" : "Short: the key point and what you need to follow it"
                    onClicked: card.setLevel(modelData.id)
                }
            }
            IconButton { objectName: "explainClose"; icon.name: "close"; description: "Close · Esc"; onClicked: card.close() }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.separator }
        Flickable {
            id: body
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(contentHeight, (card.parent ? card.parent.height : 600) * .72 - Theme.barHeight * 2 - 2)
            contentHeight: content.implicitHeight + 20
            boundsBehavior: Flickable.StopAtBounds
            clip: true
            ScrollBar.vertical: ScrollBar {}
            ColumnLayout {
                id: content
                x: 12; y: 10
                width: body.width - 24
                spacing: 8
                // First use of a provider: what is sent, before anything is.
                ColumnLayout {
                    visible: card.needsConsent && !card.error.length
                    Layout.fillWidth: true
                    spacing: 8
                    Label {
                        Layout.fillWidth: true; wrapMode: Text.Wrap
                        text: "Owelk sends " + (card.spec.kind === "selection" || card.spec.kind === "notation" ? "" : "an image of this part and ")
                              + "the paper's text to " + (card.providerInfo.sends || card.providerInfo.name || "the AI provider")
                              + ". The PDF file itself is never uploaded. Usage is billed by the provider under your account."
                        color: Theme.textSecondary; font.pixelSize: Theme.fontSmall
                    }
                    Button {
                        objectName: "explainConsent"
                        primary: true
                        text: "Send and Explain"
                        onClicked: { card.ai.giveConsent(card.ai.provider); card.start(false) }
                    }
                }
                Label {
                    objectName: "explainWaiting"
                    visible: card.streaming && (!card.answer.length || card.spec.kind === "notation")
                    text: card.spec.kind === "notation" ? "Collecting the symbols of this paper…" : "Thinking…"
                    color: Theme.textSecondary; font.pixelSize: Theme.fontSmall
                }
                TextEdit {
                    id: answerText
                    objectName: "explainAnswer"
                    visible: card.answer.length > 0 && !(card.streaming && card.spec.kind === "notation")
                    Layout.fillWidth: true
                    readOnly: true; selectByMouse: true
                    textFormat: TextEdit.RichText; wrapMode: TextEdit.WrapAtWordBoundaryOrAnywhere
                    text: visible ? researchStore.markdownHtml(card.answer, Theme.accent, Theme.text, Theme.fontBody) : ""
                    color: Theme.text; font.pixelSize: Theme.fontBody
                    selectionColor: Theme.mix(Theme.accent, Theme.field, .65); selectedTextColor: Theme.text
                    onLinkActivated: function(link) { card.linkActivated(link) }
                    HoverHandler { cursorShape: answerText.hoveredLink.length > 0 ? Qt.PointingHandCursor : Qt.IBeamCursor }
                    Keys.onPressed: function(event) {
                        if (event.matches(StandardKey.Copy) && selectedText.length) {
                            researchStore.copyText(researchStore.plainTextWithMath(getFormattedText(selectionStart, selectionEnd)))
                            event.accepted = true
                        }
                    }
                }
                Label {
                    objectName: "explainError"
                    visible: card.error.length > 0
                    Layout.fillWidth: true; wrapMode: Text.Wrap
                    text: card.error
                    color: Theme.danger; font.pixelSize: Theme.fontSmall
                }
                Label {
                    visible: card.stopped
                    text: "Stopped."
                    color: Theme.textTertiary; font.pixelSize: Theme.fontSmall
                }
            }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.separator }
        // Footer: go on in the AI panel, keep or copy it, ask again.
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.barHeight
            Layout.leftMargin: 8; Layout.rightMargin: 6
            spacing: 2
            Button {
                objectName: "explainContinue"
                primary: true
                text: "Continue in AI"
                enabled: card.key.length > 0 && !card.streaming && !card.stopped
                ToolTip.visible: hovered; ToolTip.delay: 500
                ToolTip.text: "Ask follow-up questions in the AI panel"
                onClicked: card.continueInAi()
            }
            Button {
                objectName: "explainSymbols"
                visible: card.spec.kind === "equation"
                text: "All Symbols"
                ToolTip.visible: hovered; ToolTip.delay: 500
                ToolTip.text: "Every symbol in this paper, with where it is defined; then point at a symbol to see what it means"
                onClicked: card.open({source: card.spec.source, kind: "notation", page: card.spec.page}, Qt.rect(card.x, card.y, 0, 0))
            }
            Item { Layout.fillWidth: true }
            Label {
                visible: card.model.length > 0 && !card.streaming
                Layout.maximumWidth: 110
                text: (card.cached ? "Kept · " : "") + card.model
                elide: Text.ElideRight
                color: Theme.textTertiary; font.pixelSize: Theme.fontCaption
            }
            IconButton {
                objectName: "explainStop"; visible: card.streaming
                icon.name: "stop"; description: "Stop"
                onClicked: card.stop()
            }
            IconButton {
                objectName: "explainAgain"; visible: !card.streaming && !card.needsConsent
                icon.name: "reload"; description: "Explain again"
                onClicked: card.start(true)
            }
            IconButton {
                objectName: "explainCopy"; enabled: card.answer.length > 0 && !card.streaming
                icon.name: "copy"; description: "Copy"
                onClicked: researchStore.copyText(card.answer)
            }
            IconButton {
                objectName: "explainSaveNote"; enabled: card.answer.length > 0 && !card.streaming
                icon.name: "note"; description: "Save as Note"
                onClicked: card.saveAsNote()
            }
        }
    }
    Shortcut { sequence: "Esc"; enabled: card.visible; onActivated: card.close() }
}
