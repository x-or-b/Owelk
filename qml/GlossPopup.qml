import Owelk.Ui
import QtQuick
import QtQuick.Controls

// Gloss: the selected word explained as used here, or the selected passage translated, in a small popup
// beside the selection. Nothing is kept in a conversation; the last answers are remembered while Owelk
// runs, so glossing at the same words again is instant.
Popup {
    id: root
    objectName: "glossPopup"
    readonly property var ai: researchStore.ai
    property var spec: ({})
    property int request: -1
    property bool streaming: false
    property string answer: ""
    property string error: ""
    // source|text → answer, the most recent last.
    property var recent: ({})
    property var recentKeys: []
    readonly property var providerInfo: ai.providers.find(function(p) { return p.id === ai.provider }) || ({})
    readonly property bool needsConsent: (ai.providers, !ai.consented(ai.provider))
    readonly property string key: (spec.source || "").toString() + "|" + (spec.text || "")
    width: Math.min(380, parent ? parent.width - 16 : 380)
    height: Math.min(content.implicitHeight + topPadding + bottomPadding, 300)
    padding: 10
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    onClosed: if (streaming) { ai.cancel(request); streaming = false }

    // spec: source, page, text. at: the point to show it by (the parent's coordinates).
    function show(next, at) {
        if (streaming) { ai.cancel(request); streaming = false }
        spec = next
        answer = ""; error = ""
        x = Math.max(8, Math.min(parent.width - width - 8, at.x))
        y = at.y + 6 + height < parent.height ? at.y + 6 : Math.max(8, at.y - height - 40)
        open()
        if (recent[key] !== undefined) { answer = recent[key]; return }
        start()
    }
    function start() {
        error = ""
        if (!providerInfo.configured && ai.provider !== "ollama") {
            error = ai.provider === "codex" ? "Sign in with ChatGPT in Settings → AI." : "Add an API key in Settings → AI."
            return
        }
        if (needsConsent) return
        streaming = true
        request = ai.gloss(spec)
    }
    function remember(text) {
        const next = Object.assign({}, recent)
        next[key] = text
        recentKeys = recentKeys.filter(function(k) { return k !== key }).concat([key])
        while (recentKeys.length > 50) { delete next[recentKeys[0]]; recentKeys = recentKeys.slice(1) }
        recent = next
    }
    Connections {
        target: root.ai
        function onDelta(id, text) { if (id === root.request) root.answer += text }
        function onFinished(id, text) {
            if (id !== root.request) return
            root.streaming = false
            root.answer = text
            root.remember(text)
        }
        function onFailed(id, message) {
            if (id !== root.request) return
            root.streaming = false
            if (message !== "Stopped.") root.error = message
        }
    }
    contentItem: Flickable {
        contentHeight: content.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        ScrollBar.vertical: ScrollBar {}
        Column {
            id: content
            width: parent.width
            spacing: 8
            // First use of a provider: what is sent, before anything is.
            Label {
                visible: root.needsConsent && !root.error.length
                width: parent.width; wrapMode: Text.Wrap
                text: "Gloss sends the selected words and the sentences around them to "
                      + (root.providerInfo.sends || root.providerInfo.name || "the AI provider") + "."
                color: Theme.textSecondary; font.pixelSize: Theme.fontSmall
            }
            Button {
                objectName: "glossConsent"
                visible: root.needsConsent && !root.error.length
                primary: true
                text: "Send"
                onClicked: { root.ai.giveConsent(root.ai.provider); root.start() }
            }
            Label {
                objectName: "glossWaiting"
                visible: root.streaming && !root.answer.length
                text: "…"
                color: Theme.textSecondary
            }
            TextEdit {
                id: answerText
                objectName: "glossAnswer"
                visible: root.answer.length > 0
                width: parent.width - (copy.visible ? copy.width + 4 : 0)
                readOnly: true; selectByMouse: true
                textFormat: TextEdit.RichText; wrapMode: TextEdit.WrapAtWordBoundaryOrAnywhere
                text: visible ? researchStore.markdownHtml(root.answer, Theme.accent, Theme.text, Theme.fontBody) : ""
                color: Theme.text; font.pixelSize: Theme.fontBody
                selectionColor: Theme.mix(Theme.accent, Theme.field, .65); selectedTextColor: Theme.text
                IconButton {
                    id: copy
                    objectName: "glossCopy"
                    visible: !root.streaming
                    x: parent.width + 4; y: -2
                    icon.name: "copy"; description: "Copy"
                    onClicked: researchStore.copyText(root.answer)
                }
            }
            Label {
                objectName: "glossError"
                visible: root.error.length > 0
                width: parent.width; wrapMode: Text.Wrap
                text: root.error
                color: Theme.danger; font.pixelSize: Theme.fontSmall
            }
        }
    }
}
