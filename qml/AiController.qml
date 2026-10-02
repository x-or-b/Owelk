import "UiTheme.js" as Theme
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The AI conversation behind the AI panel. Lives outside the dock so switching panels or docks
// never drops a streaming answer. Every turn is kept as a thread; follow-ups send earlier turns along.
Item {
    id: root
    objectName: "aiController"
    visible: false
    readonly property var ai: researchStore.ai
    property var reader: null
    property string threadId: ""
    property var thread: ({})
    readonly property var messages: thread.messages || []
    // What the next request carries (source, scope, page, selection, captureId, action).
    property var spec: ({})
    property int request: -1
    property string pendingQuestion: ""
    property string answer: ""
    property string error: ""
    property string usedModel: ""
    property bool truncated: false
    property bool streaming: false
    // provider id → [{id, name}] as the providers report them.
    property var models: ({})
    // Whether the panel shows a conversation (open thread or a new one) rather than the thread list.
    property bool conversationOpen: false
    signal focusRequested()
    readonly property var providerInfo: ai.providers.find(function(p) { return p.id === ai.provider }) || ({})
    // The model choice for the next turn: provider and model are the service's; effort and fast
    // mode are remembered per provider and offered only where the model supports them.
    readonly property string model: (ai.providers, ai.model(ai.provider))
    readonly property var modelInfo: (models[ai.provider] || []).find(function(m) { return m.id === root.model }) || ({})
    readonly property string modelLabel: modelInfo.name || model || (ai.provider === "codex" || ai.provider.endsWith("-agent") ? "Default model" : "Choose a model")
    readonly property var efforts: modelInfo.efforts || []
    property string effort: ""
    property bool fast: false
    readonly property string effectiveEffort: efforts.indexOf(effort) >= 0 ? effort : (modelInfo.defaultEffort || (efforts.length ? efforts[0] : ""))
    readonly property bool fastAvailable: !!modelInfo.fast
    readonly property bool effectiveFast: fast && fastAvailable
    // Images attached to the next question: [{url, name}].
    property var images: []
    readonly property string selectionProvider: ai.provider
    onSelectionProviderChanged: loadSelection()
    Component.onCompleted: { loadSelection(); loadModels() }
    function loadSelection() {
        effort = researchStore.setting("ai.effort." + ai.provider, "")
        fast = researchStore.setting("ai.fast." + ai.provider, "") === "1"
    }
    function setEffort(value) { effort = value; researchStore.setSetting("ai.effort." + ai.provider, value) }
    function setFast(on) { fast = on; researchStore.setSetting("ai.fast." + ai.provider, on ? "1" : "") }
    function effortName(value) {
        const names = {minimal: "Minimal", low: "Low", medium: "Medium", high: "High", xhigh: "Extra high", max: "Max", ultra: "Ultra"}
        return names[value] || (value ? value.charAt(0).toUpperCase() + value.slice(1) : "")
    }
    function companyName(provider) {
        return ({claude: "Anthropic", openai: "OpenAI", codex: "ChatGPT account", ollama: "Ollama (this Mac)",
                 "claude-agent": "Claude Agent", "codex-agent": "Codex Agent", "gemini-agent": "Gemini CLI"})[provider] || provider
    }
    function attachImage(url) {
        const value = url.toString()
        if (!/\.(png|jpe?g|gif|webp|heic)$/i.test(value) || images.some(function(i) { return i.url === value })) return false
        if (images.length >= 6) { error = "Up to 6 images per question."; return false }
        images = images.concat([{url: value, name: decodeURIComponent(value.replace(/^.*\//, ""))}])
        return true
    }
    function pasteImage() {
        const file = ai.saveClipboardImage()
        return file.length > 0 && attachImage(file)
    }
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
        images.forEach(function(image, index) { list.push({kind: "image", index: index, label: image.name, url: image.url}) })
        return list
    }
    function stop() { if (streaming) ai.cancel(request) }
    function reset() {
        stop()
        answer = ""; error = ""; pendingQuestion = ""; usedModel = ""; truncated = false
    }
    // A reader or capture action starts a new thread about that material.
    function begin(next) {
        reset()
        threadId = ""; thread = ({})
        spec = Object.assign({}, next)
        conversationOpen = true
        if (spec.action === "ask") focusRequested()
        else send("")
    }
    function newThread() {
        reset()
        threadId = ""; thread = ({})
        spec = reader && reader.source && reader.source.toString().length ? {source: reader.source, scope: "none", page: reader.currentPage || 0} : ({})
        conversationOpen = true
        focusRequested()
    }
    function openThread(id) {
        const saved = researchStore.aiThread(id)
        if (!saved.id) return false
        reset()
        threadId = id; thread = saved
        conversationOpen = true
        // Continue with the model the thread used, when that provider is still set up.
        const info = ai.providers.find(function(p) { return p.id === saved.provider }) || ({})
        if (info.configured || saved.provider === "ollama") {
            ai.provider = saved.provider
            if (saved.model) ai.setModel(saved.provider, saved.model)
        }
        spec = saved.source && saved.source.toString().length ? {source: saved.source, scope: "none"} : ({})
        return true
    }
    function attach(kind) {
        if (!reader) return
        const next = Object.assign({}, spec, {source: reader.source})
        if (kind === "page") { next.scope = "page"; next.page = reader.currentPage || 0 }
        else if (kind === "paper") next.scope = "paper"
        else if (kind === "selection" && reader.selectedText.length) { next.selection = reader.selectedText; next.scope = next.scope || "selection" }
        spec = next
    }
    function detach(kind, index) {
        if (kind === "image") { images = images.filter(function(_, i) { return i !== index }); return }
        const next = Object.assign({}, spec)
        if (kind === "paper") return
        if (kind === "selection") next.selection = ""
        if (kind === "page" || kind === "paperText") next.scope = "none"
        if (kind === "capture") delete next.captureId
        spec = next
    }
    function send(question) {
        error = ""
        const provider = ai.provider
        if (!providerInfo.configured && provider !== "ollama") {
            error = setupHint(provider)
            return false
        }
        if (!spec.action && !question.trim().length) return false
        if (!ai.consented(provider)) { consent.question = question; consent.open(); return false }
        pendingQuestion = question.trim().length ? question.trim() : (actions[spec.action] || "Ask")
        answer = ""; streaming = true
        const choice = {provider: provider, model: model, question: question, threadId: threadId, action: spec.action || "ask",
                        imageFiles: images.map(function(i) { return i.url })}
        if (efforts.length) choice.effort = effectiveEffort
        if (effectiveFast) choice.fast = true
        request = ai.ask(Object.assign({}, spec, choice))
        images = []
        return true
    }
    function loadModels() {
        for (const p of ai.providers)
            if (p.configured || p.id === "ollama") ai.listModels(p.id)
    }
    // Where a provider that cannot answer yet is set up.
    function setupHint(provider) {
        if (provider === "codex") return "Sign in with ChatGPT in Settings → AI."
        if (provider === "claude-agent") return "Claude Agent needs a Claude API key (console.anthropic.com). Add it in Settings → AI → Claude Agent. A Claude.ai subscription cannot be used here."
        if (provider.endsWith("-agent")) return "Install the agent in Settings → AI."
        return "Add an API key in Settings → AI."
    }
    function chooseProvider(provider) {
        ai.provider = provider
        error = ""
        const info = ai.providers.find(function(p) { return p.id === provider }) || ({})
        if (!info.configured && provider !== "ollama")
            error = setupHint(provider)
        else ai.listModels(provider)
    }
    function chooseModel(provider, model) {
        ai.provider = provider
        ai.setModel(provider, model)
    }
    function showThreads() {
        reset()
        images = []
        threadId = ""; thread = ({}); spec = ({})
        conversationOpen = false
    }
    function renameThread(id, title) { return researchStore.renameAiThread(id, title) }
    function deleteThread(id) {
        if (id === threadId) { reset(); threadId = ""; thread = ({}) }
        return researchStore.deleteAiThread(id)
    }
    function saveAsNote(index) {
        const message = messages[index]
        if (!message || message.role !== "assistant" || !threadId.length) return ""
        const lines = [message.content, "", "---", "- " + researchStore.markdownLink("ai", threadId)]
        if (thread.source && thread.source.toString().length) {
            const paper = researchStore.documentLinkId(thread.source)
            if (paper.length) lines.push("- " + researchStore.markdownLink("document", paper))
        }
        const note = researchStore.createNote(thread.title || "AI", lines.join("\n") + "\n")
        if (note.length) { researchStore.addLink("note", note, "ai", threadId); researchStore.notify("Saved as a note with links to its sources.") }
        return note
    }
    Connections {
        target: root.ai
        function onStarted(id, thread, provider, model, cut) {
            if (id !== root.request) return
            root.usedModel = model; root.truncated = cut
            if (root.threadId !== thread) { root.threadId = thread; root.thread = researchStore.aiThread(thread) }
        }
        function onDelta(id, text) { if (id === root.request) root.answer += text }
        function onFinished(id, text, details) {
            if (id !== root.request) return
            root.streaming = false; root.usedModel = details.model
            root.thread = researchStore.aiThread(root.threadId)
            root.answer = ""; root.pendingQuestion = ""
            // The material went with this turn; follow-ups reuse it through the thread.
            root.spec = root.spec.source ? {source: root.spec.source, scope: "none"} : ({})
        }
        function onFailed(id, message) {
            if (id !== root.request) return
            root.streaming = false
            if (message !== "Stopped.") root.error = message
        }
        function onModelsLoaded(provider, list) {
            const next = Object.assign({}, root.models)
            next[provider] = list
            root.models = next
        }
    }
    Connections {
        target: researchStore
        function onAiThreadsChanged() {
            if (root.threadId.length && !root.streaming) {
                const saved = researchStore.aiThread(root.threadId)
                if (saved.id) root.thread = saved
                else { root.threadId = ""; root.thread = ({}) }
            }
        }
    }
    UiControls.Dialog {
        id: consent
        objectName: "aiConsentDialog"
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: 440
        modal: true
        property string question: ""
        title: "Send to " + (root.providerInfo.name || "AI provider") + "?"
        standardButtons: Dialog.Ok | Dialog.Cancel
        ColumnLayout {
            width: parent.width
            spacing: 8
            Label {
                Layout.fillWidth: true; wrapMode: Text.Wrap
                text: "Owelk sends the parts shown below and the earlier turns of this thread to " + (root.providerInfo.sends || "the provider")
                      + " each time you ask. Nothing else from your library leaves this Mac, and the PDF file itself is never uploaded."
            }
            Repeater {
                model: root.attachments
                delegate: Label { required property var modelData; text: "• " + modelData.label; color: Theme.textSecondary; elide: Text.ElideRight; Layout.fillWidth: true }
            }
            Label { Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: 12; color: Theme.textTertiary; text: "You are asked once per provider. Usage is billed by the provider under your account." }
        }
        onAccepted: { root.ai.giveConsent(root.ai.provider); root.send(question) }
    }
}
