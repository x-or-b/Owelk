import "UiTheme.js" as Theme
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Ask an AI about the selection, page, paper or a capture. Shows what will be sent and where, streams
// the answer, and can keep it as a saved answer or a note linked to the paper.
UiControls.Popup {
    id: root
    objectName: "aiComposer"
    parent: Overlay.overlay
    x: parent ? parent.width - width - 24 : 0
    y: 56
    width: Math.min(560, parent ? parent.width - 48 : 560)
    height: Math.min(680, parent ? parent.height - 80 : 680)
    modal: false
    closePolicy: Popup.CloseOnEscape
    padding: 14
    readonly property var ai: researchStore.ai
    property var spec: ({})
    property int request: -1
    property string answer: ""
    property string error: ""
    property string usedModel: ""
    property bool truncated: false
    property bool streaming: false
    property var finishedDetails: null
    property string savedId: ""
    property bool showingSaved: false
    readonly property var providerInfo: ai.providers.find(function(p) { return p.id === providerBox.currentId }) || ({})
    readonly property var actions: ({explain: "Explain", translate: "Translate", summarize: "Summarize", ask: "Ask", figure: "Explain figure"})
    // What goes into the request, shown as chips before anything is sent.
    readonly property var attachments: {
        const list = []
        const s = spec
        if (s.source && s.source.toString().length) list.push({kind: "paper", label: "Paper · " + researchStore.displayName(s.source)})
        if (s.selection && s.selection.length) {
            const flat = s.selection.replace(/\s+/g, " ").trim()
            list.push({kind: "selection", label: "Selection · " + flat.slice(0, 60) + (flat.length > 60 ? "…" : "")})
        }
        if (s.scope === "page") list.push({kind: "page", label: "Page " + (Number(s.page) + 1) + " text"})
        if (s.scope === "paper") list.push({kind: "paperText", label: "Full paper text"})
        if (s.captureId) list.push({kind: "capture", label: s.action === "figure" ? "Figure image" : "Excerpt"})
        return list
    }
    function begin(next) {
        if (streaming) ai.cancel(request)
        spec = Object.assign({}, next)
        answer = ""; error = ""; usedModel = ""; truncated = false; finishedDetails = null; savedId = ""; showingSaved = false
        question.text = ""
        open()
        // Questions wait for the reader; one-click actions start right away when the provider is ready.
        if (spec.action === "ask") question.forceActiveFocus()
        else send()
    }
    function showSaved(id) {
        const saved = researchStore.aiResponse(id)
        if (!saved.id) return
        if (streaming) ai.cancel(request)
        spec = {action: saved.action, source: saved.source, page: saved.page, scope: "none"}
        answer = saved.answer; error = ""; usedModel = saved.model; savedId = id; showingSaved = true
        finishedDetails = null
        question.text = saved.question
        open()
    }
    function send() {
        error = ""
        const provider = providerBox.currentId
        if (!root.providerInfo.configured && provider !== "ollama") {
            error = provider === "codex" ? "Sign in with ChatGPT in Settings → AI." : "Add an API key in Settings → AI."
            return
        }
        if (!ai.consented(provider)) { consent.open(); return }
        answer = ""; savedId = ""; finishedDetails = null; showingSaved = false
        streaming = true
        request = ai.ask(Object.assign({}, spec, {provider: provider, question: question.text}))
    }
    Connections {
        target: root.ai
        function onStarted(id, provider, model, cut) { if (id === root.request) { root.usedModel = model; root.truncated = cut } }
        function onDelta(id, text) { if (id === root.request) root.answer += text }
        function onFinished(id, text, details) {
            if (id !== root.request) return
            root.streaming = false; root.answer = text; root.usedModel = details.model; root.finishedDetails = details
        }
        function onFailed(id, message) {
            if (id !== root.request) return
            root.streaming = false
            if (message !== "Stopped.") root.error = message
        }
    }
    function saveAnswer() {
        if (savedId.length) return savedId
        if (!finishedDetails) return ""
        savedId = researchStore.saveAiResponse(Object.assign({}, finishedDetails, {answer: answer}))
        return savedId
    }
    function saveAsNote() {
        const id = saveAnswer()
        if (!id.length) return
        const lines = [answer, "", "---", "- " + researchStore.markdownLink("ai", id)]
        if (spec.source && spec.source.toString().length) {
            const paper = researchStore.documentLinkId(spec.source)
            if (paper.length) lines.push("- " + researchStore.markdownLink("document", paper))
        }
        if (spec.captureId) lines.push("- " + researchStore.markdownLink("capture", spec.captureId))
        const note = researchStore.createNote((actions[spec.action] || "AI") + " · " + researchStore.displayName(spec.source || ""), lines.join("\n") + "\n")
        if (note.length) { researchStore.addLink("note", note, "ai", id); researchStore.notify("Saved as a note with links to its sources.") }
    }
    background: Rectangle { color: Theme.surfacePanel; border.color: Theme.borderPopup; radius: Theme.cornerRadius }
    UiControls.Dialog {
        id: consent
        objectName: "aiConsentDialog"
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: 440
        modal: true
        title: "Send to " + (root.providerInfo.name || "AI provider") + "?"
        standardButtons: Dialog.Ok | Dialog.Cancel
        ColumnLayout {
            width: parent.width
            spacing: 8
            Label {
                Layout.fillWidth: true; wrapMode: Text.Wrap
                text: "Owelk sends the parts shown below to " + (root.providerInfo.sends || "the provider")
                      + " each time you ask. Nothing else from your library leaves this Mac, and the PDF file itself is never uploaded."
            }
            Repeater {
                model: root.attachments
                delegate: Label { required property var modelData; text: "• " + modelData.label; color: Theme.textSecondary; elide: Text.ElideRight; Layout.fillWidth: true }
            }
            Label { Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: 12; color: Theme.textTertiary; text: "You are asked once per provider. Usage is billed by the provider under your account." }
        }
        onAccepted: { root.ai.giveConsent(providerBox.currentId); root.send() }
    }
    contentItem: ColumnLayout {
        spacing: 10
        RowLayout {
            Layout.fillWidth: true
            Label { text: root.showingSaved ? "Saved answer" : (root.actions[root.spec.action] || "Ask AI"); font.pixelSize: 15; font.weight: Font.DemiBold; color: Theme.text }
            Item { Layout.fillWidth: true }
            UiControls.ComboBox {
                id: providerBox
                objectName: "aiProviderBox"
                Layout.preferredWidth: 210
                textRole: "name"
                model: root.ai.providers
                readonly property string currentId: currentIndex >= 0 && model[currentIndex] ? model[currentIndex].id : root.ai.provider
                currentIndex: Math.max(0, root.ai.providers.findIndex(function(p) { return p.id === root.ai.provider }))
                onActivated: function(index) { root.ai.provider = root.ai.providers[index].id }
            }
            ReaderIconButton { kind: "close"; description: "Close"; onClicked: { if (root.streaming) root.ai.cancel(root.request); root.close() } }
        }
        Flow {
            Layout.fillWidth: true
            spacing: 6
            Repeater {
                model: root.attachments
                delegate: Rectangle {
                    required property var modelData
                    height: 24; width: Math.min(chip.implicitWidth + 16, 300)
                    radius: Theme.cornerRadius; color: Theme.surfaceAlt; border.color: Theme.border
                    Label { id: chip; anchors.centerIn: parent; width: parent.width - 12; text: modelData.label; elide: Text.ElideRight; maximumLineCount: 1; textFormat: Text.PlainText; font.pixelSize: 11; color: Theme.textSecondary }
                }
            }
        }
        UiControls.TextArea {
            id: question
            objectName: "aiQuestion"
            Layout.fillWidth: true
            Layout.preferredHeight: 70
            placeholderText: root.spec.action === "ask" ? "Ask about the material above…" : "Optional: add a request (e.g. explain more simply)"
            wrapMode: TextEdit.Wrap
            Keys.onPressed: function(event) {
                if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) { root.send(); event.accepted = true }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            Label {
                Layout.fillWidth: true
                text: (root.providerInfo.kind === "local" ? "Stays on this Mac" : "Sent to " + (root.providerInfo.sends || "")) + (root.usedModel ? " · " + root.usedModel : "")
                      + (root.truncated ? " · long text shortened" : "")
                elide: Text.ElideRight; font.pixelSize: 11; color: Theme.textTertiary
            }
            UiControls.Button {
                objectName: "aiSend"
                text: root.streaming ? "Stop" : (root.answer.length ? "Ask Again" : "Ask")
                highlighted: !root.streaming
                onClicked: root.streaming ? root.ai.cancel(root.request) : root.send()
            }
        }
        Label {
            objectName: "aiError"
            visible: root.error.length > 0
            Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
            text: root.error; color: Theme.danger; font.pixelSize: 12
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }
        ScrollView {
            Layout.fillWidth: true; Layout.fillHeight: true
            clip: true
            Text {
                objectName: "aiAnswer"
                width: parent.width
                text: root.answer.length ? researchStore.markdownHtml(root.answer, Theme.accent)
                    : root.streaming ? "<i>Thinking…</i>" : ""
                textFormat: Text.RichText
                wrapMode: Text.Wrap
                color: Theme.textBody
                font.pixelSize: 13
                onLinkActivated: function(link) { if (/^https?:/.test(link)) Qt.openUrlExternally(link) }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            visible: root.answer.length > 0 && !root.streaming
            UiControls.Button { text: "Copy"; onClicked: researchStore.copyText(root.answer) }
            UiControls.Button {
                objectName: "aiSaveAnswer"
                text: root.savedId.length ? "Saved" : "Save Answer"
                enabled: !root.savedId.length && root.finishedDetails !== null
                onClicked: if (root.saveAnswer().length) researchStore.notify("Answer saved. Find it in search.")
            }
            UiControls.Button { objectName: "aiSaveNote"; text: "Save as Note"; enabled: root.finishedDetails !== null || root.savedId.length > 0; onClicked: root.saveAsNote() }
            Item { Layout.fillWidth: true }
        }
    }
}
