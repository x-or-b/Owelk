import Owelk.Ui
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
    // What the next request carries (source, scope, page, selection, quote, action).
    property var spec: ({})
    // The page last translated on its own, so the panel can offer the next one (-1: none).
    property int translatePage: -1
    readonly property bool canTranslateNext: translatePage >= 0 && !streaming && !!reader && reader.pdfReady
                                             && translatePage + 1 < reader.pageCount && !!spec.source
    function translateNext() {
        if (!canTranslateNext) return false
        const page = translatePage + 1
        spec = {action: "translate", scope: "page", page: page, source: spec.source, fresh: true, label: "Translate page " + (page + 1)}
        return send("")
    }
    property int request: -1
    property string pendingQuestion: ""
    property string answer: ""
    property string error: ""
    property string usedModel: ""
    property bool truncated: false
    property bool streaming: false
    // The reasoning summary of the answer being prepared, and the seconds before the answer began.
    property string thinkingText: ""
    property int thinkingSeconds: 0
    property double askedAt: 0
    property bool showThinking: researchStore.setting("ai.showThinking", "1") === "1"
    Connections { target: researchStore; function onSettingsChanged() { root.showThinking = researchStore.setting("ai.showThinking", "1") === "1" } }
    // One line for "Thinking · …": the latest heading of the summary, else its latest sentence.
    function thinkingHeadline(text) {
        const headings = text.match(/\*\*([^*\n]+)\*\*/g) || []
        let line = headings.length ? headings[headings.length - 1] : ""
        if (!line.length) {
            const paragraphs = text.split(/\n+/).map(function(p) { return p.trim() }).filter(function(p) { return p.length })
            const last = paragraphs.length ? paragraphs[paragraphs.length - 1] : ""
            const sentences = last.split(/[.!?]\s+/).filter(function(p) { return p.trim().length > 12 })
            line = sentences.length ? sentences[sentences.length - 1] : last
        }
        line = line.replace(/[*_`#>]/g, "").replace(/\s+/g, " ").trim()
        return line.length > 120 ? line.slice(0, 119) + "…" : line
    }
    // provider id → [{id, name}] as the providers report them.
    property var models: ({})
    // Whether the panel shows a conversation (open thread or a new one) rather than the thread list.
    property bool conversationOpen: false
    signal focusRequested()
    // An answer came in: the thread, its title and the answer's opening words (plain text).
    signal answered(string threadId, string title, string preview)
    readonly property var providerInfo: ai.providers.find(function(p) { return p.id === ai.provider }) || ({})
    // The model choice for the next turn: provider and model are the service's; effort and fast
    // mode are remembered per provider and offered only where the model supports them.
    readonly property string model: (ai.providers, ai.model(ai.provider))
    readonly property var modelInfo: (models[ai.provider] || []).find(function(m) { return m.id === root.model }) || ({})
    readonly property string modelLabel: modelInfo.name || model || (ai.provider === "codex" ? "Default model" : "Choose a model")
    readonly property var efforts: modelInfo.efforts || []
    property string effort: ""
    property bool fast: false
    readonly property string effectiveEffort: efforts.indexOf(effort) >= 0 ? effort : (modelInfo.defaultEffort || (efforts.length ? efforts[0] : ""))
    readonly property bool fastAvailable: !!modelInfo.fast
    readonly property bool effectiveFast: fast && fastAvailable
    // Images attached to the next question: [{url, name}].
    property var images: []
    // A region capture started from the AI panel goes into the next question instead of only the shelf.
    property bool captureWanted: false
    readonly property bool readerCapturing: !!reader && !!reader.capturing
    // Esc ends capture mode without a capture; the save itself is asynchronous, so wait a moment.
    onReaderCapturingChanged: if (!readerCapturing && captureWanted) captureGrace.restart()
    Timer { id: captureGrace; interval: 4000; onTriggered: root.captureWanted = false }
    function captureRegion() {
        if (!reader || !reader.pdfReady) { error = "Open a PDF to capture a region."; return false }
        error = ""
        captureWanted = true
        captureGrace.stop()
        reader.startCapture()
        return true
    }
    // Called for every saved capture; takes the one the panel asked for.
    function takeCapture(id) {
        if (!captureWanted) return false
        captureWanted = false
        captureGrace.stop()
        const capture = researchStore.captures.find(function(c) { return c.id === id })
        if (!capture || !capture.imageAvailable) return false
        if (!conversationOpen) newThread()
        if (capture.source && !spec.source) spec = Object.assign({}, spec, {source: capture.source, scope: spec.scope || "none"})
        images = images.concat([{url: capture.image.toString(), name: "Capture · p. " + (Number(capture.page) + 1)}])
        focusRequested()
        return true
    }
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
        return ({claude: "Anthropic", openai: "OpenAI", codex: "ChatGPT account", ollama: "Ollama (this computer)"})[provider] || provider
    }
    function attachImage(url) {
        const value = url.toString()
        if (!/\.(png|jpe?g|gif|webp|heic)$/i.test(value) || images.some(function(i) { return i.url === value })) return false
        if (images.length >= 6) { error = "Up to 6 images per question."; return false }
        images = images.concat([{url: value, name: decodeURIComponent(value.replace(/^.*\//, ""))}])
        return true
    }
    // A figure, table, algorithm or equation (with its caption) from the PDF: its image, named so the model
    // knows what it is ("Figure 3, page 5"), joins the open conversation, or a new one about that paper.
    // Nothing is saved to Captures.
    function attachFigure(next) {
        const file = ai.saveRegionImage(next.source, next.page, next.region)
        if (!file.length) { error = "Could not read that part of the PDF."; return false }
        if (!conversationOpen) newThread(next.source)
        if (!attachImage(file)) return false
        const label = next.label || "Figure", page = Number(next.page) + 1
        const elsewhere = spec.source && !researchStore.sameSource(spec.source, next.source)
        const copy = images.slice()
        copy[copy.length - 1] = Object.assign({}, copy[copy.length - 1], {
            name: label + " · p. " + page,
            about: label + ", page " + page + (elsewhere ? " of " + researchStore.displayName(next.source) : "")})
        images = copy
        focusRequested()
        return true
    }
    // Words selected in the PDF or a saved excerpt, to ask about: with the open conversation, or a new one.
    function attachText(next) {
        if (!conversationOpen) newThread(next.source)
        const elsewhere = spec.source && !researchStore.sameSource(spec.source, next.source)
        const text = (elsewhere ? "(From " + researchStore.displayName(next.source) + ", page " + (Number(next.page) + 1) + ")\n" : "") + next.selection
        spec = Object.assign({}, spec, {selection: text})
        focusRequested()
        return true
    }
    function pasteImage() {
        const file = ai.saveClipboardImage()
        return file.length > 0 && attachImage(file)
    }
    readonly property var actions: ({translate: "Translate", ask: "Ask"})
    // What goes into the request, shown as chips before anything is sent.
    readonly property var attachments: {
        const list = []
        const s = spec
        // The paper chip is the paper itself: with no narrower scope (a page, a selection) its whole text
        // goes with the first question; later turns carry it in the conversation.
        if (s.source && s.source.toString().length) list.push({kind: "paper", label: "Paper · " + researchStore.displayName(s.source)})
        if (s.selection && s.selection.length) {
            const flat = s.selection.replace(/\s+/g, " ").trim()
            list.push({kind: "selection", label: "Selection · " + flat.slice(0, 60) + (flat.length > 60 ? "…" : "")})
        }
        if (s.quote && s.quote.length) {
            const flat = s.quote.replace(/\s+/g, " ").trim()
            list.push({kind: "quote", label: "Quote · " + flat.slice(0, 60) + (flat.length > 60 ? "…" : "")})
        }
        if (s.scope === "page") list.push({kind: "page", label: "Page " + (Number(s.page) + 1) + " text"})
        if (s.scope === "library") list.push({kind: "library", label: (s.collection ? "Collection · " + s.collectionName : "Whole library") + " · passages that answer the question"})
        images.forEach(function(image, index) { list.push({kind: "image", index: index, label: image.name, url: image.url}) })
        return list
    }
    function stop() { if (streaming) ai.cancel(request) }
    function reset() {
        stop()
        answer = ""; error = ""; pendingQuestion = ""; usedModel = ""; truncated = false
        thinkingText = ""; thinkingSeconds = 0
    }
    // Attaching (a figure, the selection, a capture) adds to the conversation open in the AI panel, even
    // while the panel is hidden, or starts one; a page translation starts its own thread.
    function begin(next) {
        if (next.attach) {
            if (next.region) attachFigure(next)
            else if (next.captureId) attachCapture(next.captureId)
            else if (next.selection) attachText(next)
            return
        }
        reset()
        threadId = ""; thread = ({})
        conversationOpen = true
        spec = Object.assign({}, next)
        if (spec.action === "ask") focusRequested()
        else send("")
    }
    // A saved capture: its image, or its text, like a selection.
    function attachCapture(id) {
        const capture = researchStore.captures.find(function(c) { return c.id === id })
        if (!capture) return false
        const source = capture.kind === "web" ? "" : capture.source
        if (capture.kind === "text") return attachText({source: source, page: capture.page, selection: capture.text})
        if (!capture.imageAvailable) { error = "This capture's image is missing."; return false }
        if (!conversationOpen) newThread(source)
        if (!attachImage(capture.image.toString())) return false
        const copy = images.slice()
        copy[copy.length - 1] = Object.assign({}, copy[copy.length - 1], {name: "Capture · p. " + (Number(capture.page) + 1),
                                                                       about: "a region captured from page " + (Number(capture.page) + 1)})
        images = copy
        focusRequested()
        return true
    }
    // A new conversation about the given paper (or the one in the reader).
    function newThread(source) {
        reset()
        threadId = ""; thread = ({})
        const paper = source !== undefined && source.toString().length ? source : reader && reader.source ? reader.source : ""
        spec = paper.toString().length ? {source: paper, scope: "paper", page: reader && researchStore.sameSource(reader.source, paper) ? reader.currentPage || 0 : 0} : ({})
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
    // This paper again, after its chip was removed.
    function attachPaper() {
        if (!reader || !reader.source.toString().length) return
        spec = Object.assign({}, spec, {source: reader.source, scope: "paper"})
    }
    // A passage from an answer (Ask About This), sent with the next question as its own material.
    function quote(text) {
        const next = Object.assign({}, spec)
        next.quote = text.trim().slice(0, 4000)
        if (next.quote.length) spec = next
        focusRequested()
    }
    function detach(kind, index) {
        if (kind === "image") { images = images.filter(function(_, i) { return i !== index }); return }
        const next = Object.assign({}, spec)
        // Without the paper the question goes out on its own: no paper details, page or selection.
        if (kind === "paper") {
            delete next.source; delete next.page; delete next.selection
            if (next.scope === "page" || next.scope === "paper" || next.scope === "selection") next.scope = "none"
            spec = next
            return
        }
        if (kind === "quote") delete next.quote
        if (kind === "library") { spec = reader && reader.source && reader.source.toString().length ? {source: reader.source, scope: "paper"} : ({}); return }
        if (kind === "selection") next.selection = ""
        if (kind === "page") next.scope = "none"
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
        pendingQuestion = question.trim().length ? question.trim() : (spec.label || actions[spec.action] || "Ask")
        translatePage = !question.trim().length && spec.action === "translate" && spec.scope === "page" ? Number(spec.page) : -1
        answer = ""; streaming = true
        thinkingText = ""; thinkingSeconds = 0; askedAt = Date.now()
        const choice = {provider: provider, model: model, question: question, threadId: threadId, action: spec.action || "ask",
                        imageFiles: images.map(function(i) { return i.url }),
                        imageLabels: images.map(function(i) { return i.about || "" }),
                        imageNames: images.map(function(i) { return i.name || "" })}
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
        return "Add an API key in Settings → AI."
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
        function onThinking(id, text) { if (id === root.request) root.thinkingText += text }
        function onDelta(id, text) {
            if (id !== root.request) return
            if (!root.answer.length) root.thinkingSeconds = Math.max(1, Math.round((Date.now() - root.askedAt) / 1000))
            root.answer += text
        }
        function onFinished(id, text, details) {
            if (id !== root.request) return
            root.streaming = false; root.usedModel = details.model
            root.thread = researchStore.aiThread(root.threadId)
            root.answer = ""; root.pendingQuestion = ""; root.thinkingText = ""
            root.answered(root.threadId, root.thread.title || "AI",
                          text.replace(/\]\([^)]*\)/g, "]").replace(/[#*_`>|]/g, "").replace(/\s+/g, " ").trim().slice(0, 160))
            // The material went with this turn; follow-ups reuse it through the thread.
            root.spec = root.spec.scope === "library" ? {scope: "library", collection: root.spec.collection || "", collectionName: root.spec.collectionName || ""}
                      : root.spec.source ? {source: root.spec.source, scope: "none"} : ({})
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
    Dialog {
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
                      + " each time you ask. Nothing else from your library leaves this computer, and the PDF file itself is never uploaded."
            }
            Repeater {
                model: root.attachments
                delegate: Label { required property var modelData; text: "• " + modelData.label; color: Theme.textSecondary; elide: Text.ElideRight; Layout.fillWidth: true }
            }
            Label { Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: Theme.fontSmall; color: Theme.textTertiary; text: "You are asked once per provider. Usage is billed by the provider under your account." }
        }
        onAccepted: { root.ai.giveConsent(root.ai.provider); root.send(question) }
    }
}
